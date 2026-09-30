-- The ChatGPT-subscription wire: our own SSE client for `codex/responses`, with no Node and no pi.
--
-- RISK, and it is the whole reason this file is shaped the way it is: this is a *private* protocol.
-- The endpoint, the headers and the event names below are not a published API; they were measured
-- from pi 0.87.1 (MIT) and from what this client already sends, and they can change under us without
-- notice. Owning this route means owning that breakage - so the endpoint and the fixed headers are
-- constants at the top of this one file, the event mapping is in the same file directly below them,
-- and `tests/fixtures/subscription/codex-responses-sse.txt` holds one real recorded stream, so a
-- future break is diagnosable against real wire bytes instead of from memory. When it breaks,
-- change this file and re-record the fixture; nothing else needs to move.
--
-- What lives where, because the halves must not drift:
--   * this file  - the endpoint, the headers, the request body, the SSE framing, the event mapping,
--                  the result contract, and the usage endpoint. It is the only thing that talks to
--                  chatgpt.com.
--   * lua/core/openai_sub_catalogue.lua - which ids this route serves and how each one maps a
--                  thinking level onto `reasoning.effort`. No pi read at request time.
--   * lua/core/openai_sub_auth.lua     - the credential (owned by another lane, and named what
--                  that lane named and verified it). This file calls exactly one thing on it:
--                  `token()` -> `{access, account_id, expires}, failure`, and it reads *both*
--                  returns - see the seam below. It never reads pi's auth file, and it never
--                  returns a token to a caller.
--   * host.http_sse (rust/wa-host/src/host.rs) - the socket, the read, cancellation and the
--                  timeouts. It hands over response lines and knows nothing about this protocol.
--
-- Cancellation and deadlines: `host.run_cancelled()` and `WASM_AGENT_SUBSCRIPTION_TIMEOUT` are
-- checked on every line, inside the read, so a cancelled run or an over-budget call stops the stream
-- where it is instead of after it ends. A stream that ends without a terminal event is an ERROR
-- (`subscription_stream_truncated`) and never a partial success: half an answer that looks like an
-- answer is the failure mode this contract exists to prevent.
local json = dofile('lua/vendor/json.lua')
local catalogue = dofile('lua/core/openai_sub_catalogue.lua')
local M = {}

-- ---------------------------------------------------------------------------------------------
-- The endpoint and the fixed headers. Measured; private; one place.
-- ---------------------------------------------------------------------------------------------

-- `model.baseUrl` + `/codex/responses` in pi 0.87.1 (opencodex-responses.js resolveCodexUrl).
M.ENDPOINT = 'https://chatgpt.com/backend-api/codex/responses'

-- The rate-limit windows `M.limits()` reads. Same host, same credential, different path.
M.USAGE_ENDPOINT = 'https://chatgpt.com/backend-api/wham/usage'

-- The client identity this route is known to accept. `codex-cli` is what this client already sent
-- for the usage endpoint before any of this was ported, and the live check in
-- `scripts/check-subscription-wire-live.lua` re-measures it against `codex/responses`. `originator`
-- stays the same claim as the User-Agent rather than a second, contradictory one: pi sends
-- `originator: pi` with its own User-Agent, and we are not pi.
M.USER_AGENT = 'codex-cli'
M.ORIGINATOR = 'codex-cli'
M.OPENAI_BETA = 'responses=experimental'

-- Fixed body fields, each one measured in pi's buildRequestBody for this route.
M.TEXT_VERBOSITY = 'low'                       -- body.text.verbosity
M.REASONING_SUMMARY = 'auto'                   -- body.reasoning.summary
M.INCLUDE = {'reasoning.encrypted_content'}    -- body.include
M.PARALLEL_TOOL_CALLS = true                   -- body.parallel_tool_calls
M.DEFAULT_INSTRUCTIONS = 'You are a helpful assistant.'

-- Thinking levels, in pi's own order (models.js EXTENDED_THINKING_LEVELS), because the clamp below
-- is a search through this list and the order is what decides the answer.
M.THINKING_LEVELS = {'off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'}

-- The event names this file consumes. Kept as a list rather than only as branches, because "what
-- does the endpoint send us" is a question a future break asks, and a reader can answer it here.
M.EVENTS = {
  'response.created',
  'response.output_item.added',
  'response.output_item.done',
  'response.output_text.delta',
  'response.refusal.delta',
  'response.reasoning_summary_text.delta',
  'response.reasoning_summary_part.done',
  'response.reasoning_text.delta',
  'response.function_call_arguments.delta',
  'response.function_call_arguments.done',
  'response.completed',
  'response.incomplete',
  'response.failed',
  'error',
}

-- An event that ends the response. Until one of these arrives, the stream is unfinished, whatever
-- arrived before it - that is what makes a truncated stream an error rather than a short answer.
M.TERMINAL_EVENTS = {
  ['response.completed'] = true,
  ['response.incomplete'] = true,
  ['response.failed'] = true,
}

-- The decision preview cap the UI reads. Code points, not bytes: the count is displayed next to
-- text a reader sees, and a UTF-8 byte count overcounts every non-ASCII character.
M.DECISION_PREVIEW_CHARS = 256

-- ---------------------------------------------------------------------------------------------
-- Small text helpers
-- ---------------------------------------------------------------------------------------------

-- Code points in `text`, or its byte length when the utf8 library is unavailable. Only used for
-- counters and preview caps.
local function codepoints(text)
  text = tostring(text or '')
  if utf8 and utf8.len then return utf8.len(text) or #text end
  return #text
end

-- The first `count` code points of `text`. `utf8.offset` counts from 1, so the byte after the last
-- wanted code point is the offset of `count + 1`.
local function preview(text, count)
  text = tostring(text or '')
  if codepoints(text) <= count then return text end
  if utf8 and utf8.offset then
    local cut = utf8.offset(text, count + 1)
    if cut then return text:sub(1, cut - 1) end
  end
  return text:sub(1, count)
end

-- ---------------------------------------------------------------------------------------------
-- The credential seam
-- ---------------------------------------------------------------------------------------------

-- The credential module's own name, and the one place this file names it. The lane that owns the
-- credential shipped `openai_sub_auth.lua` and verified it - its own store, single-flight refresh
-- counted across processes, rotation, its failure taxonomy, no secrets in what it prints - so this
-- file adopts that name. Renaming the verified artifact to match its caller, or shipping a second
-- module (or a shim) that re-exports it, would make the two halves agree about a *name* while
-- leaving two files that can disagree about a *credential*, which is the defect this closes.
M.CREDENTIAL_MODULE = 'lua/core/openai_sub_auth.lua'

-- A failure of this file's own making, in the credential lane's shape: a `code` to branch on plus a
-- sentence, and a `tostring` that reads like that lane's own sentence. Used only for the two cases
-- the credential module cannot report for itself - its file missing/unloadable, or `token()`
-- answering with neither a credential nor a failure.
local function credential_failure(code, message)
  return setmetatable({ code = code, message = message },
    { __tostring = function(self)
      return tostring(self.code) .. (self.message and (': ' .. tostring(self.message)) or '')
    end })
end
M.credential_failure = credential_failure

-- `{access, account_id, expires}` from the lane that owns the credential. Called per request, never
-- cached here: whoever owns the token owns its refresh, and a copy in this process is a second
-- opinion about when it expired.
--
-- The seam returns **two** values and this file reads both. `token()` answers an absent store
-- (`subscription_credentials_absent`, naming the login to run), a rejected refresh
-- (`refresh_rejected:<status>`), a live lock (`locked`) and an expired flow (`flow_expired`) as
-- `nil, {code, message}`. Reading only the first value collapsed all four into the same bare nil,
-- and a caller cannot act on that: "log in", "another process is refreshing, wait" and "the server
-- refused the refresh token" need three different answers. The second value is passed through
-- unchanged - the code is the callable part, the message is what a log should show.
function M.credential()
  local ok, module = pcall(dofile, M.CREDENTIAL_MODULE)
  if not ok or type(module) ~= 'table' or type(module.token) ~= 'function' then
    return nil, credential_failure('subscription_credential_unavailable',
      M.CREDENTIAL_MODULE .. ' must return {token = function() -> {access, account_id, expires}}')
  end
  local value, failure = module.token()
  if type(value) == 'table' and type(value.access) == 'string' and value.access ~= '' then
    return value
  end
  if type(failure) == 'table' and type(failure.code) == 'string' then return nil, failure end
  return nil, credential_failure('subscription_credential_missing',
    'token() returned no access token and no failure of its own')
end

-- The seam itself. `M.complete` calls through this, so a test or a diagnostic can answer without
-- the credential lane's file; nothing in the runtime path replaces it.
M.credential_provider = M.credential

-- The deadline this route applies to one request, in seconds. Same variable, same bound and same
-- refusal as the pi-backed path used, so a change of transport does not silently change the budget.
function M.request_timeout()
  local raw = host.getenv('WASM_AGENT_SUBSCRIPTION_TIMEOUT') or host.getenv('WASM_AGENT_LLM_TIMEOUT')
  local seconds = raw and tonumber(raw) or 3600
  if not seconds or seconds ~= math.floor(seconds) or seconds < 1 or seconds > 86400 then
    error('invalid_subscription_timeout: expected 1..86400 seconds')
  end
  return seconds
end

-- ---------------------------------------------------------------------------------------------
-- The request: headers, and the Responses body
-- ---------------------------------------------------------------------------------------------

function M.headers(credential, session_id)
  local headers = {
    ['Authorization'] = 'Bearer ' .. credential.access,
    ['chatgpt-account-id'] = tostring(credential.account_id or ''),
    ['originator'] = M.ORIGINATOR,
    ['User-Agent'] = M.USER_AGENT,
    ['OpenAI-Beta'] = M.OPENAI_BETA,
    ['accept'] = 'text/event-stream',
    ['content-type'] = 'application/json',
  }
  if session_id and session_id ~= '' then
    headers['session-id'] = session_id
    headers['x-client-request-id'] = session_id
  end
  return headers
end

-- The text of a message whose content may be a string or a part list. Assistant and system
-- messages are text here: this client never attaches an image to either (an image belongs to a user
-- message or a tool result), and pi's Responses conversion drops a non-text part of an assistant
-- message for the same reason.
local function flat_text(content)
  if type(content) == 'string' then return content end
  local parts = {}
  for _, part in ipairs(type(content) == 'table' and content or {}) do
    if type(part) == 'table' and part.type == 'text' then parts[#parts + 1] = part.text or '' end
  end
  return table.concat(parts, '')
end

-- Responses message ids are their own namespace (`msg_...`), and longer than 64 characters are not
-- accepted. The durable wasm-agent id is still the useful part: it is what makes a replayed message
-- recognisable, so it is sanitised rather than replaced.
function M.response_message_id(id)
  local value = tostring(id or 'message'):gsub('[^%w_%-]', '_')
  value = 'msg_' .. value
  if #value > 64 then value = value:sub(1, 64) end
  return value
end

-- A tool-call id as this route stores it: `call_...|fc_...`. The item part is dropped when it is not
-- an `fc_*` id - the Responses validator rejects a function_call whose item id is another kind of
-- id, and pi drops it in the same case (a call that came from another route or another model).
function M.tool_id_parts(id)
  local text = tostring(id or '')
  local call_id, item_id = text:match('^([^|]*)|(.*)$')
  if not call_id then return text, nil end
  if item_id == '' then item_id = nil end
  if item_id and not item_id:match('^fc_') then item_id = nil end
  return call_id, item_id
end

-- An image part, as this route wants it: a data URL on an input_image item.
local function image_item(url)
  local mime, data = tostring(url or ''):match('^data:([^;]+);base64,(.*)$')
  if not mime then error('subscription_image_part_unsupported: expected a data: URL') end
  return {type = 'input_image', detail = 'auto', image_url = 'data:' .. mime .. ';base64,' .. data}
end

-- A user message's content as Responses input items.
local function user_content(content)
  if type(content) == 'string' then
    if content == '' then return {} end
    return {{type = 'input_text', text = content}}
  end
  local parts = {}
  for _, part in ipairs(content or {}) do
    if type(part) == 'table' and part.type == 'text' then
      parts[#parts + 1] = {type = 'input_text', text = part.text or ''}
    elseif type(part) == 'table' then
      parts[#parts + 1] = image_item(part.image_url and part.image_url.url)
    else
      error('subscription_message_part_unsupported: ' .. type(part))
    end
  end
  return parts
end

-- A tool result's `output`: text, or a part list when the id accepts images. The three fallbacks are
-- the endpoint's own vocabulary for "there was nothing to say", and they are kept: an empty string
-- where a result was expected reads as a tool that answered nothing.
function M.tool_output(content, entry)
  local text, images = {}, {}
  if type(content) == 'string' then
    text[#text + 1] = content
  else
    for _, part in ipairs(content or {}) do
      if type(part) == 'table' and part.type == 'text' then
        text[#text + 1] = part.text or ''
      elseif type(part) == 'table' then
        images[#images + 1] = part.image_url and part.image_url.url
      else
        error('subscription_tool_output_part_unsupported: ' .. type(part))
      end
    end
  end
  local joined = table.concat(text, '\n')
  if #images == 0 then
    return joined ~= '' and joined or '(no tool output)'
  end
  if not (type(entry) == 'table' and entry.supports_image) then
    return joined ~= '' and joined or '(see attached image)'
  end
  local output = {}
  if joined ~= '' then output[#output + 1] = {type = 'input_text', text = joined} end
  for _, url in ipairs(images) do output[#output + 1] = image_item(url) end
  return output
end

-- The transcript as `instructions` plus `input` items. This is wasm-agent's own message conversion -
-- it lived inside the JS bridge before this and is the same rule, not a redesign: system messages
-- become the instructions, an assistant message with a phase replayed as a completed message item
-- carrying that phase, a tool call as a function_call item, a tool result as a function_call_output.
function M.items(messages, entry)
  local instructions, items, tool_names = {}, {}, {}
  for _, message in ipairs(messages or {}) do
    local role = type(message) == 'table' and message.role or nil
    if role == 'system' then
      instructions[#instructions + 1] = flat_text(message.content)
    elseif role == 'assistant' then
      local content = flat_text(message.content)
      if content ~= '' then
        local phase = message.phase
        if phase ~= 'commentary' and phase ~= 'final_answer' then phase = nil end
        items[#items + 1] = {type = 'message', role = 'assistant', status = 'completed',
          id = M.response_message_id(message.id), phase = phase,
          content = {{type = 'output_text', text = content, annotations = {}}}}
      end
      for _, call in ipairs(message.tool_calls or {}) do
        local callee = call['function'] or {}
        local name = callee.name or ''
        tool_names[call.id] = name
        local call_id, item_id = M.tool_id_parts(call.id)
        local arguments = callee.arguments
        if type(arguments) ~= 'string' or arguments == '' then arguments = '{}' end
        items[#items + 1] = {type = 'function_call', id = item_id, call_id = call_id, name = name,
          arguments = arguments}
      end
    elseif role == 'tool' then
      local call_id = M.tool_id_parts(message.tool_call_id)
      items[#items + 1] = {type = 'function_call_output', call_id = call_id,
        output = M.tool_output(message.content, entry)}
    elseif role == 'user' then
      local content = user_content(message.content)
      if #content > 0 then items[#items + 1] = {role = 'user', content = content} end
    else
      error('subscription_message_role_unsupported: ' .. tostring(role))
    end
  end
  return table.concat(instructions, '\n\n'), items
end

-- The thinking levels this id honours, in pi's order. `off` is missing exactly where pi published
-- `off: null` (one id cannot turn reasoning off at all), and the two cases are not the same thing -
-- see `M.off_not_supported` in the catalogue.
function M.supported_levels(entry)
  if type(entry) ~= 'table' or not entry.reasoning then return {'off'} end
  local levels = {}
  local not_supported = catalogue.off_not_supported[tostring(entry.id)] == true
  for _, level in ipairs(M.THINKING_LEVELS) do
    local mapped = (entry.thinking_levels or {})[level]
    if level == 'off' and not_supported then
      -- The id publishes `off: null`: it does not honour this level at all.
    elseif (level == 'xhigh' or level == 'max') and mapped == nil then
      -- High-effort levels exist only where the id published one.
    else
      levels[#levels + 1] = level
    end
  end
  return levels
end

-- pi's rule: a level the id does not honour is moved up to the next level it does, then down, and
-- `off` when there is nothing to move to. Ported rather than simplified because the level that ends
-- up in `reasoning.effort` is the difference between a cheap call and an expensive one.
function M.clamp_level(entry, level)
  local available = M.supported_levels(entry)
  for _, candidate in ipairs(available) do
    if candidate == level then return level end
  end
  local requested
  for index, candidate in ipairs(M.THINKING_LEVELS) do
    if candidate == level then requested = index end
  end
  if not requested then return available[1] or 'off' end
  for index = requested, #M.THINKING_LEVELS do
    for _, candidate in ipairs(available) do
      if candidate == M.THINKING_LEVELS[index] then return candidate end
    end
  end
  for index = requested - 1, 1, -1 do
    for _, candidate in ipairs(available) do
      if candidate == M.THINKING_LEVELS[index] then return candidate end
    end
  end
  return available[1] or 'off'
end

-- The `reasoning` object for the body, or nil when the body must carry none at all. `selected` is
-- what the run asked for: `provider` means "let the route pick", `off` means "no reasoning", or a
-- level name. Known deviation, named here: pi omits `reasoning` entirely when the catalogue
-- published `off: null` for the id (gpt-6-astra), because its `null` and a missing key are
-- different values in JavaScript. We send `{effort = 'low'}` there instead - the level pi's own
-- clamp lands on for that id - which is a body the endpoint accepts for every id in the catalogue.
function M.reasoning_field(entry, selected)
  if not (type(entry) == 'table' and entry.reasoning) then return nil end
  if selected == nil then
    if catalogue.off_not_supported[tostring(entry.id)] then return nil end
    return {effort = (entry.thinking_levels or {}).off or 'none', summary = M.REASONING_SUMMARY}
  end
  local requested = selected
  if requested == 'provider' then requested = 'medium' end
  if requested == 'off' then requested = 'none' end
  local clamped = M.clamp_level(entry, requested)
  if clamped == 'off' then
    if catalogue.off_not_supported[tostring(entry.id)] then return nil end
    return {effort = (entry.thinking_levels or {}).off or 'none', summary = M.REASONING_SUMMARY}
  end
  local effort = (entry.thinking_levels or {})[clamped] or clamped
  return {effort = effort, summary = M.REASONING_SUMMARY}
end

-- The request body. Every field here is one pi builds for this route, with two named exceptions:
-- `max_output_tokens` (pi does not send it on this route and clamps against the model's own window
-- instead; we send the caller's cap when there is one, and the live check records that the endpoint
-- accepts it) and `strict` on tools (pi sends `strict: null`; we omit the key, which is the same
-- request as far as the endpoint's schema validation is concerned).
function M.body(model, messages, tools, opts, selected, entry)
  opts = opts or {}
  local instructions, items = M.items(messages, entry)
  local body = {
    model = model,
    store = false,
    stream = true,
    instructions = instructions ~= '' and instructions or M.DEFAULT_INSTRUCTIONS,
    input = items,
    text = {verbosity = M.TEXT_VERBOSITY},
    include = M.INCLUDE,
    tool_choice = 'auto',
    parallel_tool_calls = M.PARALLEL_TOOL_CALLS,
  }
  if opts.session_id and opts.session_id ~= '' then body.prompt_cache_key = opts.session_id end
  if tools and #tools > 0 then
    local converted = {}
    for _, tool in ipairs(tools) do
      local callee = tool['function'] or tool
      converted[#converted + 1] = {type = 'function', name = callee.name,
        description = callee.description, parameters = callee.parameters}
    end
    body.tools = converted
  end
  if opts.max_output then body.max_output_tokens = opts.max_output end
  local reasoning = M.reasoning_field(entry, selected)
  if reasoning then body.reasoning = reasoning end
  return body
end

-- ---------------------------------------------------------------------------------------------
-- SSE framing
-- ---------------------------------------------------------------------------------------------

-- A Server-Sent-Events *frame* reader: feed it lines, get (event name, data payload) back.
--
-- The frame is not a line. A frame is one or more `data:` lines ended by a blank line, an event name
-- may precede them, and a line beginning with `:` is a comment (the endpoint sends keep-alives). A
-- reader that treats every `data:` line as an event loses every payload that spans lines, which is
-- how a JSON body split by the network turns into "the provider sent nothing".
function M.framing(on_event)
  local name, data = '', {}
  local function dispatch()
    if #data == 0 and name == '' then return end
    local payload = table.concat(data, '\n')
    local event_name = name
    name, data = '', {}
    if payload == '' and event_name == '' then return end
    on_event(event_name, payload)
  end
  return function(line)
    line = tostring(line or '')
    if line == '' then
      dispatch()
      return
    end
    if line:sub(1, 1) == ':' then return end          -- a comment, e.g. a keep-alive
    local field, rest = line:match('^([^:]*):(.*)$')
    if not field then return end                      -- a bare field name has no value to read
    if rest:sub(1, 1) == ' ' then rest = rest:sub(2) end
    if field == 'event' then
      name = rest
    elseif field == 'data' then
      data[#data + 1] = rest
    end
    -- `id` and `retry` are framing the endpoint does not use here; they are read and ignored.
  end
end

-- ---------------------------------------------------------------------------------------------
-- The event mapping
-- ---------------------------------------------------------------------------------------------

-- One response, built from its events. Kept separate from the transport so the fixture test can
-- drive it with recorded bytes and no socket at all.
--
-- The phase rule this preserves, and must keep preserving: text arrives *provisionally* as
-- `pending_delta`, and is resolved to `commentary` or to the answer when the completed message item
-- says which it was. Only text the response already knows is the final answer streams as `delta`
-- while it arrives. Flattening the two would put a model's running commentary into the answer, and
-- the UI's commentary balloons, the reasoning fold and the tool-decision telemetry all read this.
function M.session(opts)
  opts = opts or {}
  local stream_id = opts.stream_id or 'stream'
  local emit = opts.emit or function() end
  local state = {
    started = opts.started_ms or (host.monotonic_ms and host.monotonic_ms() or 0),
    events = {},
    slots = {},
    blocks = {},
    decisions = {},
    streamed_final = {},
    commentary = {},
    commentary_ids = {},
    reasoning = {},
    ttft = nil,
    request_id = nil,
    stop_reason = 'pending',
    status = nil,
    incomplete_reason = nil,
    usage = nil,
    terminal = false,
    finished = false,
    event_count = 0,
    last_event = '',
  }
  state.time = function()
    if not host.monotonic_ms then return 0 end
    return host.monotonic_ms() - state.started
  end

  local function mark_first_token()
    if not state.ttft then state.ttft = state.time() end
  end

  local function publish_decision(decision, complete, previous_id)
    local text = (decision.preview or '') ..
      (decision.truncated and '\u{2026} [preview only; complete arguments in result]' or '')
    local event = {type = 'decision', call_id = decision.id, name = decision.name,
      arguments_text = text, complete = complete}
    if previous_id and previous_id ~= decision.id then event.previous_call_id = previous_id end
    if decision.truncated then event.arguments_truncated = true end
    emit(event)
  end

  local function apply_phase(item)
    if type(item) == 'table' and item.type == 'message' and item.phase == 'final_answer' then
      state.stop_reason = 'stop'
    end
  end

  local function create_slot(output_index, item)
    if type(item) ~= 'table' then return nil end
    local slot
    if item.type == 'reasoning' then
      slot = {kind = 'thinking', text = ''}
      state.blocks[#state.blocks + 1] = {kind = 'thinking', text = ''}
    elseif item.type == 'message' then
      apply_phase(item)
      slot = {kind = 'text', text = '', phase = nil}
      state.blocks[#state.blocks + 1] = {kind = 'text', text = '', phase = nil}
    elseif item.type == 'function_call' or item.type == 'custom_tool_call' then
      local id = item.call_id and (tostring(item.call_id) .. '|' .. tostring(item.id or '')) or nil
      slot = {kind = 'tool', id = id, name = item.name or '', arguments = {}, partial_json = item.arguments or ''}
      state.blocks[#state.blocks + 1] = {kind = 'tool', id = id, name = item.name or '', arguments = {}}
    else
      return nil
    end
    slot.index = #state.blocks
    slot.block = state.blocks[#state.blocks]
    state.slots[output_index] = slot
    return slot
  end

  local function slot_for(output_index, kind, item)
    local slot = state.slots[output_index]
    if slot and slot.kind == kind then return slot end
    if slot then return nil end
    return create_slot(output_index, item)
  end

  local function text_delta(slot, delta)
    state.blocks[slot.index].text = state.blocks[slot.index].text .. delta
    if state.stop_reason == 'stop' then
      emit({type = 'delta', text = delta})
      state.streamed_final[slot.index] = true
    else
      emit({type = 'pending_delta', pending_id = stream_id .. ':' .. slot.index, text = delta})
    end
  end

  local function tool_delta(slot, delta)
    state.blocks[slot.index].partial_json = (state.blocks[slot.index].partial_json or '') .. delta
    local decision = state.decisions[slot.index]
    if not decision then
      decision = {id = slot.id or ('wire-' .. slot.index), name = slot.name, preview = '',
        truncated = false, announced = false}
      state.decisions[slot.index] = decision
    end
    if slot.name and slot.name ~= '' then decision.name = slot.name end
    local room = M.DECISION_PREVIEW_CHARS - codepoints(decision.preview)
    decision.preview = decision.preview .. preview(delta, math.max(0, room))
    if codepoints(delta) > room then decision.truncated = true end
    if #delta > 0 and not decision.announced then
      decision.announced = true
      if decision.truncated then decision.truncation_announced = true end
      publish_decision(decision, false)
    elseif decision.truncated and not decision.truncation_announced then
      decision.truncation_announced = true
      publish_decision(decision, false)
    end
  end

  local function finalize(response)
    state.terminal = true
    state.status = response and response.status or nil
    state.incomplete_reason = response and response.incomplete_details
      and response.incomplete_details.reason or nil
    if response and response.id then state.request_id = response.id end
    local usage = response and response.usage
    if type(usage) == 'table' then
      local input_details = usage.input_tokens_details or {}
      local output_details = usage.output_tokens_details or {}
      state.usage = {
        prompt_tokens = usage.input_tokens or 0,
        completion_tokens = usage.output_tokens or 0,
        total_tokens = usage.total_tokens or 0,
        prompt_tokens_details = {cached_tokens = input_details.cached_tokens or 0},
        completion_tokens_details = {reasoning_tokens = output_details.reasoning_tokens or 0},
      }
    end
    local status = state.status
    if status == nil or status == 'completed' or status == 'in_progress' or status == 'queued' then
      state.stop_reason = 'stop'
    elseif status == 'incomplete' then
      state.stop_reason = state.incomplete_reason == 'max_output_tokens' and 'length' or 'error'
      if state.stop_reason == 'error' then
        state.error_message = state.incomplete_reason and
          ('Response incomplete: ' .. tostring(state.incomplete_reason)) or
          'Response incomplete without a provider reason'
      end
    else
      -- 'failed' and 'cancelled'
      state.stop_reason = 'error'
    end
    local has_tool = false
    for _, block in ipairs(state.blocks) do
      if block.kind == 'tool' then has_tool = true end
    end
    if has_tool and state.stop_reason == 'stop' then state.stop_reason = 'toolUse' end
  end

  local function raise(code)
    error(code, 0)
  end

  local handlers = {
    ['response.created'] = function(event)
      if event.response and event.response.id then state.request_id = event.response.id end
    end,
    ['response.output_item.added'] = function(event)
      create_slot(event.output_index, event.item)
    end,
    ['response.output_text.delta'] = function(event)
      local slot = slot_for(event.output_index, 'text', event.item)
      if not slot then return end
      mark_first_token()
      text_delta(slot, event.delta or '')
    end,
    ['response.refusal.delta'] = function(event)
      local slot = slot_for(event.output_index, 'text', event.item)
      if not slot then return end
      mark_first_token()
      text_delta(slot, event.delta or '')
    end,
    ['response.reasoning_summary_text.delta'] = function(event)
      local slot = slot_for(event.output_index, 'thinking', event.item)
      if not slot then return end
      mark_first_token()
      state.blocks[slot.index].text = state.blocks[slot.index].text .. (event.delta or '')
      emit({type = 'reasoning', text = event.delta or '', chars = codepoints(state.blocks[slot.index].text)})
    end,
    ['response.reasoning_text.delta'] = function(event)
      local slot = slot_for(event.output_index, 'thinking', event.item)
      if not slot then return end
      mark_first_token()
      state.blocks[slot.index].text = state.blocks[slot.index].text .. (event.delta or '')
      emit({type = 'reasoning', text = event.delta or '', chars = codepoints(state.blocks[slot.index].text)})
    end,
    ['response.reasoning_summary_part.done'] = function(event)
      local slot = slot_for(event.output_index, 'thinking', event.item)
      if not slot then return end
      -- A part boundary is a paragraph boundary in the reasoning fold; pi inserts the same two
      -- newlines, and the fold relies on them to separate two thoughts that are not one sentence.
      state.blocks[slot.index].text = state.blocks[slot.index].text .. '\n\n'
      emit({type = 'reasoning', text = '\n\n', chars = codepoints(state.blocks[slot.index].text)})
    end,
    ['response.function_call_arguments.delta'] = function(event)
      local slot = slot_for(event.output_index, 'tool', event.item)
      if not slot then return end
      mark_first_token()
      tool_delta(slot, event.delta or '')
    end,
    ['response.function_call_arguments.done'] = function(event)
      local slot = slot_for(event.output_index, 'tool', event.item)
      if not slot then return end
      local previous = state.blocks[slot.index].partial_json or ''
      local final = event.arguments or ''
      state.blocks[slot.index].partial_json = final
      -- Only the part that had not already streamed is a delta: re-emitting the whole payload on
      -- every argument event would be quadratic on the wire for one large tool call.
      if previous ~= '' and final:sub(1, #previous) == previous then
        tool_delta(slot, final:sub(#previous + 1))
      elseif previous == '' then
        tool_delta(slot, final)
      end
    end,
    ['response.output_item.done'] = function(event)
      local item = event.item
      if type(item) ~= 'table' then return end
      apply_phase(item)
      local slot = state.slots[event.output_index] or create_slot(event.output_index, item)
      if not slot then return end
      if item.type == 'reasoning' and slot.kind == 'thinking' then
        local summary = {}
        for _, part in ipairs(item.summary or {}) do summary[#summary + 1] = part.text or '' end
        local content = {}
        for _, part in ipairs(item.content or {}) do content[#content + 1] = part.text or '' end
        local joined = table.concat(summary, '\n\n')
        if joined == '' then joined = table.concat(content, '\n\n') end
        if joined ~= '' then state.blocks[slot.index].text = joined end
        state.slots[event.output_index] = nil
      elseif item.type == 'message' and slot.kind == 'text' then
        local text = {}
        for _, part in ipairs(item.content or {}) do
          text[#text + 1] = part.type == 'output_text' and (part.text or '') or (part.refusal or '')
        end
        local joined = table.concat(text, '')
        if joined ~= '' or state.blocks[slot.index].text == '' then
          state.blocks[slot.index].text = joined
        end
        local phase = (item.phase == 'commentary' or item.phase == 'final_answer') and item.phase or ''
        state.blocks[slot.index].phase = phase
        local pending_id = stream_id .. ':' .. slot.index
        if phase == 'commentary' then
          local message_id = opts.new_id and opts.new_id() or nil
          state.commentary_ids[slot.index] = message_id
          emit({type = 'commentary', pending_id = pending_id, message_id = message_id,
            text = state.blocks[slot.index].text})
        elseif not state.streamed_final[slot.index] then
          emit({type = 'delta', pending_id = pending_id, text = state.blocks[slot.index].text})
        end
        state.streamed_final[slot.index] = nil
        state.slots[event.output_index] = nil
      elseif (item.type == 'function_call' or item.type == 'custom_tool_call') and slot.kind == 'tool' then
        mark_first_token()
        local text = item.arguments
        if text == nil or text == '' then text = state.blocks[slot.index].partial_json or '' end
        if text == '' then text = '{}' end
        local ok, arguments = pcall(json.decode, text)
        if not ok or type(arguments) ~= 'table' then
          raise('subscription_tool_arguments_unparseable: ' .. tostring(item.name or 'tool'))
        end
        state.blocks[slot.index].arguments = arguments
        state.blocks[slot.index].partial_json = nil
        state.blocks[slot.index].id = slot.id
        local previous_id = state.decisions[slot.index] and state.decisions[slot.index].id or nil
        local decision = state.decisions[slot.index] or
          {id = slot.id or ('wire-' .. slot.index), name = slot.name, preview = ''}
        decision.id = slot.id or decision.id
        decision.name = slot.name ~= '' and slot.name or decision.name
        local encoded = json.encode(arguments)
        decision.preview = preview(encoded, M.DECISION_PREVIEW_CHARS)
        decision.truncated = codepoints(encoded) > M.DECISION_PREVIEW_CHARS
        publish_decision(decision, true, previous_id)
        state.decisions[slot.index] = nil
        state.slots[event.output_index] = nil
      end
    end,
    ['response.completed'] = function(event) finalize(event.response) end,
    ['response.incomplete'] = function(event) finalize(event.response) end,
    ['response.failed'] = function(event)
      local response = event.response or {}
      local failure = response.error
      local details = response.incomplete_details
      local message
      if failure then
        message = tostring(failure.code or 'unknown') .. ': ' .. tostring(failure.message or 'no message')
      elseif details and details.reason then
        message = 'incomplete: ' .. tostring(details.reason)
      else
        message = 'Unknown error (no error details in response)'
      end
      state.terminal = true
      raise('subscription_response_failed: ' .. message)
    end,
    ['error'] = function(event)
      state.terminal = true
      raise('subscription_provider_error: Error Code ' .. tostring(event.code) .. ': ' ..
        tostring(event.message))
    end,
  }

  local session = {}

  -- One event, already framed and JSON-decoded. Unparseable JSON is a protocol failure, not a
  -- skipped line: a stream whose one interesting event failed to parse looks exactly like a stream
  -- that never sent it, which is the confusion this route cannot afford.
  function session.event(name, data)
    if state.finished then return end
    local text = tostring(data or '')
    if text == '[DONE]' then return end
    local ok, event = pcall(json.decode, text)
    if not ok or type(event) ~= 'table' then
      raise('subscription_event_unparseable: the endpoint sent a frame that is not JSON')
    end
    state.event_count = state.event_count + 1
    local kind = type(event.type) == 'string' and event.type or name
    state.last_event = kind or ''
    local handler = handlers[kind or '']
    if handler then handler(event) end
    state.events[#state.events + 1] = kind
  end

  session.line = M.framing(session.event)

  -- The result, or a loud failure. A stream that ended without a terminal event is reported as a
  -- truncated stream and never as a short answer, whatever arrived before it.
  function session.result(model)
    if not state.terminal then
      error(string.format(
        'subscription_stream_truncated: the stream ended after %d event(s) (last: %s) with no ' ..
        'terminal response event; a partial answer is not an answer',
        state.event_count, state.last_event ~= '' and state.last_event or 'none'), 0)
    end
    if state.status == 'failed' or state.status == 'cancelled' then
      raise('subscription_response_' .. tostring(state.status))
    end
    if state.stop_reason == 'error' then
      raise('subscription_response_error: ' .. tostring(state.error_message or 'the provider ' ..
        'reported an error after the stream ended'))
    end
    local answer, commentary = {}, {}
    for index, block in ipairs(state.blocks) do
      if block.kind == 'text' then
        if block.phase == 'commentary' then
          commentary[#commentary + 1] = {content = block.text, id = state.commentary_ids[index],
            pending_id = stream_id .. ':' .. index}
        else
          answer[#answer + 1] = {phase = block.phase or '', text = block.text}
        end
      end
    end
    local tool_calls = {}
    for _, block in ipairs(state.blocks) do
      if block.kind == 'tool' then
        tool_calls[#tool_calls + 1] = {id = block.id or '', type = 'function',
          ['function'] = {name = block.name or '', arguments = json.encode(block.arguments or {})}}
      end
    end
    local finish = state.stop_reason == 'length' and 'length'
      or state.stop_reason == 'toolUse' and 'tool_calls' or 'stop'
    local phase = ''
    if #answer > 0 then phase = answer[#answer].phase end
    return {
      content = table.concat((function()
        local texts = {}
        for _, block in ipairs(answer) do texts[#texts + 1] = block.text end
        return texts
      end)(), ''),
      commentary = commentary,
      final_phase = phase,
      reasoning = (function()
        local texts = {}
        for _, block in ipairs(state.blocks) do
          if block.kind == 'thinking' then texts[#texts + 1] = block.text end
        end
        return table.concat(texts, '')
      end)(),
      tool_calls = tool_calls,
      finish_reason = finish,
      stream_complete = true,
      model = model,
      request_id = state.request_id,
      ttft_ms = state.ttft,
      usage = state.usage,
    }, state
  end

  return session
end

-- ---------------------------------------------------------------------------------------------
-- The transport
-- ---------------------------------------------------------------------------------------------

-- One completion over `host.http_sse`. Same inputs and the same result contract as the pi-backed
-- path it replaces: `(model, messages, tools, stream, opts, reasoning)` in, the result table
-- provider.lua reads out.
function M.complete(model, messages, tools, stream, opts, reasoning)
  opts = opts or {}
  local entry = catalogue.get(model)
  if not entry then
    error('subscription_model_unknown: this route\'s catalogue does not publish ' .. tostring(model) ..
      '; update lua/core/openai_sub_catalogue.lua', 0)
  end
  -- Both values from the seam. `absent` is the credential lane's taxonomy - `subscription_
  -- credentials_absent`, `refresh_rejected:<status>`, `locked`, `flow_expired` - and it is what the
  -- turn fails with, so the person reading the error is told which of the four happened instead of
  -- reading that a credential was `nil`. `error(..., 0)` keeps the code first in the text with no
  -- `file:line:` prepended: the code is the thing a caller greps and a human recognises.
  local credential, absent = M.credential_provider()
  if not credential then
    error(tostring(absent or credential_failure('subscription_credential_missing',
      'the credential seam returned no credential and no failure of its own')), 0)
  end
  local stream_id = opts.stream_id or (host.uuid and host.uuid() or 'stream')
  local timeout_ms = (tonumber(opts.timeout_seconds) or M.request_timeout()) * 1000
  -- `reasoning` is what the run asked for: a level name, or a table with `selected` (what
  -- provider.lua's request options carry).
  local selected = type(reasoning) == 'table' and reasoning.selected or reasoning
  local body = M.body(model, messages, tools, opts, selected, entry)
  local headers = M.headers(credential, opts.session_id)
  local emit = function(event)
    if stream then host.stream(json.encode(event)) end
  end
  local started = host.monotonic_ms and host.monotonic_ms() or 0
  local session = M.session({stream_id = stream_id, emit = emit, started_ms = started,
    new_id = host.uuid})
  local line = session.line
  local counted = 0
  local observe = opts.on_line    -- a diagnostic/recording seam; nothing in the runtime path sets it
  -- The callback's own stop, remembered so it can be re-raised as itself. Raising inside the
  -- callback is what ends the read, but the transport reports a callback failure as
  -- `subscription_transport_line_callback_failed` with a Lua traceback that carries a local file
  -- path and line number - measured on a real request cut by `WASM_AGENT_SUBSCRIPTION_TIMEOUT=1`,
  -- which raised `.../subscription_wire.lua:897: subscription_timeout: ...` rather than the
  -- `subscription_timeout` this route documents. A caller matching on the documented name would
  -- not find it, so the two names are raised from here instead.
  local stopped_by = nil
  local outcome = host.http_sse('POST', M.ENDPOINT, json.encode(headers), json.encode(body),
    function(text)
      -- Cancellation and the deadline are checked here, on every line, because this is inside the
      -- read: raising from here is what ends a run that has been cancelled or has run out of budget,
      -- rather than letting it finish a stream nobody is waiting for.
      if host.run_cancelled then
        local cancelled = json.decode(host.run_cancelled())
        if cancelled.cancelled then stopped_by = 'run_cancelled'; error(stopped_by, 0) end
      end
      if host.monotonic_ms and host.monotonic_ms() - started > timeout_ms then
        stopped_by = string.format(
          'subscription_timeout: no completion within %ds (WASM_AGENT_SUBSCRIPTION_TIMEOUT); the ' ..
          'stream was stopped after %d line(s)', math.floor(timeout_ms / 1000), counted)
        error(stopped_by, 0)
      end
      counted = counted + 1
      if host.beat then host.beat() end
      if observe then observe(text) end
      line(text)
    end)
  if stopped_by then error(stopped_by, 0) end
  local decoded = json.decode(outcome)
  if decoded.error then
    if decoded.error == 'run_cancelled' then error('run_cancelled', 0) end
    error(string.format('subscription_transport_%s: %s (after %s line(s))',
      tostring(decoded.termination or 'failed'), tostring(decoded.error),
      tostring(decoded.lines or counted)), 0)
  end
  if decoded.status ~= 200 then
    error(string.format('subscription_http_%s: %s', tostring(decoded.status),
      tostring(decoded.body or ''):sub(1, 240)), 0)
  end
  local result, state = session.result(model)
  -- Streaming telemetry, so an incomplete stream can say how it ended rather than only that it did.
  result.commentary_streamed = stream and (#result.commentary > 0) or false
  result.transport = 'native-codex-responses'
  result.termination = decoded.termination
  result.lines = decoded.lines
  result.events = state.event_count
  result.saw_terminal_event = true
  return result
end

-- ---------------------------------------------------------------------------------------------
-- The usage windows (the same credential, the other endpoint)
-- ---------------------------------------------------------------------------------------------

-- Rate-limit windows, in the shape the CLI already shows: `rolling`, `weekly`, `monthly`, each
-- `{status, percent, resetsAt}`. Ported from the bridge it replaces - same keys, same fallbacks,
-- same ISO-8601 instants - because the UI reads those names.
function M.limits()
  local credential, absent = M.credential_provider()
  -- Limits are display data, so an absent credential stays `{}` - the same answer this file already
  -- gives for an account with no id, and provider.lua's caller already treats as "nothing to show".
  -- The taxonomy leaves by the second return value instead of being swallowed, so a caller that
  -- prints it can say which of the four it was.
  if not credential then
    return {}, tostring(absent or credential_failure('subscription_credential_missing',
      'the credential seam returned no credential and no failure of its own'))
  end
  if not credential.account_id or credential.account_id == '' then return {} end
  local response = json.decode(host.http('GET', M.USAGE_ENDPOINT, json.encode({
    ['Accept'] = 'application/json',
    ['Authorization'] = 'Bearer ' .. credential.access,
    ['ChatGPT-Account-Id'] = tostring(credential.account_id),
    ['User-Agent'] = M.USER_AGENT,
  })))
  if response.error then error('subscription_limits_error: ' .. tostring(response.error)) end
  if response.status ~= 200 then
    error('subscription_limits_http_' .. tostring(response.status) .. ': ' ..
      tostring(response.body or ''):sub(1, 240))
  end
  local payload = json.decode(response.body or '{}')
  local root = payload.rate_limits or payload.rate_limit or {}
  local limits = {}
  local function add_window(window, fallback)
    if type(window) ~= 'table' then return end
    local percent = tonumber(window.used_percent)
    if not percent then return end
    local duration = tonumber(window.limit_window_seconds)
    local key = duration and
      (duration >= 2592000 and 'monthly' or duration >= 172800 and 'weekly' or 'rolling') or fallback
    local reset = tonumber(window.reset_at)
    limits[key] = {status = window.limit_reached and 'limited' or 'available', percent = percent,
      resetsAt = reset and os.date('!%Y-%m-%dT%H:%M:%S', reset) .. '.000Z' or nil}
  end
  add_window(root.primary_window or root.primary or root.five_hour, 'rolling')
  add_window(root.secondary_window or root.secondary or root.weekly, 'weekly')
  add_window(root.tertiary_window or root.tertiary or root.monthly_window or root.monthly, 'monthly')
  return limits
end

return M
