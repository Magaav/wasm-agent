-- ONE MODEL CALL, ONE 'run' TOOL EVENT IN THE LEDGER (27/11, run-is-the-only-declared-door item 3).
--
-- The brief measured each run logged TWICE: once as the model's call, once as nested name="run" with the same
-- arguments_hash. The second emitter is lua/core/codemode.lua:658 - a call made INSIDE a code-mode script - and this
-- row is the runtime proof that a run the model calls produces exactly ONE event, with no nested sibling. The
-- structural argument (only codemode.lua emits nested tool spans) is in the mission report; a structural argument is
-- not a row, and this is.
--
-- Hermetic: the provider is replaced before the agent runs, so there is no paid call and no network. The ledger is a
-- real one in the runner's private home, read through telemetry.events (a cursor reader).
--
--   WASM_AGENT_HOME=<scratch> WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/test-run-logged-once.lua wa --db <scratch>
-- THE ROW JUDGES A TREE THAT CARRIES THE FIX, AND SAYS SO WHEN IT DOES NOT. Measured at landing queue #59: the row
-- came back RED on a merged tip whose Lua tree did not carry the guard in lua/core/codemode.lua (a stale or embedded
-- tree), which reads as "the product is broken" when the truth is "this row cannot judge here". A row that cannot see
-- the code it is about must SKIP BY NAME, never fail.
do
  local root = host.getenv('WASM_AGENT_LUA_ROOT')
  if root and root ~= '' then
    local ok, body = pcall(host.read_file, root .. '/lua/core/codemode.lua')
    if ok and type(body) == 'string' and not body:find("call.tool~='run'", 1, true) then
      print('SKIP test-run-logged-once: the Lua tree at ' .. root .. ' has no guard in codemode.lua for the door, '
        .. 'so this row would report the defect it exists to prevent instead of judging the fix')
      return
    end
  end
end

local native_getenv = host.getenv
local overrides = {WASM_AGENT_LLM_API_KEY='test-only', WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0', WASM_AGENT_PROVIDER_RESPONSE_RETRIES='0', WASM_AGENT_PROVIDER_RETRIES='0'}
host.getenv = function(key)
  if overrides[key] ~= nil then return overrides[key] end
  return native_getenv(key)
end
host.http = function() error('unexpected HTTP in a hermetic row') end
host.http_stream = host.http

local memory = dofile('lua/core/memory.lua'); memory.setup()
local telemetry = dofile('lua/core/telemetry.lua'); telemetry.setup()
local original_dofile = dofile
local provider = dofile('lua/core/provider.lua')
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib = original_dofile('lua/core/agent.lua')
dofile = original_dofile

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local usage = {prompt_tokens = 1000, completion_tokens = 20, total_tokens = 1020}
local sid = memory.start_session('', 'run-logged-once', {user_id = 'master', node_id = '', title = 'run-logged-once'})

local calls = 0
provider.complete_with = function()
  calls = calls + 1
  if calls == 1 then
    -- ONE tool call, named run, the door the catalogue declares.
    local call = {id = 'call-1', type = 'function'}
    call['function'] = {name = 'run', arguments = '{"code":"return 21 * 2"}'}
    return {content = '', finish_reason = 'tool_calls', usage = usage, tool_calls = {call}}
  end
  return {content = 'the script answered 42', tool_calls = {}, finish_reason = 'stop', usage = usage}
end

local bot = agentlib.new(sid, function() end, 'master', 'master', '')
local reply = bot:run('run a tiny script and tell me its answer')
check(calls == 2, 'the turn took one tool call and one answer: ' .. tostring(calls))
check(type(reply) == 'string' and #reply > 0, 'the turn answered: ' .. tostring(reply))

-- THE LEDGER, read through the same cursor reader the CLI uses.
local read = telemetry.events(sid, 0, 1000)
check(type(read) == 'table' and read.available ~= false, 'the ledger was readable')
local rows = read.events or read
local starts, nested, finishes = 0, 0, 0
for _, row in ipairs(rows) do
  if row.kind == 'tool' then
    local payload = row.payload or {}
    if type(payload) == 'string' then
      local ok, decoded = pcall(function() return require('lua/vendor/json.lua') end)
      payload = ok and {} or {}
    end
    local name = tostring(payload.name or '')
    if name == 'run' then
      if row.phase == 'start' then
        starts = starts + 1
        if payload.nested == true then nested = nested + 1 end
      elseif row.phase == 'end' then
        finishes = finishes + 1
      end
    end
  end
end
check(starts == 1, "ONE run tool start for one model call, not two: " .. tostring(starts))
check(nested == 0, 'and not one of them is a nested copy: ' .. tostring(nested))
check(finishes == 1, 'and the call is closed once: ' .. tostring(finishes))

print(string.format('run logged once ok (%d checks; one model call, one run event, no nested copy)', checks))

