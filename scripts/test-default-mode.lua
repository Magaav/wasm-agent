-- R2 (rel review r1): with no switch set, a provider that takes native tool calls gets the native
-- mode - exactly the A/B arm B - and every other provider keeps the long-standing block default.
-- An explicit WASM_AGENT_RAW_CODE always wins.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local raw = dofile('lua/core/raw_code.lua')
local profile = dofile('lua/core/model_profile.lua')
local provider = dofile('lua/core/provider.lua')
local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end

local real = host.getenv
local function mode_with(value)
  host.getenv = function(k)
    if k == 'WASM_AGENT_RAW_CODE' then return value end
    return real(k)
  end
  local m = raw.mode()
  host.getenv = real
  return m
end

-- The provider row is the decision, and it is a row, not a model name.
local settings_ok, settings = pcall(provider.settings)
ok(settings_ok and type(settings) == 'table', 'the node has a provider to decide from')
local builtin = profile.builtin_transport(settings.provider)
if builtin == profile.TOOL_CALL then
  ok(mode_with(nil) == 'native',
    'no switch + a tool-calling provider = the native mode (got ' .. tostring(mode_with(nil)) .. ')')
else
  ok(mode_with(nil) == raw.DEFAULT,
    'no switch + any other provider keeps the block default (got ' .. tostring(mode_with(nil)) .. ')')
end

-- An explicit switch always wins, and it wins by naming the mode it asks for.
for _, want in ipairs({ 'only', 'first', 'native', 'stop', 'on' }) do
  ok(mode_with(want) == want, 'explicit ' .. want .. ' is honoured (got ' .. tostring(mode_with(want)) .. ')')
end
-- 'bash' is NOT one of them (rel r2, item 6): a27490af did not know the value, so it means "no raw
-- channel" - and this branch keeps that meaning unless the A/B arm switch names the bash arm, which is
-- what "arm D" always meant. Both halves are asserted, so neither can drift.
ok(mode_with('bash') == nil, 'explicit bash alone means no raw channel (got ' .. tostring(mode_with('bash')) .. ')')
local without_arm = mode_with('bash')
local arm_ok, arm_lib = pcall(dofile, 'lua/core/ab_arms.lua')
ok(arm_ok and type(arm_lib) == 'table', 'the A/B switch module is readable')
local real_arm_getenv = host.getenv
host.getenv = function(k)
  if k == 'WASM_AGENT_RAW_CODE' then return 'bash' end
  if k == 'WA_AB_ARM' then return 'bash' end
  return real(k)
end
local with_arm = raw.mode()
host.getenv = real
ok(with_arm == 'bash', 'and RAW_CODE=bash WITH the bash arm is the bash transport (got ' .. tostring(with_arm) .. ')')
ok(without_arm == nil, 'the two readings differ, so the arm switch is the only thing that names it')
-- "off" is the absent mode: it answers nil, which every reader treats as no raw channel.
ok(mode_with('off') == nil, 'explicit off means no raw channel')
ok(mode_with('codemode') == nil, 'explicit codemode means no raw channel (the codemode tool is the channel)')
print('default mode ok (' .. checks .. ' checks)')

