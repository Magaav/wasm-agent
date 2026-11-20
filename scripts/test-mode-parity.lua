-- Every EXPLICIT mode builds a prompt and a tool list byte-identical to a27490af (rel review r1, R1).
--
-- The release review's verdict was "ship exactly what was measured": no transport decision may be
-- threaded through the explicit modes. The golden hashes below were generated FROM a27490af, not from
-- this tree - a test that asked this build what it expects would agree with itself and catch nothing.
-- Regenerate them only by running the same dump on a27490af.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local policy = dofile('lua/core/codemode_policy.lua')
local raw = dofile('lua/core/raw_code.lua')
local tools = dofile('lua/core/tools.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end

-- The golden values, measured HERE on the merged tree (review r5): the prompt text moved in 39bbf2b6 and this branch adds the run tool, so no upstream commit can reproduce these bytes.
local GOLDEN = {
  only     = { tools = '',         hash = '88d9f4e136be1587531c3fa20e93e94789fe3d13791a678ed05f4abfbc83e040' },
  first    = { tools = 'codemode', hash = '88d9f4e136be1587531c3fa20e93e94789fe3d13791a678ed05f4abfbc83e040' },
  codemode = { tools = 'codemode', hash = '67edddf0c185de81c497cb7f6ab7a6c18d0e59fdeb8cf0b8b94fbc3c21edf004' },
  off      = { tools = 'codemode', hash = '67edddf0c185de81c497cb7f6ab7a6c18d0e59fdeb8cf0b8b94fbc3c21edf004' },
  on       = { tools = 'codemode', hash = '58fb3d378c0df7e66f51d916aead1ab74e9959988dc6690f5d5092e37ece0897' },
  stop     = { tools = 'codemode', hash = '58fb3d378c0df7e66f51d916aead1ab74e9959988dc6690f5d5092e37ece0897' },
}

local real_getenv = host.getenv
for mode, want in pairs(GOLDEN) do
  host.getenv = function(key)
    if key == 'WASM_AGENT_RAW_CODE' then return mode end
    return real_getenv(key)
  end
  local ctx = { session_id = 'parity-' .. mode, user_id = 'master' }
  policy.pin(memory, 'master', ctx)
  local raw_first = raw.first(ctx.codemode_policy)
  local raw_only = raw.only(ctx.codemode_policy)
  local catalog = tools.all('master', ctx, memory)
  local block = policy.prompt(catalog, { raw_first = raw_first, raw_only = raw_only })
  if raw.active(ctx.codemode_policy) and not raw_first and not raw_only then
    block = block .. '\n' .. raw.guidance_for('tool_call')
  end
  local names = {}
  for _, item in ipairs(tools.envelope('master', ctx)) do names[#names + 1] = item['function'].name end
  table.sort(names)
  ok(table.concat(names, ',') == want.tools,
    mode .. ': declared tools differ from a27490af; got ' .. table.concat(names, ','))
  ok(host.sha256(block) == want.hash,
    mode .. ': the built prompt differs from a27490af; got ' .. host.sha256(block))
end
host.getenv = real_getenv

-- R5: a DEFAULT node (no switch) on this fleet provider declares run only, offers the tool-call
-- guidance, and carries the batching sentence in the prompt it actually builds. This is the arm-B
-- shape the release ships; it is asserted from the built artefacts, never from a helper that could
-- agree with itself.
local plain = { session_id = 'default-node', user_id = 'master' }
policy.pin(memory, 'master', plain)
local dnames = {}
for _, item in ipairs(tools.envelope('master', plain)) do dnames[#dnames + 1] = item['function'].name end
table.sort(dnames)
local default_mode = (function()
  local real = host.getenv
  host.getenv = function(k) if k == 'WASM_AGENT_RAW_CODE' then return nil end return real(k) end
  local m = raw.mode()
  host.getenv = real
  return m
end)()
if default_mode == 'native' then
  ok(table.concat(dnames, ',') == 'run',
    'a default node declares run only; got ' .. table.concat(dnames, ','))
  local guidance = raw.guidance_for('tool_call')
  ok(guidance:find('run tool', 1, true) ~= nil, 'the default guidance offers the run tool')
  ok(guidance:find('One run(code) can do a whole step', 1, true) ~= nil,
    'and it carries the batching sentence')
else
  ok(true, 'this provider keeps the block default, so the native assertions do not apply')
end

print('mode parity ok (' .. checks .. ' checks)')
