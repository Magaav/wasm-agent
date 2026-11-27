-- A WRONG FIELD NAME ANSWERS WITH THE NEAREST REAL NAME AND ITS SHAPE: `operation` (refusals-that-help (b)).
--
-- MEASURED (notes 141, 165, 220): a model wrote `name` where the field is `id`, and learned it only from a
-- later call - `name` is not textually near `id`, so the refusal listed the accepted names and suggested
-- nothing.
--
-- WHAT THIS ROW PINS: the owner's rule (lua/core/json_contract.lua: nearest name first, then the intent table)
-- answers `name` -> `id` with the field's exact shape, which is what the refusal is built from.
-- NAMED GAP, not claimed here: through a direct dispatch the operation handler's own id check can answer
-- before this refusal (`invalid_operation_id`), and `label`/`description` are allowed through by
-- tool_arguments.M.INTERNAL. Both are follow-ups on the ordering/allow-list, not on the mechanism.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end
local json = dofile('lua/vendor/json.lua')
local checks, failed = 0, 0
local function check(ok, message)
  if ok then checks = checks + 1 else failed = failed + 1; print('FAIL ' .. message) end
end
local nodes = dofile('lua/core/nodes.lua')
local reload = dofile('lua/core/reload.lua')
local contract = reload.require('lua/core/json_contract.lua')
local declared = { action = { type = 'string' }, id = { type = 'string' }, command = { type = 'string' },
  timeout_seconds = { type = 'integer' }, wait_ms = { type = 'integer' } }
for _, sent in ipairs({ 'name', 'label', 'description' }) do
  local did, how = contract.field_intent('operation', sent, declared)
  check(did == 'id', 'the owner answers ' .. sent .. ' with id (how: ' .. tostring(how) .. ')')
  check(contract.shape_of(declared[did]) == 'string', 'and its exact shape: ' .. tostring(contract.shape_of(declared[did])))
end
-- The textual rule still wins when a name is close, so the intent table never overrides a real near match.
local did_textual = contract.field_intent('operation', 'timout_seconds', declared)
check(did_textual == 'timeout_seconds', 'a near name is still answered by distance: ' .. tostring(did_textual))
-- And an unrelated name gets no suggestion at all rather than a wrong one.
check(contract.field_intent('operation', 'banana', declared) == nil, 'an unrelated name gets no suggestion')
print(('field names operation: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
