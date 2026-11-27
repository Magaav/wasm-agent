-- AN UNKNOWN FIELD IN A PEER BASH CALL MUST NAME ITSELF (refusals-that-help, item (k)).
--
-- MEASURED: `tools.remote` bash with `time_seconds` (the caller meant timeout_seconds) was refused
--     "a check on what the node applied did not hold: peer bash field not adoptable"
-- with fix "read detail, then re-read the state" - naming neither the field that was sent nor the field that
-- would have been taken. A model cannot act on that: it has to guess which of its arguments is wrong.
--
-- This row pins the refusal as the sentence it must be:
--   unknown field time_seconds; accepted fields are ...; nearest: timeout_seconds
-- and that nothing was started for it. The nearest name comes from the schema validator's own helper
-- (lua/core/json_contract.lua, exported by this change), so `q` -> `query` and `time_seconds` ->
-- `timeout_seconds` are one rule rather than two.
--
-- Hermetic: its own scratch home, and the dispatch it measures is a stub, so nothing runs.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local nodes = dofile('lua/core/nodes.lua')
local real_dofile = dofile
dofile = function(path) if path == 'lua/core/nodes.lua' then return nodes end return real_dofile(path) end
local tools = dofile('lua/core/tools.lua')
dofile = real_dofile
local checks, failed = 0, 0
local function check(ok, message)
  if ok then checks = checks + 1 else failed = failed + 1; print('FAIL ' .. message) end
end

local seen = {}
local real_dispatch = tools.dispatch
tools.dispatch = function(_memory, name, args)
  seen[#seen + 1] = { name = name, args = args }
  return { error = 'probe_stop', effect = 'none' }
end
local ok_server, server = pcall(real_dofile, 'lua/core/server.lua')
if not ok_server then error('lua/core/server.lua did not load: ' .. tostring(server)) end
local caller, author = { node_id = 'peer-field-probe', role = 'master' }, 'master'

-- 1. THE MEASURED CALL.
local refused = wa_peer_dispatch('bash', { command = 'printf ok', time_seconds = 5, budget_ms = 5000 }, caller, author)
check(type(refused) == 'table' and refused.error == 'peer_bash_field_not_adoptable',
  'an unknown field is still refused: ' .. json.encode(refused or {}):sub(1, 240))
check(type(refused) == 'table' and refused.field == 'time_seconds',
  'it names the field that was sent: ' .. tostring(type(refused) == 'table' and refused.field))
check(type(refused) == 'table' and refused.nearest == 'timeout_seconds',
  'and the field the caller probably meant: ' .. tostring(type(refused) == 'table' and refused.nearest))
local message = type(refused) == 'table' and tostring(refused.message or refused.note or '') or ''
check(message:find('unknown field time_seconds', 1, true) ~= nil,
  'the message says which field is unknown: ' .. message:sub(1, 240))
check(message:find('accepted fields are ', 1, true) ~= nil,
  'and what the call may send instead: ' .. message:sub(1, 240))
check(message:find('nearest: timeout_seconds', 1, true) ~= nil,
  'and the nearest accepted name: ' .. message:sub(1, 240))
check(type(refused) == 'table' and type(refused.carried) == 'table' and #refused.carried > 0,
  'the accepted fields travel as a list too: ' .. json.encode(type(refused) == 'table' and refused.carried or {}):sub(1, 240))
check(#seen == 0, 'and nothing was started for a refused call (dispatches: ' .. #seen .. ')')

-- 2. THE FIELD IT SUGGESTED IS ACCEPTED: the suggestion is not a second refusal.
seen = {}
local accepted = wa_peer_dispatch('bash', { command = 'printf ok', timeout_seconds = 5, budget_ms = 5000 }, caller, author)
check(type(accepted) ~= 'table' or accepted.error ~= 'peer_bash_field_not_adoptable',
  'the suggested field is taken: ' .. json.encode(accepted or {}):sub(1, 240))
-- The accepted call goes down the ADOPTION path (a supervised operation), not through the dispatch stub, so
-- what is asserted is what the caller gets: no refusal, and a command that ran (adopted or a code back).
local executed = type(accepted) == 'table' and accepted.error == nil
  and (accepted.adopted == true or accepted.code == 0 or #seen == 1)
check(executed, 'and the suggested field is taken: the command runs instead of being refused: '
  .. json.encode(accepted or {}):sub(1, 300))

print(('peer bash field names itself: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
