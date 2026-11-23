-- TOOL ROUND TRIP: one file read inside run(code=...), timed from this side of the seam.
--
--   WASM_AGENT_LUA_ROOT=<tree> WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/speed/probe-tool-roundtrip.lua \
--     wa --db <scratch>/t.db
--
-- WHAT IS MEASURED. One dispatch of the 'codemode' tool - the same call a model's run block makes - whose
-- script awaits ONE 'tools.read' and returns the length it read. The number is the route: the guest starts,
-- the read crosses the boundary, the file is read locally, the value comes back inside the envelope and the
-- call settles. No model, no network, no remote node.
--
-- WHAT IS NOT. The guest VM's own provisioning: when quickjs is not provisioned this tree drives code mode
-- through the host's scripted peer (scripts/bench-codemode.lua says why), and then the number is the SEAM
-- and not the guest. The probe prints which one it measured, so a number from a provisioned machine is
-- never compared with one from an unprovisioned machine by mistake.
--
-- The median is the harness's (scripts/lib/speed-stats.lua), never this file's: one 'sample <n> <ms>' line
-- per measured call on stdout and nothing else. A warm-up call is made and THROWN AWAY first, because the
-- first code-mode call in a process pays for the module, the policy pin and the sandbox's own start - a
-- real cost, but the cold-start row's, not this one's.
local home = tostring(host.getenv('WASM_AGENT_HOME') or '')
local function norm(value) return (value:gsub('\\', '/'):gsub('/+$', '')):lower() end
local operator = norm(tostring(host.getenv('HOME') or '') .. '/.wasm-agent')
if home == '' then print('SKIP tool-roundtrip: no WASM_AGENT_HOME (a scratch home is required)'); os.exit(0) end
if norm(home) == operator then
  print('SKIP tool-roundtrip: refusing to run against the node own home (' .. home .. ')'); os.exit(0)
end

local count = tonumber(host.getenv('WA_SPEED_SAMPLES') or '') or 5
local target = host.getenv('WA_SPEED_READ_PATH') or 'lua/core/memory.lua'
local code = string.format('const r = await tools.read({path: %q}); return r.content.length;', target)

local memory = dofile('lua/core/memory.lua')
memory.setup()
local tools = dofile('lua/core/tools.lua')
local policy = dofile('lua/core/codemode_policy.lua')
local sid = memory.start_session('', 'speed tool round trip', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master', role = 'master' }
policy.pin(memory, 'master', ctx)

local function once()
  local began = tonumber(host.monotonic_ms())
  local result = tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx)
  local elapsed = tonumber(host.monotonic_ms()) - began
  return elapsed, result
end

-- The warm-up: its NUMBER is discarded, its failure is not (a route that cannot read a file must not be
-- reported as a slow route).
local _, result = once()
if type(result) ~= 'table' or result.ok == false then
  io.stderr:write('unavailable: the code-mode call failed: ' .. tostring(result and (result.error or result.reason) or 'no answer') .. '\n')
  os.exit(2)
end
-- Which guest ran is a fact this row cannot invent: the answer says it, and when it does not the row says
-- guest=unknown rather than guessing (rule 1).
local guest = tostring(result.backend or result.sandbox or '')
if guest == '' then guest = 'unknown' end
print('guest ' .. guest)

local values = {}
for index = 1, count do
  local ms, answer = once()
  if type(answer) ~= 'table' or answer.ok == false then
    io.stderr:write('unavailable: sample ' .. index .. ' failed: ' .. tostring(answer and (answer.error or answer.reason) or 'no answer') .. '\n')
    os.exit(2)
  end
  local whole = math.floor(ms + 0.5)
  values[#values + 1] = whole
  print(string.format('sample %d %d', index, whole))
end
if #values < 3 then
  io.stderr:write('unavailable: only ' .. #values .. ' sample(s) - three are the least a median can stand on\n')
  os.exit(2)
end
