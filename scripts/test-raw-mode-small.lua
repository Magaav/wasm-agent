-- Item 6 (rel review r2), the three small rules, each on the real module.
--
--   1. mode() does not load the profile/provider modules on every call: its default is cached for the
--      process, and a provider switch (and a test) can drop that cache by name;
--   2. WASM_AGENT_RAW_CODE=bash keeps its a27490af meaning ("no raw channel") unless the A/B switch
--      names the bash arm - a mode this branch added must not repurpose a value that already meant off;
--   3. a thread whose prefix was frozen in one mode keeps it: the mode is decided at thread start,
--      recorded with the frozen prefix, and read from there on every later turn.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local raw = dofile('lua/core/raw_code.lua')
local agent = dofile('lua/core/agent.lua')
local provider = dofile('lua/core/provider.lua')

local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then error(label .. ' (got ' .. tostring(got) .. ', want ' .. tostring(want) .. ')', 0) end
end

local real = host.getenv
local function with(env, fn)
  host.getenv = function(k)
    if env[k] ~= nil then return env[k] end
    return real(k)
  end
  local okc, value = pcall(fn)
  host.getenv = real
  if not okc then error(value, 0) end
  return value
end

-- ---------------------------------------------------------------- 1. the default is cached per process
raw.reset_mode_cache()
local counted = 0
local original_default = raw.default_mode
raw.default_mode = function(...) counted = counted + 1; return original_default(...) end
local first = with({}, function() return raw.mode() end)
local second = with({}, function() return raw.mode() end)
local third = with({}, function() return raw.mode() end)
eq(counted, 1, 'three reads of mode() with no switch load the default once (got ' .. counted .. ')')
eq(first, second, 'the cached reads agree')
eq(second, third, 'the cached reads agree')
raw.reset_mode_cache()
local after_reset = with({}, function() return raw.mode() end)
eq(counted, 2, 'reset_mode_cache() makes the next read measure again (got ' .. counted .. ')')
eq(after_reset, first, 'and the answer does not change with the cache dropped')
raw.default_mode = original_default

-- The provider switch is one of the paths that must drop it, and it does so by name.
local switch_source = host.read_file((host.getenv('WASM_AGENT_LUA_ROOT') or '.') .. '/lua/core/provider.lua') or ''
ok(switch_source:find('reset_mode_cache', 1, true) ~= nil,
  'a provider switch invalidates the cached mode (lua/core/provider.lua, set_provider)')

-- ---------------------------------------------------------------- 2. RAW_CODE=bash keeps its meaning
raw.reset_mode_cache()
eq(with({ WASM_AGENT_RAW_CODE = 'bash' }, function() return raw.mode() end), nil,
  'RAW_CODE=bash with no A/B arm means NO raw channel, exactly as a27490af read that unknown value')
eq(with({ WASM_AGENT_RAW_CODE = 'bash', WA_AB_ARM = 'bash' }, function() return raw.mode() end), 'bash',
  'and it is the bash transport only when the A/B switch names that arm')
eq(with({ WASM_AGENT_RAW_CODE = 'native' }, function() return raw.mode() end), 'native',
  'native is this branch own transport and is unaffected by the arm switch')

-- ---------------------------------------------------------------- 3. a frozen thread keeps its mode
-- Start the thread in only mode, with the switch set; then read it again with the switch UNSET, which
-- on this node's provider row is native. The thread must still act in only.
local sid = with({ WASM_AGENT_RAW_CODE = 'only' }, function()
  local started = memory.start_session('', 'frozen mode thread', { user_id = 'master', title = 'frozen mode' })
  local bot = agent.new(started, function() end, 'master', 'master', '')
  bot:build_context()
  eq(bot.mode_source, 'switch', 'a new thread takes its mode from the switch')
  eq(bot.codemode_policy.raw_mode, 'only', 'and records it with the prefix it freezes')
  return started
end)

local later = with({}, function()
  local bot = agent.new(sid, function() end, 'master', 'master', '')
  bot:build_context()
  return bot
end)
eq(later.mode_source, 'frozen', 'a later turn on that thread reads the mode from the frozen prefix')
eq(later.codemode_policy.raw_mode, 'only',
  'so a thread that started in only keeps only after the node default moved to native')
ok(raw.mode_of(later.codemode_policy) == 'only', 'and every mode reader sees it: mode_of(policy)')
eq(later.codeact_transport, 'block', 'the only-mode thread keeps the fenced-block transport')

-- The recorded value is what a fresh process reads too: the same session, no in-memory state.
local stored = dofile('lua/core/prompt_cache.lua').read({ session_id = sid, user_id = 'master', role = 'master' })
eq(type(stored) == 'table' and stored.raw_mode, 'only',
  'the frozen prefix itself carries the mode, so a restarted node reads the same answer')

print('raw mode small rules ok (' .. checks .. ' checks)')
