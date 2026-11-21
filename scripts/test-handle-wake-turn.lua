-- A settled handle starts a model step with nobody typing (21/11).
--
-- The whole point of the wake is that no operator action is needed and the model never polls: the work
-- ends, a durable row exists, and a MODEL CALL happens. This row holds that last hop without a
-- provider, a network or a terminal - the provider is stubbed the way scripts/test-cli-steering.lua
-- stubs it - and it asserts the four facts the rule is:
--
--   1. the wake row is claimed by the same call the node tick and the CLI idle prompt make;
--   2. the model is asked ONCE, with the settled answer and the handles still pending in its input;
--   3. the turn is durable in the session's transcript, labelled as a wake;
--   4. the effect is never re-run - the wake reads the retained answer - and the wake-only round is
--      counted.
local json = dofile('lua/vendor/json.lua')
local native_getenv = host.getenv
local env = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_CODEMODE' then return 'native' end
  if key == 'WASM_AGENT_LLM_API_KEY' then return 'test-only' end
  if key == 'WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if key == 'WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  if key == 'WASM_AGENT_PI_MODELS_STORE' then return 'missing-test-store' end
  return env(key)
end
host.http = function() error('unexpected HTTP in the hermetic handle-wake test') end
host.http_stream = host.http
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local pending = dofile('lua/core/codemode_pending.lua')
local selfloop = dofile('lua/core/selfloop.lua')
local counters = dofile('lua/core/counters.lua')
local handle_wake = dofile('lua/core/handle_wake.lua')
local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end
local data = dofile('lua/core/paths.lua').data()
assert(not data:match('/%%.wasm%%-agent$') or data:find('scratch', 1, true) or data:find('/tmp/', 1, true),
  'this row needs a scratch HOME (it writes handles, wakes and turns); it refused to run in ' .. tostring(data))
local marker = data .. '/wake-marker.txt'
assert(host.write_file(marker, ''), 'the marker starts empty')
local sid = memory.start_session('', 'a settled handle starts a model step', { user_id = 'master' })
local session = assert(memory.session(sid), 'the session exists')
local owner = session.user_id
local ctx = { session_id = sid, user_id = owner, role = 'master' }
local function dispatch(name, params, raw) return tools.dispatch(memory, name, params, 'master', ctx, raw) end
local scope = 'handle-wake-turn-scope'
local opts = { ctx = ctx, scope = scope, session = sid, dispatch = dispatch }

-- 1. A call that settles with nobody waiting, appending to its own marker: the marker is how the
-- "never re-run" half is measured.
-- The command takes about a second, so the call answers a HANDLE rather than finishing inside its
-- zero-millisecond wait - which is the only shape this row is about.
local started = pending.invoke(dispatch, opts, 'bash',
  { command = 'sleep 1; echo ran >> ' .. marker .. '; echo the answer' },
  json.encode({ command = 'sleep 1; echo ran >> ' .. marker .. '; echo the answer' }), 0)
check(type(started) == 'table' and started.state == 'pending' and type(started.op) == 'string',
  'a call answers a handle: ' .. json.encode(started or {}):sub(1, 200))
local op = tostring(started.op)
if host.sleep then host.sleep(2500) end
local swept = handle_wake.sweep()
check(type(swept) == 'table' and (tonumber(swept.settled) or 0) >= 1,
  'the sweep settles it and schedules the wake: ' .. json.encode(swept or {}):sub(1, 200))

-- 2. Claim it the way the node tick and the CLI's idle prompt do, then run the turn.
local row = selfloop.claim_due(sid, owner)
check(type(row) == 'table' and tostring(row.id) == 'handle:' .. op,
  'the wake is due and claimed: ' .. json.encode(row or {}):sub(1, 200))
local provider = dofile('lua/core/provider.lua')
local original_dofile = dofile
local calls, seen = 0, {}
provider.complete_with = function(_, messages)
  calls = calls + 1
  local last = messages[#messages] and tostring(messages[#messages].content) or ''
  seen.last = last
  for _, message in ipairs(messages) do
    if tostring(message.content):find('the answer', 1, true) then seen.answer = true end
  end
  return { content = 'wake received', tool_calls = {}, finish_reason = 'stop',
    usage = { prompt_tokens = 900, completion_tokens = 20, total_tokens = 920 } }
end
dofile = function(path)
  if path == 'lua/core/provider.lua' then return provider end
  return original_dofile(path)
end
local answer = selfloop.run_wake({ id = row.id, owner = owner, session_id = sid })
dofile = original_dofile
check(type(answer) == 'table' and answer.ok == true,
  'the wake turn ran: ' .. json.encode(answer or {}):sub(1, 240))
check(calls == 1, 'the model was asked exactly once, with nobody typing: ' .. calls)
check(seen.answer == true, 'and its input carries the settled answer itself: ' .. tostring(seen.last):sub(1, 240))

-- 3. The turn is durable, and it is labelled as node state rather than as the operator's words.
local found
for _, turn in ipairs(memory.session_messages(sid, { limit = 40 })) do
  if tostring(turn.content):find('[self-wake', 1, true) then found = tostring(turn.content) end
end
check(found ~= nil, 'the wake is a durable row in the transcript')
check(found and found:find('a pending call settled', 1, true) ~= nil,
  'and it says what woke the session: ' .. tostring(found):sub(1, 240))

-- 4. Nothing was re-run, and the wake-only round is counted.
local lines = 0
for _ in tostring(host.read_file(marker) or ''):gmatch('\n') do lines = lines + 1 end
check(lines == 1, 'the effect ran exactly once across the wake (the marker has ' .. lines .. ' line(s))')
check(counters.read().wake_only_round == 1,
  'and the step is counted as a wake-only round: ' .. json.encode(counters.read()))

print(string.format('handle wake turn: %d checks', checks))
