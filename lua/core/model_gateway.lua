-- The model gateway, from the loop's side (docs/MODEL-GATEWAY.md).
--
-- Today a turn's provider call is `M.complete_with` in `lua/core/provider.lua`: one endpoint, one JSON
-- body, its own retry arithmetic. With `WA_MODEL_GATEWAY=1` (or the policy setting the node maps onto
-- that variable) the call is instead *decided and made* by the `wa:model` component
-- (`rust/components/model-gateway`, `wit/model/model.wit`): the caller names a **task class** and the
-- data **label**, and gets back the model's answer with the route that served it. **Without the flag
-- every line below is unused and the native path runs exactly as it always ran.**
--
-- Two things live here rather than in the component, because they are the loop's own state:
--
--   * the *session's label*: the strictest label seen in the session, set by sources (`note`), read by
--     every call (`session_label`). A session with no recorded source fails closed as `client`, so a
--     wiring mistake loses capability instead of leaking a client's message to a public provider;
--   * the *wire shape*: this tree's transport to the host is JSON (`host.memory`, `host.selfloop` do the
--     same), and the host turns it into the typed records of `wit/model/model.wit` before the component
--     sees anything. `scripts/test-model-gateway.lua` asserts the shape, so a change here cannot drift
--     from the WIT without a test failing.
--
-- What is deliberately absent: any credential (the component names a secret; the kernel adds its value),
-- any retry, fallback, breaker or budget arithmetic (that is the component's, and it is unit-tested
-- there), and any reordering of messages or tools (a moved byte is a prompt-cache miss).
local json = dofile("lua/vendor/json.lua")
local state = dofile("lua/core/state.lua")

local M = {}

-- Strictness order. `client` is the strictest (another person's data), `public` the weakest.
local RANK = { public = 1, internal = 2, client = 3 }
M.LABELS = { "public", "internal", "client" }
-- Where the per-session labels are kept. One small file, pruned to the newest entries.
local LABEL_FILE = "model_labels"
local LABEL_LIMIT = 200

local function valid_label(value)
  return type(value) == "string" and RANK[value] ~= nil
end

local function strictest(a, b)
  if not valid_label(a) then return b end
  if not valid_label(b) then return a end
  return RANK[a] >= RANK[b] and a or b
end
M.strictest = strictest

-- The flag. Read once, when the module loads, exactly as every other seam in this tree reads it.
local enabled = (function()
  local ok, value = pcall(host.getenv, "WA_MODEL_GATEWAY")
  return ok and tostring(value or "") == "1"
end)()

function M.enabled() return enabled end

-- --------------------------------------------------------------------------------------- the label

-- A source's label (`docs/MODEL-GATEWAY.md`, "Data labels"). A channel message is `client` unless the
-- chat is the operator's own; the operator's own typing is `internal`; a tool result is never weaker
-- than the thing it read; anything unclassified fails closed.
function M.label_of_source(source)
  if type(source) ~= "table" then return "client" end
  if source.kind == "channel" then
    return source.own_chat and "internal" or "client"
  elseif source.kind == "operator" then
    return "internal"
  elseif source.kind == "tool_result" or source.kind == "model" then
    return valid_label(source.inherited) and source.inherited or "client"
  elseif source.kind == "node" then
    return "internal"
  end
  return "client"
end

local function load_labels()
  local text = state.read(LABEL_FILE)
  if type(text) ~= "string" or text == "" then return {}, 0 end
  local ok, decoded = pcall(json.decode, text)
  if not ok or type(decoded) ~= "table" then return {}, 0 end
  local labels = decoded.labels or {}
  return labels, tonumber(decoded.seq) or 0
end

local function save_labels(labels, seq)
  local names = {}
  for name in pairs(labels) do names[#names + 1] = name end
  table.sort(names)
  if #names > LABEL_LIMIT then
    -- The oldest sessions fall out first (their sequence number is the order note() wrote them in).
    table.sort(names, function(a, b) return (labels[a].seq or 0) < (labels[b].seq or 0) end)
    for index = 1, #names - LABEL_LIMIT do labels[names[index]] = nil end
  end
  pcall(state.write, LABEL_FILE, json.encode({ seq = seq, labels = labels }))
end

-- Record a source seen in `session`, and answer the session's label after it.
function M.note(session, source)
  session = tostring(session or "")
  if session == "" then return "client" end
  local labels, seq = load_labels()
  seq = seq + 1
  local label = M.label_of_source(source)
  local current = labels[session]
  local merged = strictest(current and current.label or nil, label)
  labels[session] = { label = merged, seq = seq }
  save_labels(labels, seq)
  return merged
end

-- The session's label. No recorded source means `client`: a session whose origin nobody labelled is not
-- one to send to a provider that may only carry public data.
function M.session_label(session)
  local labels = load_labels()
  local entry = labels[tostring(session or "")]
  if type(entry) == "table" and valid_label(entry.label) then return entry.label end
  return "client"
end

function M.forget(session)
  local labels, seq = load_labels()
  labels[tostring(session or "")] = nil
  save_labels(labels, seq)
end

-- --------------------------------------------------------------------------------------- the call

-- The class a call asks for. An explicit class wins; otherwise the loop's `kind` decides: a compaction
-- or a summary is `cheap`, a vision turn is `vision`, code mode's turns are `code`, the plan/step rounds
-- are `plan`, and anything else is `default`.
function M.class_for(opts)
  opts = opts or {}
  if type(opts.class) == "string" and opts.class ~= "" then return opts.class end
  local kind = tostring(opts.kind or "")
  if kind == "compact" or kind == "compaction" or kind == "summary" or kind == "title" then return "cheap" end
  if kind == "vision" or kind == "image" then return "vision" end
  if kind == "codemode" or kind == "code_mode" or kind == "edit" then return "code" end
  if kind == "plan" or kind == "planning" or kind == "decision" then return "plan" end
  if (opts.images or 0) > 0 then return "vision" end
  return "default"
end

-- The messages of the seam: role, ordered parts, tool calls, the tool-call id, and the one cache
-- breakpoint. Nothing is merged or sorted; a system message that the loop put in the middle stays there
-- and the provider adapter refuses the request rather than moving it.
local function wire_message(message, breakpoint)
  local role = tostring(message.role or "user")
  local parts = {}
  local content = message.content
  if type(content) == "table" then
    for _, part in ipairs(content) do
      if type(part) == "table" and (part.type == "text" or part.text ~= nil) then
        parts[#parts + 1] = { type = "text", text = tostring(part.text or "") }
      elseif type(part) == "table" and part.type == "image" then
        parts[#parts + 1] = {
          type = "image",
          mime = tostring(part.mime or "image/png"),
          base64 = tostring(part.data or ""),
        }
      end
    end
  elseif content ~= nil then
    parts[#parts + 1] = { type = "text", text = tostring(content) }
  end
  local calls = {}
  for _, call in ipairs(message.tool_calls or {}) do
    calls[#calls + 1] = {
      id = tostring(call.id or ""),
      name = tostring(call["function"] and call["function"].name or call.name or ""),
      arguments_json = tostring(call["function"] and call["function"].arguments or call.arguments_json or "{}"),
    }
  end
  return {
    role = role,
    parts = parts,
    tool_calls = calls,
    tool_call_id = message.tool_call_id,
    name = message.name,
    cache_breakpoint = breakpoint and true or false,
  }
end

-- The request the host turns into `chat-request`. `opts.model` may be a model ref (`provider/model`) or
-- a bare model id, which applies to whichever endpoint the loop has active.
function M.build_request(model, messages, tools, opts)
  opts = opts or {}
  local ref = nil
  local explicit = opts.model_ref or opts.model
  if type(explicit) == "string" and explicit:find("/", 1, true) then
    local provider, name = explicit:match("^([^/]+)/(.+)$")
    if provider and name then ref = { provider = provider, model = name } end
  end
  local list = {}
  for index, message in ipairs(messages or {}) do
    -- The breakpoint goes after the last message the loop marked, or after the last tool definition's
    -- owner when the caller asked for caching and marked nothing: it never moves a message.
    local breakpoint = message.cache_breakpoint
    if breakpoint == nil and index == opts.breakpoint_index then breakpoint = true end
    list[index] = wire_message(message, breakpoint)
  end
  local tool_list = {}
  for index, tool in ipairs(tools or {}) do
    tool_list[index] = {
      name = tostring(tool.name or tool["function"] and tool["function"].name or ""),
      description = tostring(tool.description or tool["function"] and tool["function"].description or ""),
      schema_json = json.encode(tool.schema or tool.parameters or tool["function"] and tool["function"].parameters or {}),
    }
  end
  return {
    session = tostring(opts.session_id or opts.session or "session"),
    class = M.class_for(opts),
    model = ref,
    label = valid_label(opts.label) and opts.label or M.session_label(opts.session_id or opts.session),
    messages = list,
    tools = tool_list,
    max_output_tokens = tonumber(opts.max_output_tokens or opts.max_tokens) or 4096,
    temperature = opts.temperature,
    estimated_input_tokens = tonumber(opts.estimated_input_tokens) or nil,
    timeout_ms = tonumber(opts.timeout_ms) or nil,
  }
end

-- One component call. Returns the seam's answer (which may be a refusal), or nil and the reason there is
-- none — the shape `lua/core/selfloop.lua` uses, so a missing capability falls back the same way.
local function seam(request)
  if type(host.model_gateway) ~= "function" then return nil, "component_capability_missing" end
  local ok, answer = pcall(host.model_gateway, json.encode(request))
  if not ok then return nil, "component_call_failed" end
  if type(answer) == "string" then
    local decoded_ok, decoded = pcall(json.decode, answer)
    answer = decoded_ok and decoded or nil
  end
  if type(answer) ~= "table" then return nil, "component_no_answer" end
  if not answer.ok then
    return { refused = answer.error or { code = "component_failed", reason = "the gateway answered no" } }
  end
  return answer.result or {}
end

local fallback_logged = {}
local function note_fallback(reason)
  if fallback_logged[reason] then return end
  fallback_logged[reason] = true
  pcall(host.log, "model gateway: served natively: " .. tostring(reason))
end

-- The gateway's answer as the loop's own result: the same fields `M.complete_with` returns, so the tool
-- loop, the empty-reply check and the telemetry span need no second code path.
local function as_result(answer)
  return {
    content = answer.content or "",
    commentary = "",
    reasoning = answer.reasoning or "",
    finish_reason = answer.finish_reason or "stop",
    tool_calls = answer.tool_calls or {},
    usage = answer.usage,
    model = answer.model,
    request_id = answer.request_id,
    -- The seam's own facts, kept so a cache miss and the route that produced it are readable together.
    gateway = {
      provider = answer.provider,
      model = answer.model,
      class = answer.class,
      label = answer.label,
      attempts = answer.attempts,
      cache_read_tokens = answer.usage and answer.usage.cache_read_tokens or 0,
      cache_write_tokens = answer.usage and answer.usage.cache_write_tokens or 0,
      latency_ms = answer.latency_ms,
      fallback_from = answer.fallback_from,
    },
  }
end

-- Serve one turn through the component. `provider` is `lua/core/provider.lua`, passed in so this file
-- can reuse the loop's own helpers (`visible_text`, `budget`) without requiring it back.
function M.complete(provider, model, messages, tools, stream, opts)
  opts = opts or {}
  local request = M.build_request(model, messages, tools, opts)
  local answer, reason = seam(request)
  if answer == nil then
    note_fallback(reason)
    return nil
  end
  if answer.refused then
    -- A refusal is an answer, not a reason to run the native path: the model must be told the label or
    -- the budget refused it, or the loop would retry into the same wall.
    local refusal = answer.refused
    error("model_gateway_" .. tostring(refusal.code or "refused") .. ": " .. tostring(refusal.reason or ""))
  end
  local result = as_result(answer)
  -- The gateway's stream is drained by the host before it answers, so the answer arrives whole; a caller
  -- that wants deltas gets the one delta it can honestly produce.
  if stream and opts.on_delta and result.content ~= "" then
    pcall(opts.on_delta, result.content)
  end
  return result
end

return M
