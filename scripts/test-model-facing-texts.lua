local native_getenv = host.getenv
local overrides = { WASM_AGENT_LLM_API_KEY = 'test-only', WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_PROVIDER_RETRIES = '0', WASM_AGENT_RUN_FAILURE_WAKE_SECONDS = '0' }
host.getenv = function(key) if overrides[key] ~= nil then return overrides[key] end return native_getenv(key) end
host.http = function() error('unexpected HTTP in hermetic test') end
host.http_stream = host.http

local memory = dofile('lua/core/memory.lua'); memory.setup()
local original_dofile = dofile
local provider = dofile('lua/core/provider.lua')
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib = original_dofile('lua/core/agent.lua')
dofile = original_dofile
local fake_answer = original_dofile('lua/core/fake_answer.lua')
local pending = original_dofile('lua/core/codemode_pending.lua')

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function session(title) return memory.start_session('', title, { user_id = 'master', node_id = '', title = title }) end
local usage = { prompt_tokens = 1000, completion_tokens = 20, total_tokens = 1020 }
local function run(title, replies)
  local sid = session(title)
  local bot = agentlib.new(sid, function() end, 'master', 'master', '')
  local seen = 0
  provider.complete_with = function()
    seen = seen + 1
    local reply = replies[seen]
    if not reply then error('unexpected provider call ' .. seen) end
    return reply
  end
  local ok, reply = pcall(bot.run, bot, 'do the thing')
  assert(ok, tostring(reply))
  return sid, reply, bot
end
local function fake(text) return { content = text, tool_calls = {}, finish_reason = 'stop', usage = usage } end
local function answer(text) return { content = text or 'done.', tool_calls = {}, finish_reason = 'stop', usage = usage } end
local function notice_rows(sid)
  local found = {}
  for _, row in ipairs(memory.session_messages(sid, { all = true }) or {}) do
    if row.role == 'user' and tostring(row.content):find('[Harness notice]', 1, true) then
      found[#found + 1] = tostring(row.content)
    end
  end
  return found
end

-- ---------------------------------------------------------------- WAIT_HELP says what the code does
local help = tostring(pending.WAIT_HELP and pending.WAIT_HELP.description or '')
check(help ~= '', 'the wait help exists')
check(help:find("defaults to 60", 1, true) ~= nil, 'wait_s still defaults to 60')
check(help:find("capped at 300", 1, true) ~= nil, 'and is still capped at 300')
check(help:find("remaining time", 1, true) == nil,
  'it no longer promises a bound the code does not have ("at the script remaining time"): ' .. help:sub(1, 200))
check(help:find("never settles", 1, true) ~= nil and help:find("codemode_wait_never_settles", 1, true) ~= nil,
  'and it names the bound that DOES exist: one op that never settles: ' .. help:sub(1, 400))
check(help:find("until:\"any\"", 1, true) ~= nil, 'the rest of the contract is unchanged')

-- ---------------------------------------------------------------- the notice names a callable tool
local scan = fake_answer.scan("<result>\n<name>bash</name>\n<output>x</output>\n</result>")
check(scan ~= nil and scan.tool == 'bash', 'the markup names the tool it was describing')
check(tostring(fake_answer.notice(scan, nil)):find("the tool you were describing", 1, true) ~= nil,
  'a caller that cannot tell which tool is callable gets "the tool", never an invented name')
check(tostring(fake_answer.notice(scan, nil)):find("tools.<", 1, true) == nil,
  'and never the old placeholder: ' .. tostring(fake_answer.notice(scan, nil)))
check(tostring(fake_answer.notice(scan, 'tools.bash()')):find("call tools.bash() and wait", 1, true) ~= nil,
  'a caller that CAN spell it passes the spelling through')

-- In a real run: the notice must name a way to call the tool that this session actually has.
local sid, reply, bot = run('model-facing-notice', {
  fake("<result>\n<name>bash</name>\n<output>x</output>\n</result>"), answer('done.') })
check(reply == 'done.', 'the turn answers')
local notices = notice_rows(sid)
check(#notices == 1, 'the notice was recorded once: ' .. tostring(#notices))
local notice = notices[1] or ''
local step = notice:match("Take your next step:.*$") or ''
check(step ~= '' and step:find("<name>", 1, true) == nil,
  'and the step it asks for never contains the placeholder: ' .. step)
-- The notice must name a way to call the tool that THIS session actually has, and nothing else. What
-- that way is depends on the envelope the session was given (code mode, an on-demand tool, a declared
-- tool, or - in raw-code-only mode - no callable door at all, where "the tool" is the honest answer), so
-- the row reads the session's own tool list and checks the notice against it.
local declared, available = {}, {}
for _, schema in ipairs(bot.tool_list or {}) do declared[schema["function"].name] = true end
for _, schema in ipairs(original_dofile('lua/core/tools.lua').all('master') or {}) do
  available[schema["function"].name] = true
end
local BT = string.char(96)
local reachable = {
  { spelling = "tools.bash(",           door = function() return declared.codemode == true and available.bash == true end },
  { spelling = 'tool_call(name="bash")', door = function() return declared.tool_call == true and available.bash == true end },
  { spelling = BT .. "bash" .. BT,       door = function() return declared.bash == true end },
}
local matched, allowed = nil, false
for _, candidate in ipairs(reachable) do
  if step:find(candidate.spelling, 1, true) then matched = candidate.spelling; allowed = candidate.door() end
end
if matched then
  check(allowed, 'the notice offers ' .. matched .. ' only because this session can use it (declared: '
    .. tostring(declared.codemode and 'codemode' or declared.tool_call and 'tool_call' or 'none') .. '): ' .. step)
else
  check(step:find("the tool you were describing", 1, true) ~= nil,
    'when this session has no callable door for that tool the notice says "the tool" instead of naming one: ' .. step)
end
check(step:find("tools.<", 1, true) == nil, 'and never the old placeholder: ' .. step)

-- A markup that names a tool this session does not have: the notice says "the tool", never the name.
local sid2 = run('model-facing-notice-unknown', {
  fake("<result>\n<name>no_such_tool_xyz</name>\n<output>x</output>\n</result>"), answer('done.') })
local unknown = (notice_rows(sid2))[1] or ''
local unknown_step = unknown:match("Take your next step:.*$") or ''
check(unknown_step:find("no_such_tool_xyz", 1, true) == nil,
  'a tool name the session cannot call is not offered as a door: ' .. unknown_step)
check(unknown_step:find("the tool you were describing", 1, true) ~= nil,
  'the notice says "the tool" when it cannot tell which one is callable: ' .. unknown_step)

print(string.format("ok model-facing-texts: %d checks", checks))
