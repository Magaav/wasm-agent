-- Parity: the same prompt, once through Pi's adapter and once through wasm-agent's own wire.
--
-- This is the check that decides whether the native transport is a *replacement* or a second
-- behaviour. It runs both routes for the same input and compares the fields the tool loop reads:
-- answer content, finish_reason, final phase, commentary, tool calls (name and parsed arguments) and
-- usage. A difference is not automatically a defect - two clients can report the same exchange
-- slightly differently - but an unexplained one is, so the script prints both sides instead of a
-- pass/fail it invented.
--
-- It needs the network, a live credential, Node and an installed Pi (the pi route), so it is not in
-- the gate: run it by hand.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/check-subscription-wire-parity.lua \
--     <repo>/rust/target/release/wa --db <scratch>.db
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local subscription = dofile('lua/core/openai_sub.lua')

local MODEL = host.getenv('WA_PARITY_MODEL') or 'gpt-6-luna'
local LEVEL = host.getenv('WA_PARITY_LEVEL') or 'low'
local SESSION = host.getenv('WA_PARITY_SESSION') or 'wa-parity-fixture'
local TIMEOUT = 300

-- The credential: the native route needs the credential lane's seam, whose name is
-- `lua/core/openai_sub_auth.lua`. The pi route resolves its own. Stand-in, read-only, never
-- printed - see the live check for the same note.
local wire_credential
do
  local ok, module = pcall(dofile, 'lua/core/openai_sub_auth.lua')
  if ok and type(module) == 'table' then
    wire_credential = module.token
  else
    local directory = host.getenv('PI_CODING_AGENT_DIR') or (paths.home() .. '/.pi/agent')
    wire_credential = function()
      local auth = json.decode(host.read_file(directory .. '/auth.json') or '{}')
      local oauth = auth['openai-codex'] or {}
      return {access = oauth.access, account_id = oauth.accountId, expires = oauth.expires}
    end
  end
end

local native_getenv = host.getenv
local transport_override
host.getenv = function(key)
  if key == 'WASM_AGENT_SUBSCRIPTION_TRANSPORT' and transport_override then
    return transport_override
  end
  return native_getenv(key)
end

local function run(transport, label, messages, tools)
  transport_override = transport
  if transport == 'native' then
    -- The native route calls the credential seam; the pi route never sees it. Set on the wire
    -- instance this route actually uses - a second `dofile` would be a different module.
    subscription.wire().credential_provider = wire_credential
  end
  local started = math.floor(host.monotonic_ms())
  local ok, result = pcall(subscription.complete, MODEL, messages, tools, false,
    {session_id = SESSION, timeout_seconds = TIMEOUT}, {selected = LEVEL})
  local elapsed = math.floor(host.monotonic_ms()) - started
  if not ok then
    print(string.format('%s: FAILED after %dms: %s', label, elapsed, tostring(result)))
    return nil, tostring(result)
  end
  print(string.format('%s: %dms %s', label, elapsed, json.encode({
    content = result.content, finish_reason = result.finish_reason,
    final_phase = result.final_phase, commentary = #(result.commentary or {}),
    tool_calls = #(result.tool_calls or {}), usage = result.usage,
    request_id = result.request_id, stream_complete = result.stream_complete})))
  return result, nil
end

local function compare(label, left, right)
  local function same(a, b) return a == b end
  local rows = {}
  local function row(field, a, b, verdict)
    -- A nil verdict is a field that is *printed* rather than compared - the arguments text is one,
    -- because Lua's encoder is canonical and Pi serialises in the endpoint's order. Saying "DIFFERS"
    -- for a field nobody compared would be a claim this check is not making.
    local note = verdict == nil and 'PRINTED (not compared)' or (verdict and 'SAME' or 'DIFFERS')
    rows[#rows + 1] = string.format('  %-22s %-40s %-40s %s', field, tostring(a), tostring(b), note)
  end
  row('content', left.content, right.content, same(left.content, right.content))
  row('finish_reason', left.finish_reason, right.finish_reason,
    same(left.finish_reason, right.finish_reason))
  row('final_phase', left.final_phase, right.final_phase, same(left.final_phase, right.final_phase))
  row('prompt_tokens', left.usage and left.usage.prompt_tokens, right.usage and right.usage.prompt_tokens,
    same(left.usage and left.usage.prompt_tokens, right.usage and right.usage.prompt_tokens))
  row('cached_tokens',
    left.usage and left.usage.prompt_tokens_details and left.usage.prompt_tokens_details.cached_tokens,
    right.usage and right.usage.prompt_tokens_details and right.usage.prompt_tokens_details.cached_tokens,
    same(left.usage and left.usage.prompt_tokens_details and left.usage.prompt_tokens_details.cached_tokens,
      right.usage and right.usage.prompt_tokens_details and right.usage.prompt_tokens_details.cached_tokens))
  row('completion_tokens', left.usage and left.usage.completion_tokens,
    right.usage and right.usage.completion_tokens,
    same(left.usage and left.usage.completion_tokens, right.usage and right.usage.completion_tokens))
  row('reasoning_tokens',
    left.usage and left.usage.completion_tokens_details and left.usage.completion_tokens_details.reasoning_tokens,
    right.usage and right.usage.completion_tokens_details and right.usage.completion_tokens_details.reasoning_tokens,
    same(left.usage and left.usage.completion_tokens_details and left.usage.completion_tokens_details.reasoning_tokens,
      right.usage and right.usage.completion_tokens_details and right.usage.completion_tokens_details.reasoning_tokens))
  row('tool_calls', #(left.tool_calls or {}), #(right.tool_calls or {}),
    same(#(left.tool_calls or {}), #(right.tool_calls or {})))
  for index = 1, math.max(#(left.tool_calls or {}), #(right.tool_calls or {})) do
    local left_call, right_call = (left.tool_calls or {})[index], (right.tool_calls or {})[index]
    local left_name = left_call and left_call['function'] and left_call['function'].name
    local right_name = right_call and right_call['function'] and right_call['function'].name
    row('tool name ' .. index, left_name, right_name, same(left_name, right_name))
    local left_arguments = left_call and json.decode(left_call['function'].arguments)
    local right_arguments = right_call and json.decode(right_call['function'].arguments)
    row('tool arguments ' .. index, json.encode(left_arguments), json.encode(right_arguments),
      left_arguments ~= nil and json.encode(left_arguments) == json.encode(right_arguments))
    -- The arguments *text* is expected to differ: Lua's encoder is canonical (keys sorted) and Pi
    -- serialises in the order the endpoint sent. Both parse to the same object, which is what the
    -- tool loop uses - so the raw text is printed, not compared.
    row('tool arguments text ' .. index, left_call and left_call['function'].arguments,
      right_call and right_call['function'].arguments, nil)
  end
  print(label)
  print(table.concat(rows, '\n'))
end

local system = {role = 'system', content = 'You are a parity fixture. Be brief and exact.'}

-- Pass A: text only, no tools. The answer content is the field a reader sees, so it is compared as
-- text and not as a shape.
local plain = {system, {role = 'user', content = 'Reply with exactly this text and nothing else: PARITY-OK'}}
local pi_text = run('pi', 'pi (text)', plain, nil)
local native_text = run('native', 'native (text)', plain, nil)
if pi_text and native_text then compare('pass A: text', pi_text, native_text) end

-- Pass B: one tool call, so the call's name and parsed arguments are compared too.
local tools = {{['function'] = {name = 'get_time', description = 'Read the current time for a zone.',
  parameters = {type = 'object', properties = {zone = {type = 'string'}}, required = {'zone'}}}}}
local calling = {system, {role = 'user',
  content = 'Call the tool get_time exactly once with zone UTC. Do not write anything else.'}}
local pi_call = run('pi', 'pi (tool)', calling, tools)
local native_call = run('native', 'native (tool)', calling, tools)
if pi_call and native_call then compare('pass B: tool call', pi_call, native_call) end

assert(pi_text and native_text and pi_call and native_call, 'both routes must answer for a parity ' ..
  'claim to mean anything; a route that failed above is the finding')
assert(pi_text.content == native_text.content,
  'the two routes must agree on the answer text, or this is not a parity result but a defect: ' ..
  json.encode(pi_text.content) .. ' vs ' .. json.encode(native_text.content))
assert(pi_text.finish_reason == native_text.finish_reason, 'and on the finish reason')
print('subscription wire parity ok (both routes answered; differences above are printed, not hidden)')
