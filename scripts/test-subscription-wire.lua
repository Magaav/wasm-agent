-- The subscription wire, tested offline against real recorded wire bytes.
--
-- Hermetic: no network, no credential, no model, no Node. `host.http_sse` is replaced by a function
-- that replays `tests/fixtures/subscription/*.txt` - the bytes two real requests through
-- `scripts/check-subscription-wire-live.lua` actually received - line by line into the same callback
-- the transport would call. Everything above the socket is therefore exercised on real wire bytes:
-- the SSE framing, the event mapping, the phase distinction (`pending_delta` resolved to
-- `commentary` or to the answer), the tool-decision telemetry, the usage mapping, and the rule that
-- a stream which ends without a terminal event is an error and never a partial success.
--
-- The fixture is what makes this a test of the endpoint's real shape rather than of our idea of it:
-- if the endpoint starts sending something else, the recorded bytes stop matching and this fails.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local wire = dofile('lua/core/subscription_wire.lua')
local catalogue = dofile('lua/core/openai_sub_catalogue.lua')

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function eq(actual, expected, message)
  check(actual == expected, message .. ' (got ' .. tostring(actual) .. ', want ' ..
    tostring(expected) .. ')')
end

local FIXTURE_DIR = 'tests/fixtures/subscription/'
local function fixture(name)
  local text = host.read_file(FIXTURE_DIR .. name)
  assert(text and text ~= '', 'the recorded fixture ' .. FIXTURE_DIR .. name .. ' must be present')
  return text
end

-- The credential lane's file does not exist yet, so this file answers for it: a *stand-in*, never a
-- second read of pi's auth file - and the test below asserts that the real seam is called by name
-- and fails visibly when it is missing.
local CREDENTIAL = {access = 'fixture-access', account_id = 'fixture-account', expires = 0}
wire.credential_provider = function() return CREDENTIAL end

-- ---------------------------------------------------------------------------------------------
-- The request: headers and body
-- ---------------------------------------------------------------------------------------------
local headers = wire.headers(CREDENTIAL, 'session-fixture')
eq(headers['Authorization'], 'Bearer fixture-access', 'the bearer token is sent')
eq(headers['chatgpt-account-id'], 'fixture-account', 'the account id is sent')
eq(headers['User-Agent'], 'codex-cli', 'the client identity is the one that was measured')
eq(headers['originator'], 'codex-cli', 'and originator says the same thing, not a second claim')
eq(headers['OpenAI-Beta'], 'responses=experimental', 'the Responses beta header is sent')
eq(headers['accept'], 'text/event-stream', 'the stream is asked for, not buffered')
eq(headers['content-type'], 'application/json', 'the body is announced')
eq(headers['session-id'], 'session-fixture', 'the session id is sent when there is one')
eq(headers['x-client-request-id'], 'session-fixture', 'in both headers the endpoint reads it from')
eq(wire.headers(CREDENTIAL, nil)['session-id'], nil, 'and is not invented when there is none')

local tools = {{['function'] = {name = 'lookup_marker', description = 'lookup',
  parameters = {type = 'object', properties = {tag = {type = 'string'}}}}}}
local messages = {
  {role = 'system', content = 'fixture system'},
  {role = 'user', content = {{type = 'text', text = 'hello'},
    {type = 'image_url', image_url = {url = 'data:image/png;base64,AA=='}}}},
  {role = 'assistant', content = '', tool_calls = {{id = 'call-1|fc_item-1',
    ['function'] = {name = 'lookup_marker', arguments = '{"tag":"luna"}'}}}},
  {role = 'tool', tool_call_id = 'call-1|fc_item-1', content = 'marker'},
  {role = 'assistant', id = 'wa_fixture-message', phase = 'final_answer', content = 'phase fixture'},
}
local entry = catalogue.get('gpt-6-luna')
check(entry ~= nil, 'the catalogue must publish the id this test asks about')
local body = wire.body('gpt-6-luna', messages, tools, {session_id = 'session-fixture', max_output = 4096},
  'off', entry)
eq(body.model, 'gpt-6-luna', 'the body names the model')
eq(body.store, false, 'store is false: the endpoint refuses a stored response')
eq(body.stream, true, 'and the response is streamed')
eq(body.instructions, 'fixture system', 'the system message becomes the instructions')
eq(body.input[1].role, 'user', 'the user message is an input item')
eq(body.input[1].content[1].type, 'input_text', 'with its text part')
eq(body.input[1].content[2].type, 'input_image', 'and its image part')
eq(body.input[1].content[2].image_url, 'data:image/png;base64,AA==', 'as the data URL it arrived as')
eq(body.input[2].type, 'function_call', 'the assistant tool call is a function_call item')
eq(body.input[2].call_id, 'call-1', 'whose call id is the part before the item id')
eq(body.input[2].id, 'fc_item-1', 'and whose item id is the part after it')
eq(body.input[2].arguments, '{"tag":"luna"}', 'with its arguments passed through unchanged')
eq(body.input[3].type, 'function_call_output', 'the tool result is a function_call_output item')
eq(body.input[3].call_id, 'call-1', 'answered for the same call id')
eq(body.input[3].output, 'marker', 'with the result as text')
eq(body.input[4].type, 'message', 'the replayed assistant message is a message item')
eq(body.input[4].phase, 'final_answer', 'carrying the phase it was recorded with')
eq(body.input[4].id, 'msg_wa_fixture-message', 'and a Responses message id, not the durable one')
eq(body.input[4].content[1].text, 'phase fixture', 'with its text')
eq(body.tools[1].name, 'lookup_marker', 'the tool reaches the body by name')
eq(body.tools[1].type, 'function', 'as a function tool')
eq(body.tools[1].parameters.properties.tag.type, 'string', 'with its schema')
eq(body.prompt_cache_key, 'session-fixture', 'the session id keys the prompt cache')
eq(body.max_output_tokens, 4096, 'the caller cap is sent when there is one')
eq(body.text.verbosity, 'low', "the route's text verbosity is reproduced")
eq(body.include[1], 'reasoning.encrypted_content', 'and so is the reasoning include list')
check(body.parallel_tool_calls == true, 'parallel tool calls are allowed, as pi does')
eq(body.reasoning.effort, 'none', 'an off run asks for the level this id maps off to')
eq(body.reasoning.summary, 'auto', 'with the summary behaviour this route uses')

local function effort(model, selected)
  local field = wire.reasoning_field(catalogue.get(model), selected)
  return field and field.effort or nil
end
eq(effort('gpt-6-luna', 'medium'), 'medium', 'a level the id publishes is passed through')
eq(effort('gpt-6-luna', 'off'), 'none', "an off run maps to the id's own off effort")
check(effort('gpt-6-luna', 'off') ~= 'medium',
  'and is not silently promoted to a level that thinks')
eq(effort('gpt-5.6-luna', 'high'), 'high', 'a level with no mapping entry stays itself')
eq(effort('gpt-5.3-codex-spark', 'high'), 'high',
  'a level the endpoint accepts is passed through even when the id publishes no mapping for it: ' ..
  "pi's supported set excludes only a published `null` and the two high-effort levels it does " ..
  'not mention')
eq(effort('gpt-5.3-codex-spark', 'max'), 'xhigh',
  'and a level the id cannot honour is clamped down to one it can, as pi clamps it')
eq(effort('gpt-6-astra', 'off'), 'low', 'an id that cannot turn reasoning off lands on its floor')

-- ---------------------------------------------------------------------------------------------
-- The catalogue: nil is not `{}`, and nothing reads pi's store at request time
-- ---------------------------------------------------------------------------------------------
local published = catalogue.thinking_level_map('gpt-6-luna')
check(type(published) == 'table' and published.off == 'none',
  'a published id answers with its levels')
eq(catalogue.thinking_level_map('not-a-model'), nil,
  '"cannot answer" is nil, never an empty table: an empty set refuses every level a child can carry')
eq(catalogue.get('not-a-model'), nil, 'and an id the catalogue does not publish is unknown')
eq(catalogue.window('gpt-6-luna').max_output, 128000, 'the output window is published per id')
eq(catalogue.window('not-a-model'), nil, 'and is unknown, not zero, for an unknown id')
eq(catalogue.thinking_level_map('gpt-6-astra').off, nil,
  "pi's `off: null` is absent here, exactly as the JSON decoder returned it")
check(catalogue.off_not_supported['gpt-6-astra'] == true,
  'the ids that publish `off: null` are named, because null and absent are not the same claim')

-- The point of the catalogue: a machine with no pi install still answers. The store path is pointed
-- at a file that does not exist, and the route must not care.
local native_getenv = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_PI_MODELS_STORE' then return paths.temp() .. '/wa-wire-no-such-store.json' end
  if key == 'PI_CODING_AGENT_DIR' then return paths.temp() .. '/wa-wire-no-such-pi' end
  return native_getenv(key)
end
check(catalogue.thinking_level_map('gpt-6-luna').off == 'none',
  'the catalogue answers with no store on disk and no pi directory')
local levels_without_pi = wire.supported_levels(catalogue.get('gpt-6-luna'))
check(#levels_without_pi > 0, 'and the route still has levels to offer')
host.getenv = native_getenv

-- The import path, against a fixture of the store the entries were measured from: a refresh that
-- changes an answer has to show up as a diff in this test rather than only in a live request.
local store = paths.temp() .. '/wa-wire-store-fixture.json'
assert(host.write_file(store, [[{"openai-codex":{"models":[
{"id":"gpt-6-luna","provider":"openai-codex","api":"openai-codex-responses","reasoning":true,
 "contextWindow":272000,"maxTokens":128000,"input":["text","image"],
 "thinkingLevelMap":{"off":"none","minimal":"low","low":"low"}},
{"id":"foreign","provider":"opencode-go","api":"openai-completions","reasoning":true}
]}}]]), 'the store fixture must be written')
local imported = catalogue.import_from_pi(store)
eq(imported.count, 1, 'only this route is imported: another api is not an entry for this route')
eq(imported.models[1].id, 'gpt-6-luna', 'the import keeps the id')
eq(imported.models[1].max_output, 128000, 'and its windows')
eq(imported.models[1].supports_image, true, 'and whether it takes images')
eq(imported.models[1].thinking_levels.off, 'none', 'and its thinking levels')
eq(catalogue.import_from_pi(paths.temp() .. '/wa-wire-no-store.json'), nil,
  'a missing store is nil, not an empty import')
check(catalogue.render(imported.models):find("id = 'gpt-6-luna'", 1, true) ~= nil,
  'and the import renders back into the catalogue file the same way it is written')

-- The credential seam is called *by the credential lane's own name* and answers with the lane's own
-- taxonomy. The defect this closes: the wire asked for `lua/core/subscription_auth.lua`, a file the
-- credential lane never shipped, so the two verified halves could not see each other at all - and an
-- absent credential must never look like an unauthenticated request or an empty answer.
eq(wire.CREDENTIAL_MODULE, 'lua/core/openai_sub_auth.lua',
  'the seam names the module the credential lane actually shipped')
local module_ok, credential_module = pcall(dofile, wire.CREDENTIAL_MODULE)
check(module_ok and type(credential_module) == 'table' and type(credential_module.token) == 'function',
  'and that module loads from this tree with a token() on it: ' .. tostring(credential_module))
-- Force the absent store instead of hoping this machine's home is empty: the question is what the
-- seam says when there is no credential, and the answer must not depend on whose disk runs the
-- suite. `WASM_AGENT_OPENAI_SUB_STORE` is the credential module's own documented override.
local native_getenv_for_seam = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_OPENAI_SUB_STORE' then
    return paths.temp() .. '/wa-wire-absent-store/credential.json'
  end
  return native_getenv_for_seam(key)
end
local seam_credential, seam_failure = wire.credential()
host.getenv = native_getenv_for_seam
check(seam_credential == nil and type(seam_failure) == 'table'
  and seam_failure.code == 'subscription_credentials_absent',
  'an absent store is the lane\'s own code, not a nil: got ' .. tostring(seam_failure and seam_failure.code))
check(tostring(seam_failure):find('subscription_credentials_absent', 1, true) ~= nil,
  'and it reads as the code with its sentence, got ' .. tostring(seam_failure))

-- ---------------------------------------------------------------------------------------------
-- The recorded streams, replayed line by line through the transport
-- ---------------------------------------------------------------------------------------------
local frames
local function replay(body_text, done)
  -- Exactly what `host.http_sse` hands over: the response's lines, in order, as they arrive.
  local lines = {}
  for line in (body_text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
  frames = 0
  host.http_sse = function(method, url, headers_json, request, on_line)
    check(method == 'POST' and url == wire.ENDPOINT, 'the transport posts to our endpoint')
    local sent = json.decode(headers_json)
    check(sent['Authorization'] == 'Bearer fixture-access', 'with the credential seam\'s token')
    local decoded = json.decode(request)
    check(decoded.model ~= nil and decoded.stream == true, 'and a streamed Responses body')
    for _, line in ipairs(lines) do
      frames = frames + 1
      on_line(line)
    end
    done = done or {}
    return json.encode({status = done.status or 200, lines = #lines,
      termination = done.termination or 'eof', body = done.body, error = done.error})
  end
end

-- 1. The tool-call stream: the decision telemetry and the call's id shape.
local events = {}
local native_stream = host.stream
host.stream = function(payload) events[#events + 1] = json.decode(payload) end
local tool_fixture = fixture('codex-responses-sse.txt')
replay(tool_fixture)
local tool_result = wire.complete('gpt-6-luna', messages, tools, true, {session_id = 'replay'}, {selected = 'low'})
eq(tool_result.finish_reason, 'tool_calls', 'a stream that ends in a tool call says so')
eq(tool_result.stream_complete, true, 'and is complete')
eq(tool_result.model, 'gpt-6-luna', 'the result names the model that answered')
check(tool_result.request_id and tool_result.request_id:match('^resp_'),
  'the response id comes from the stream, got ' .. tostring(tool_result.request_id))
check(type(tool_result.ttft_ms) == 'number' or tool_result.ttft_ms ~= nil, 'and time-to-first-token')
eq(#tool_result.tool_calls, 1, 'the stream carried exactly one tool call')
local call = tool_result.tool_calls[1]
eq(call.type, 'function', 'it is a function call')
eq(call['function'].name, 'get_time', 'with the tool name')
eq(json.decode(call['function'].arguments).zone, 'UTC', 'and arguments that parse back')
check(tostring(call.id):find('|fc_', 1, true) ~= nil,
  'the call id keeps the Responses item id, which is what a replay needs: ' .. tostring(call.id))
check(tool_result.usage.prompt_tokens > 0 and tool_result.usage.completion_tokens > 0,
  'usage comes from the terminal event')
check(tool_result.usage.total_tokens >= tool_result.usage.prompt_tokens,
  'and total is at least the prompt')
eq(tool_result.usage.completion_tokens_details.reasoning_tokens, 0,
  'reasoning tokens are reported, zero and not nil')
check(tool_result.usage.prompt_tokens_details.cached_tokens ~= nil,
  'and so are cached prompt tokens')
local decisions = {}
for _, event in ipairs(events) do
  if event.type == 'decision' then decisions[#decisions + 1] = event end
end
check(#decisions >= 2, 'the tool decision is announced while the arguments stream, then completed')
eq(decisions[1].complete, false, 'the first announcement is provisional')
eq(decisions[#decisions].complete, true, 'and the last one is complete')
eq(decisions[#decisions].arguments_text, '{"zone":"UTC"}', 'with the final arguments as text')
eq(decisions[#decisions].call_id, call.id, 'named by the same call id the result uses')

-- 2. The text stream: provisional text resolves to commentary, and to the answer, exactly once.
events = {}
local text_fixture = fixture('codex-responses-sse-text.txt')
replay(text_fixture)
local text_result = wire.complete('gpt-6-luna', messages, tools, true, {session_id = 'replay'}, {selected = 'low'})
check(#text_result.commentary > 0, 'the recorded stream carries commentary text')
local pending, resolved = {}, {}
for _, event in ipairs(events) do
  if event.type == 'pending_delta' then
    pending[event.pending_id] = (pending[event.pending_id] or '') .. event.text
  elseif event.type == 'commentary' or (event.type == 'delta' and event.pending_id) then
    resolved[event.pending_id] = resolved[event.pending_id] or {}
    resolved[event.pending_id][#resolved[event.pending_id] + 1] = event
  end
end
check(next(pending) ~= nil, 'and it streamed that text provisionally while it arrived')
for pending_id, text in pairs(pending) do
  local answers = resolved[pending_id]
  check(answers ~= nil and #answers == 1,
    'provisional text must resolve exactly once: ' .. tostring(pending_id))
  eq(answers[1].text, text, 'and resolve without loss or duplication')
end
eq(text_result.content, '', 'commentary is not the answer')
eq(text_result.commentary[1].content, resolved[next(pending)][1].text,
  'the commentary block in the result is the text that was streamed')
check(text_result.commentary[1].id and text_result.commentary[1].pending_id,
  'and it names both the message and the pending block the UI was drawing')

-- 3. Truncation is an error, never a partial success.
local terminal = text_fixture:find('\n\n' .. 'event: response.completed', 1, true)
check(terminal ~= nil, 'the fixture has a terminal event to cut off')
replay(text_fixture:sub(1, terminal))
local cut_ok, cut_error = pcall(wire.complete, 'gpt-6-luna', messages, tools, false,
  {session_id = 'replay'}, {selected = 'low'})
check(not cut_ok and tostring(cut_error):find('subscription_stream_truncated', 1, true) ~= nil,
  'a stream that ends without a terminal event fails loudly, got ' .. tostring(cut_error))
check(tostring(cut_error):find('partial answer is not an answer', 1, true) ~= nil,
  'and says why, rather than reporting a short answer')

-- 4. A frame that is not JSON, an HTTP refusal and a cancelled run are all visible.
replay('event: response.output_text.delta\ndata: not json at all\n\n')
local bad_ok, bad_error = pcall(wire.complete, 'gpt-6-luna', messages, tools, false,
  {session_id = 'replay'}, {selected = 'low'})
check(not bad_ok and tostring(bad_error):find('subscription_event_unparseable', 1, true) ~= nil,
  'an unparseable frame is a protocol failure, got ' .. tostring(bad_error))
replay('', {status = 401, body = '{"error":{"message":"unauthorized"}}'})
local http_ok, http_error = pcall(wire.complete, 'gpt-6-luna', messages, tools, false,
  {session_id = 'replay'}, {selected = 'low'})
check(not http_ok and tostring(http_error):find('subscription_http_401', 1, true) ~= nil,
  'an auth refusal is reported with its status, got ' .. tostring(http_error))
replay('', {error = 'run_cancelled', termination = 'cancelled'})
local cancel_ok, cancel_error = pcall(wire.complete, 'gpt-6-luna', messages, tools, false,
  {session_id = 'replay'}, {selected = 'low'})
check(not cancel_ok and tostring(cancel_error):find('^run_cancelled') ~= nil,
  'a cancelled read surfaces as run_cancelled - as the name, not buried in a transport ' ..
  'traceback, got ' .. tostring(cancel_error))

-- 5. Cancellation and the deadline are checked *while reading*, not after the stream ends.
replay(text_fixture)
local native_cancelled = host.run_cancelled
host.run_cancelled = function() return json.encode({cancelled = true}) end
local running_ok, running_error = pcall(wire.complete, 'gpt-6-luna', messages, tools, false,
  {session_id = 'replay'}, {selected = 'low'})
check(not running_ok and tostring(running_error):find('^run_cancelled') ~= nil,
  'a run cancelled mid-stream stops at the next line, as the name, got ' ..
  tostring(running_error))
check(frames < select(2, text_fixture:gsub('\n', '\n')),
  'and does not read the rest of the stream: read ' .. tostring(frames) .. ' of ' ..
  tostring(select(2, text_fixture:gsub('\n', '\n'))))
host.run_cancelled = native_cancelled
replay(text_fixture)
local native_ms = host.monotonic_ms
local ticks = 0
host.monotonic_ms = function() ticks = ticks + 1; return ticks > 1 and 10 ^ 9 or 0 end
local deadline_ok, deadline_error = pcall(wire.complete, 'gpt-6-luna', messages, tools, false,
  {session_id = 'replay', timeout_seconds = 5}, {selected = 'low'})
check(not deadline_ok and tostring(deadline_error):find('subscription_timeout', 1, true) ~= nil,
  'the WASM_AGENT_SUBSCRIPTION_TIMEOUT bound stops the read, got ' .. tostring(deadline_error))
-- And it is the *name* the caller can match on, not a substring of a transport traceback. Measured
-- on a real request cut by `WASM_AGENT_SUBSCRIPTION_TIMEOUT=1`: the stop arrived as
-- `subscription_transport_line_callback_failed: .../subscription_wire.lua:897: subscription_timeout:
-- ...`, so `find('subscription_timeout')` passed while an operator reading the error - or a caller
-- matching on the documented name - saw both a local path and the wrong leading name. A check that
-- only searches for the substring cannot tell those two apart; this one anchors.
check(tostring(deadline_error):find('^subscription_timeout') ~= nil,
  'the deadline error must BE subscription_timeout, not carry it inside a wrapped callback ' ..
  'failure, got ' .. tostring(deadline_error))
check(tostring(deadline_error):find('subscription_wire.lua', 1, true) == nil,
  'and must not leak a filesystem path or line number into the message, got ' ..
  tostring(deadline_error))
host.monotonic_ms = native_ms

-- 6. An id the catalogue does not publish is refused before any request leaves.
replay(tool_fixture)
local unknown_ok, unknown_error = pcall(wire.complete, 'not-a-model', messages, tools, false,
  {session_id = 'replay'}, {selected = 'low'})
check(not unknown_ok and tostring(unknown_error):find('subscription_model_unknown', 1, true) ~= nil,
  'an id this route does not publish is refused by name, got ' .. tostring(unknown_error))
check(frames == 0, 'and no bytes leave for it')

-- 7. "Is this route configured?" is a credential question, and on the native transport the answer
-- is the seam's - not a third-party package's file. Measured before this check existed, with Pi's
-- `auth.json` unreachable (which is what a machine without Pi looks like): `M.configured()` answered
-- false while this route's own credential was present and usable, so `wa status` reported the route
-- unconfigured and the agent refused the turn at `provider.configured()`. The route's whole point is
-- that it runs with no Pi on disk, so this is a property of the transport, not of the credential -
-- hence a check here rather than in the credential lane's own fixture.
local subscription = dofile('lua/core/openai_sub.lua')
local seam_wire = subscription.wire()
local native_getenv, native_read = host.getenv, host.read_file
local function as(transport, credential)
  host.getenv = function(key)
    if key == 'WASM_AGENT_SUBSCRIPTION_TRANSPORT' then return transport end
    if key == 'PI_CODING_AGENT_DIR' then return '/nonexistent-pi-agent-dir' end
    return native_getenv(key)
  end
  host.read_file = function(path)
    if tostring(path):find('nonexistent-pi-agent-dir', 1, true) then return nil end
    return native_read(path)
  end
  if credential then seam_wire.credential_provider = credential end
end
as('native', function() return {access = 'seam-access', account_id = 'seam-account'} end)
check(subscription.transport() == 'native', 'the transport override is the one under test')
check(subscription.configured() == true,
  'on native, a usable seam credential configures the route with no Pi on disk at all')
as('native', function() return nil end)
check(subscription.configured() == false,
  'and a seam that yields no credential does not, rather than claiming a route that cannot run')
as('native', function() error('subscription_credentials_absent') end)
check(subscription.configured() == false,
  'and a seam that raises is an unconfigured route, not a crash: status must stay answerable')
as('pi', nil)
check(subscription.configured() == false,
  'the Pi transport still asks Pi\'s auth file, which is not there in this fixture')
host.getenv, host.read_file = native_getenv, native_read

-- Encrypted reasoning is captured whole and replayed before the turn's own items: with store=false
-- the endpoint keeps nothing, so a reasoning model only keeps its chain of thought if it is sent back.
local reasoning_item = {type = 'reasoning', id = 'rs_fixture', summary = {{type = 'summary_text', text = 'plan'}},
  encrypted_content = 'enc-fixture'}
local with_reasoning = tool_fixture:gsub('(event: response%.in_progress\n[^\n]*\n\n)', function(head)
  return head .. 'event: response.output_item.added\ndata: ' ..
    json.encode({type = 'response.output_item.added', output_index = 9,
      item = {id = 'rs_fixture', type = 'reasoning', summary = {}}}) .. '\n\n' ..
    'event: response.output_item.done\ndata: ' ..
    json.encode({type = 'response.output_item.done', output_index = 9, item = reasoning_item}) .. '\n\n'
end, 1)
replay(with_reasoning)
local reasoned = wire.complete('gpt-6-luna', messages, tools, true, {session_id = 'replay'}, {selected = 'low'})
check(type(reasoned.reasoning_items) == 'table', 'a stream with encrypted reasoning returns it')
eq(reasoned.reasoning_items.model, 'gpt-6-luna', 'bound to the model that produced it')
eq(reasoned.reasoning_items.items[1].encrypted_content, 'enc-fixture', 'with the encrypted content intact')
eq(reasoned.reasoning_items.items[1].id, nil, 'and without an item id store=false cannot resolve')
local _, replayed = wire.items({
  {role = 'user', content = 'q'},
  {role = 'assistant', content = '', reasoning_items = reasoned.reasoning_items.items, tool_calls = reasoned.tool_calls},
})
eq(replayed[2].type, 'reasoning', 'the reasoning is replayed before the turn')
eq(replayed[3].type, 'function_call', 'and the turn\'s call follows it')

host.stream = native_stream
print('subscription wire ok (' .. checks .. ' checks)')
