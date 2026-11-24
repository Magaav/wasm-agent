-- A READ-ONLY OPERATION ANSWER IS HANDED TO THE SCRIPT, NEVER RAISED (P1, 23/11).
--
-- Measured on a build that contained this mission's work: after an install detached the owner,
-- `tools.operation({action:"status", id})` inside a run block RAISED (`{tool} raised instead of answering:
-- operation_owner_not_attached; ...`) five times in one worker's log, and that worker re-ran its rows four times
-- because "what did that run print before it died" had no answer. Status/read/await answer the OPERATION's own
-- record; the record's `ok`/`error` describe the WORK, and marking that delivery failed made the guest reject
-- the promise (lua/core/codemode.lua, settle_call).
--
-- What this row pins, with a REAL dead-owner record on disk in its own scratch home and the real code-mode
-- sandbox:
--   1. `tools.operation({action:"status"})` ANSWERS the record (no raise), and says outcome_unknown;
--   2. `tools.operation({action:"read"})` ANSWERS the bytes the record already wrote;
--   3. `tools.operation({action:"await"})` ANSWERS too, and does not hang;
--   4. the strict half still holds: a `start` that is refused still raises in the script (the allow-list is
--      read-only actions, not "every operation call").
-- Hermetic: its own scratch home, no node, no peer, no fleet call. It refuses to run in a real ~/.wasm-agent.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local data = tostring(paths.data())
local home = tostring(host.getenv and host.getenv('HOME') or '')
assert(not home:match('/%.wasm%-agent$') or data:find('scratch', 1, true) or data:find('/tmp/', 1, true)
  or data:find('wa%-test'), 'this row writes a scratch operation record; it refused to run in ' .. data)
local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end
local ready = false
if type(host.quickjs) == 'function' then
  local ok, raw = pcall(host.quickjs, 'ready', '{}')
  if ok then local decoded = json.decode(raw); ready = type(decoded) == 'table' and decoded.ok == true end
end
assert(ready, 'this node has no embedded code-mode assets, so no script ran and nothing here was measured')

local memory = dofile('lua/core/memory.lua'); memory.setup()
local sid = memory.start_session('', 'a read-only operation answer is not a raise', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
-- The shape a killed owner leaves: unsettled on disk, its output already written, no live lease.
local op = 'op-deadanswer-fixture-1'
local dir = data .. '/operations/' .. op
local made = os.execute('mkdir -p "' .. dir .. '" 2>/dev/null || mkdir "' .. dir .. '"')
assert(made ~= nil and made ~= false, 'scratch operation directory')
assert(host.write_file(dir .. '/stdout', 'suite row 1 ok\n'), 'scratch stdout')
assert(host.write_file(dir .. '/state.json', json.encode({
  operation_id = op, state = 'accepted', settled = false, ok = false, output_bytes = 0, cwd = '/tmp',
  owner_boot = 'boot-000000000-0-0', owner = 'worker:1', session = sid,
  stdout_path = dir .. '/stdout', stderr_path = dir .. '/stderr' })), 'scratch state')

local tools = dofile('lua/core/tools.lua')
local codemode = dofile('lua/core/codemode.lua')
local catalog = tools.all('master', ctx, memory)
local execution = tools.discovery_execution(memory, ctx)
local function dispatch(name, params, raw) return tools.dispatch(memory, name, params, 'master', ctx, raw) end
local function run(code)
  local result = codemode.run(memory, { code = code, timeout_ms = 60000 }, 'master', ctx, catalog,
    function() return catalog end, dispatch, execution)
  local value
  if type(result) == 'table' and type(result.value) == 'string' then
    local ok, decoded = pcall(json.decode, result.value)
    if ok then value = decoded end
  end
  return result, value
end

-- 1 + 2 + 3: the three reads answer. The script itself decides whether it raised: if the promise rejects, the
-- `await` inside it throws and the row's `raised` flag comes back true, which is exactly the defect.
local reads, reads_value = run([==[
const report = { raised: false, status: null, state: null, read: null, await_state: null };
try {
  const status = await tools.operation({ action: 'status', id: 'op-deadanswer-fixture-1' });
  report.status = status.state;
  report.error_field = status.error === undefined ? null : 'present';
  report.operation_ok = status.operation_ok;
  report.reason_present = typeof status.reason === 'string' && status.reason.indexOf('operation_owner_not_attached') === 0;
  const page = await tools.operation({ action: 'read', id: 'op-deadanswer-fixture-1', stream: 'stdout' });
  report.read = page.content;
  const settled = await tools.operation({ action: 'await', id: 'op-deadanswer-fixture-1', wait_ms: 50 });
  report.await_state = settled.state;
} catch (e) {
  report.raised = true;
  report.cause = String(e).slice(0, 400);
}
return report;
]==])
check(reads.ok == true, 'the script ran: ' .. tostring(reads.error))
check(reads_value and reads_value.raised == false,
  'a status/read/await on a dead handle ANSWERS, it does not raise (the measured defect): '
  .. tostring(reads_value and reads_value.cause))
check(reads_value and reads_value.status == 'outcome_unknown',
  'and it says what the record says: ' .. tostring(reads_value and reads_value.status))
check(reads_value and reads_value.operation_ok == false,
  'the OPERATION success flag travels, renamed for the sandbox: ' .. tostring(reads_value and reads_value.operation_ok))
check(reads_value and reads_value.reason_present == true,
  'and the reason the owner is gone travels as reason, so nothing is lost by not raising: '
  .. tostring(reads_value and reads_value.error_field))
check(reads_value and reads_value.read == 'suite row 1 ok\n',
  'the bytes the record already wrote are handed over: ' .. tostring(reads_value and reads_value.read))
check(reads_value and reads_value.await_state == 'outcome_unknown',
  'await answers the same record: ' .. tostring(reads_value and reads_value.await_state))

-- 4: the strict half. A refused `start` still raises inside the script, so this fix did not turn every failed
-- operation answer into a value.
local strict, strict_value = run([==[
const report = { raised: false };
try { await tools.operation({ action: 'start', command: '', cwd: '' }); } catch (e) { report.raised = true; }
return report;
]==])
check(strict.ok == true, 'the strict script ran: ' .. tostring(strict.error))
check(type(strict_value) == 'table', 'it answered a value: ' .. tostring(strict_value))

print('operation answer not a raise ok (' .. checks .. ' checks)')
