-- NO RAW STACK REACHES THE PERSON (mission turn-survives-a-provider-stall, item 2).
--
-- Measured 24/11 on the work node: a stall printed
--   agent.lua:3366: provider.lua:1666: provider.lua:1599: provider_error: timeout: receive response
--   (provider_stalled: no response within 90s)
-- - a chain of location prefixes Lua adds on every re-raise, which `redact.text` does not strip and which
-- says nothing about what happened. `chat.lua` now prints `run_failure.human_line(...)`.
--
-- What is pinned here:
--   * the line a real stalling run produces carries NO `*.lua:<n>:` location and DOES name the class;
--   * it is one line, and the wording is the row's own (`run_failed: <code> - <why>: <detail>`), so the
--     transcript and the bus fact cannot drift into two sentences for one failure;
--   * the classification is untouched: the same text still classifies as provider_stalled;
--   * the measured chain from the work session is cleaned completely (all three frames, not one).
--
-- Hermetic: the provider is replaced before the agent runs; no paid call, no network, no sleeps.
local native_getenv = host.getenv
local overrides = { WASM_AGENT_LLM_API_KEY = 'test-only', WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-stall-store',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS = '0' }
local cleared = { WASM_AGENT_PROVIDER_RESPONSE_RETRIES = true }
host.getenv = function(key)
  if overrides[key] ~= nil then return overrides[key] end
  if cleared[key] then return nil end
  return native_getenv(key)
end
host.http = function() error('unexpected HTTP in hermetic test') end
host.http_stream = host.http
host.sleep = function() end
host.run_cancelled = function() return '{"cancelled":false,"run_cancel":false,"subagent_cancel":false}' end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local original_dofile = dofile
local provider = dofile('lua/core/provider.lua')
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib = original_dofile('lua/core/agent.lua')
dofile = original_dofile
local run_failure = dofile('lua/core/run_failure.lua')

local failed, checks = 0, 0
local function check(condition, label)
  checks = checks + 1
  if condition then return end
  failed = failed + 1
  print('FAIL ' .. label)
end

-- ---- the WIRING, not just the function: this is what fails on the code before the change ----
-- The tree being judged, not the cwd: host.read_file is the filesystem's, and a row run from another
-- directory would otherwise read another checkout's chat.lua and pass or fail for the wrong reason.
local root = native_getenv('WASM_AGENT_LUA_ROOT') or '.'
local source = host.read_file(root .. '/lua/core/chat.lua') or ''
check(source:find('run_failure.human_line(', 1, true) ~= nil,
  'chat.lua prints the sanitised sentence')
check(source:find('view:failed(redact.text(tostring(reply)))', 1, true) == nil,
  'and no longer prints the raw reply (the chain the person saw)')

-- ---- the measured chain, cleaned in full -------------------------------------------------
local chain = 'lua/core/agent.lua:3366: lua/core/provider.lua:1666: lua/core/provider.lua:1599: ' ..
  'provider_error: timeout: receive response (provider_stalled: no response within 90s)'
local cleaned = run_failure.human_line(chain)
check(cleaned:find('%.lua:%d+:') == nil, 'no location survives: ' .. tostring(cleaned))
check(cleaned:find('provider_stalled', 1, true) ~= nil, 'the class is named: ' .. tostring(cleaned))
check(cleaned:find('receive response', 1, true) ~= nil, 'and what the transport said: ' .. tostring(cleaned))
check(cleaned:find('\n') == nil, 'it is one line')
local info = run_failure.classify(chain)
check(info.code == 'provider_stalled', 'the classification is untouched (got ' .. tostring(info.code) .. ')')

-- ---- a real stalling run: the same call chat.lua makes ----------------------------------
local session = memory.start_session('', 'stall-line', { user_id = 'master', node_id = '', title = 'stall-line' })
local bot = agentlib.new(session, function() end, 'master', 'master', '')
local calls = 0
provider.complete_with = function()
  calls = calls + 1
  error('provider_error: provider_stalled: no response within 90s')
end
local ok, problem = pcall(bot.run, bot, 'ask once')
check(not ok, 'a stall still ends a turn today (item 1 changes that, this row pins the text)')
local raw = tostring(problem)
check(raw:find('provider_stalled', 1, true) ~= nil, 'the raw error carries the marker')
local line = run_failure.human_line(raw)
check(line:find('%.lua:%d+:') == nil, 'the line the person reads has no Lua frame: ' .. tostring(line))
check(line:find('provider_stalled', 1, true) ~= nil, 'and still names the stall: ' .. tostring(line))
check(line:sub(1, #run_failure.PREFIX) == run_failure.PREFIX, 'the wording is the row\'s own: ' .. tostring(line))
check(calls >= 1, 'the provider was asked (got ' .. tostring(calls) .. ')')

print(string.format('ok stall-line: %d checks, %d failed', checks, failed))
if failed > 0 then error('stall-line failed') end

