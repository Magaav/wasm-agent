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
for _, want in ipairs({ 'only', 'first', 'native', 'bash', 'stop', 'on' }) do
  ok(mode_with(want) == want, 'explicit ' .. want .. ' is honoured (got ' .. tostring(mode_with(want)) .. ')')
end
-- "off" is the absent mode: it answers nil, which every reader treats as no raw channel.
ok(mode_with('off') == nil, 'explicit off means no raw channel')
ok(mode_with('codemode') == nil, 'explicit codemode means no raw channel (the codemode tool is the channel)')
print('default mode ok (' .. checks .. ' checks)')

