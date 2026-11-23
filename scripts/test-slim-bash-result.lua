-- A command's answer carries what a caller ACTS ON; the bookkeeping stays one handle away
-- (mission slim-tool-results, Victor 22/11).
--
-- Measured on the base of this branch, one real run block, `echo hi`: 38 fields and 1,408 bytes of JSON
-- for 3 bytes of stdout. Over the last 200 recorded results the envelope was 2,111 bytes per call median
-- against 756 bytes of decision fields (docs/missions/reports/write-names-its-node.md), 179 of them the
-- PEER's filesystem paths. pi and Claude Code both hand the model the text and the exit code and keep the
-- rest behind one pointer; `lua/core/bash_result.lua` is that pointer's local half, and the pointer itself
-- is the operation record: `operation {action="status", id=<operation_id>}`.
--
-- What this holds, in order:
--   * the three fixtures are REAL answers recorded on the base (see fixtures/slim-bash-result/README.md),
--     so the removed set is measured from data, not from a list somebody typed;
--   * the answer a caller receives has NO field outside the kept set - through the run block a model's
--     script actually runs, and through a direct dispatch;
--   * a shape that is not a command envelope (a transport refusal, a pending handle) passes through
--     untouched: unknown is not empty;
--   * a peer's fat answer is slimmed by the CALLER, one call or a batch entry;
--   * the removed fields are all still there, on the operation record, read back through the handle;
--   * a script that reads r.stdout / r.code / r.ok behaves exactly as it did, including the one case
--     that used to depend on `process_exit_code`/`settled`: a non-zero exit is a result, not a throw.
--
-- Hermetic: its own scratch home (the guard refuses the real one), no network, no model, and the only
-- peer it names is this node itself (a `remote` call addressed here runs here).
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local json = dofile('lua/vendor/json.lua')

local function refuse(why) print('REFUSED test-slim-bash-result: ' .. why); os.exit(2) end
local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-slim-bash-result')
if why_home then refuse(why_home) end

local TREE = host.getenv('WASM_AGENT_LUA_ROOT') or '.'
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local nodes = dofile('lua/core/nodes.lua')
local bash_result = dofile('lua/core/bash_result.lua')

local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end

local function fixture(name)
  local raw = host.read_file(TREE .. '/fixtures/slim-bash-result/' .. name)
  assert(raw, 'fixture missing: ' .. name)
  return json.decode(raw)
end
local function keys(value)
  local list = {}
  for key in pairs(value) do list[#list + 1] = key end
  table.sort(list)
  return list
end
local function kept(key) return bash_result.KEEP[key] == true end
local function outside(value) -- keys the allow-list does not name, sorted
  local list = {}
  for key in pairs(value) do if not kept(key) then list[#list + 1] = key end end
  table.sort(list)
  return list
end

-- The old answers, recorded on the base of this branch (fixtures/slim-bash-result/README.md).
local old_local = fixture('old-local-bash.json')
local old_script = fixture('old-script-bash.json')
local old_remote = fixture('old-remote-bash.json')
check(type(old_local) == 'table' and type(old_script) == 'table' and type(old_remote) == 'table',
  'the three recorded old answers load')
-- They ARE the fat shape: this is what the mission measured, not an assumption.
check(#keys(old_local) >= 35 and old_local.timing ~= nil and old_local.effective_cwd ~= nil
  and old_local.owner_boot ~= nil and old_local.stdout_path ~= nil,
  'the recorded local answer is the fat one the mission measured: ' .. #keys(old_local) .. ' fields')
check(old_remote.node == 'nextcloud' and tostring(old_remote.stdout_path):find('/home/ubuntu/', 1, true) ~= nil,
  'the recorded remote answer is a real OLD PEER answer, with the peer path in it')
check(#keys(old_script) > #keys(old_local), 'the run-block answer had two more fields than the direct one (' .. #keys(old_script) .. ')')

-- The removed set is derived from the recorded answer, so a field added to the record later is covered
-- by this row without editing it.
local removed = outside(old_local)
check(#removed > 20 and #removed > #keys(old_local) / 2,
  'the recorded answer is mostly bookkeeping: ' .. #removed .. ' of ' .. #keys(old_local) .. ' fields are not kept')

-- 1. The allow-list, on the recorded answers.
local slim_local = bash_result.slim(old_local)
check(#outside(slim_local) == 0, 'no field outside the kept set: ' .. table.concat(outside(slim_local), ','))
check(#keys(slim_local) == #keys(old_local) - #removed, 'exactly the kept fields of the recorded answer survive')
for _, key in ipairs(removed) do
  check(slim_local[key] == nil, 'removed field survives in the answer: ' .. key)
end
for _, key in ipairs({ 'stdout', 'code', 'ok', 'operation_id', 'timeout_ms', 'output_complete',
    'stdout_truncated', 'stderr_truncated', 'stdout_elided_bytes', 'stderr_elided_bytes' }) do
  check(slim_local[key] == old_local[key], 'a kept field changed value: ' .. key)
end
check(#json.encode(slim_local) < #json.encode(old_local) / 2,
  'the answer is at least twice as small: ' .. #json.encode(slim_local) .. ' vs ' .. #json.encode(old_local) .. ' bytes')
-- A copy, not a window into the record: nothing downstream can reach a removed field through it.
slim_local.stdout = 'tampered'
check(old_local.stdout ~= 'tampered', 'the slim answer is a fresh table, not the record itself')
local slim_remote = bash_result.slim(old_remote)
check(slim_remote.node == 'nextcloud' and #outside(slim_remote) == 0, 'a peer answer keeps its node and nothing else')
check(slim_remote.stdout_path == nil and slim_remote.stderr_path == nil,
  'the peer filesystem paths are not in the answer any more')
check(slim_remote.stdout == old_remote.stdout and slim_remote.code == old_remote.code, 'the peer output and code survive')
check(#keys(bash_result.slim(slim_local)) == #keys(slim_local), 'slimming twice is the same answer')

-- 2. A shape that is not a command envelope is not rewritten. Unknown is not empty.
local transport = { error = 'remote_unreachable', node = 'gone', retryable = true, next = 'start the node' }
check(bash_result.slim(transport) == transport, 'a transport refusal passes through untouched')
local handle = { state = 'pending', op = 'op-1', tool = 'bash', output_bytes = 0 }
check(bash_result.slim(handle) == handle, 'a pending handle passes through untouched')

-- 3. WHICH answer is a command's, decided by the call, never by the answer's text.
check(bash_result.slim_for('bash', {}, old_local) ~= old_local, 'a bash call is slimmed')
check(#outside(bash_result.slim_for('bash', {}, old_local)) == 0, 'and it has nothing outside the kept set')
check(#outside(bash_result.slim_for('remote', { capability = 'bash' }, old_remote)) == 0,
  'an OLD PEER answer over remote{capability:"bash"} is slimmed by the CALLER')
local page = { content = 'text', path = '/etc/hostname', bytes = 4, status = 200 }
check(bash_result.slim_for('remote', { capability = 'read' }, page) == page,
  'a peer READ is not a command: its answer keeps every field it had')
local batch = { ok = true, node = 'nextcloud', failed = 0, round_trips = 1,
  results = { old_remote, page } }
local slim_batch = bash_result.slim_for('remote', { capability = 'batch', calls = {
  { capability = 'bash', command = 'echo hi' }, { capability = 'read', path = '/etc/hostname' } } }, batch)
check(slim_batch ~= batch and #outside(slim_batch.results[1]) == 0, 'the batch entry that ran a command is slimmed')
check(slim_batch.results[2] == page, 'the batch entry that was a read is byte-identical')
check(slim_batch.ok == true and slim_batch.node == 'nextcloud' and slim_batch.round_trips == 1,
  'the batch answer itself keeps its own fields')

-- 4. THE REAL PATH: one run block, the route a model's script takes.
local sid = memory.start_session('', 'slim bash result', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master', role = 'master' }
local function run(code)
  local result = tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx)
  check(result and result.ok, 'the run block ran: ' .. json.encode(result or {}):sub(1, 400))
  local item = result.items and result.items[1]
  check(item and type(item.text) == 'string', 'the run block printed text')
  return json.decode(item.text)
end
local scripted = run('text(JSON.stringify(await tools.bash({command:"echo hi"})));')
check(#outside(scripted) == 0, 'the script received nothing outside the kept set: ' .. table.concat(outside(scripted), ','))
check(scripted.stdout == old_script.stdout and scripted.code == old_script.code and scripted.ok == true,
  'a script reading r.stdout / r.code / r.ok reads the same values as before')
for _, key in ipairs(removed) do
  check(scripted[key] == nil, 'a removed field reached the script: ' .. key)
end
check(type(scripted.operation_id) == 'string' and scripted.operation_id ~= '',
  'the answer names the handle that holds the rest')

-- The other producer: a DIRECT call (the agent loop's own path) gets the same shape.
local direct = tools.dispatch(memory, 'bash', { command = 'echo hi' }, 'master', ctx)
check(#outside(direct) == 0, 'a direct bash call has nothing outside the kept set')
check(direct.stdout == 'hi\n' and direct.code == 0 and direct.ok == true, 'the direct answer is the output the command printed')
check(direct.operation_id == scripted.operation_id or type(direct.operation_id) == 'string',
  'the direct answer names its operation too')

-- 5. THE ONE READER THAT DEPENDED ON A REMOVED FIELD: a non-zero exit is a result, not a throw.
local failed = run('text(JSON.stringify(await tools.bash({command:"exit 3"})));')
check(failed.ok == true and failed.code == 3, 'a command that exited 3 is an answer with code 3, not an error')
check(#outside(failed) == 0, 'and that answer keeps the same shape')

-- 6. THE HANDLE RETURNS EVERY REMOVED FIELD. The record the answer points at is the whole answer.
-- TWO of the record's own doors, because they answer different halves of it: `status` is the operation's
-- record (owner, session, launch directory, containment, cleanup, the store paths, the timing), and `wait`
-- is the record plus the LIVE-wait facts the manager computes on demand (`overdue`, `shell_exited`,
-- `output_idle_ms`), which a settled record read from disk need not carry. Every removed field is on one
-- of them, which is what this row holds: the fields did not disappear, they moved one handle away.
local record = tools.dispatch(memory, 'operation', { action = 'status', id = direct.operation_id }, 'master', ctx)
check(type(record) == 'table' and record.error == nil, 'the operation record answers by its id: ' .. json.encode(record or {}):sub(1, 300))
local live = tools.dispatch(memory, 'operation', { action = 'wait', id = direct.operation_id, wait_ms = 0 }, 'master', ctx)
check(type(live) == 'table' and live.error == nil, 'the hold of the same operation answers too: ' .. json.encode(live or {}):sub(1, 300))
local reachable = {}
for key, value in pairs(live) do reachable[key] = value end
for key, value in pairs(record) do reachable[key] = value end
for _, key in ipairs(removed) do
  if key == 'overdue' then
    -- A LIVE-WAIT fact, not a record field: it says the work is still running past its deadline, and the
    -- operation record computes it only while `!settled` (rust/wa-operation/src/lib.rs). A command that
    -- answered is settled by definition, so the value it used to carry was always false - and the handle
    -- still answers it while work is live (`operation {action="wait"}` on an unsettled id).
    check(record.settled == true and reachable.overdue ~= true,
      'a settled operation is not overdue, by definition: ' .. json.encode(record.settled))
  else
    check(reachable[key] ~= nil, 'removed field is not reachable through the handle: ' .. key)
  end
end
for _, key in ipairs({ 'stdout', 'code', 'ok', 'timeout_ms', 'output_complete' }) do
  check(record[key] == direct[key], 'the record and the answer disagree on a kept field: ' .. key)
end
-- A gated field is *reachable*, not merely present: the store it names is the same output.
check(record.stdout == direct.stdout and record.stdout_path ~= nil, 'the record names the output store the answer summarised')
check(record.timing ~= nil and type(record.timing.total_ms) == 'number', 'the timing is on the record, where a reader can ask for it')

-- 7. LOCAL AND REMOTE, ONE SHAPE. A remote call addressed to this node runs here, so both producers are
-- real; an OLD peer is covered by the recorded answer above, which the caller slims.
local here = tostring(nodes.node_name() or '')
local remote_ok = here ~= ''
local remote = remote_ok and tools.dispatch(memory, 'remote',
  { node = here, capability = 'bash', command = 'echo hi' }, 'master', ctx) or nil
if remote_ok and type(remote) == 'table' and remote.error == nil then
  check(#outside(remote) == 0, 'a remote bash call has nothing outside the kept set')
  check(remote.stdout == 'hi\n' and remote.code == 0, 'and the peer-produced output is the output the command printed')
  check(table.concat(keys(remote)) == table.concat(keys(direct)),
    'local and remote bash answer the same fields: ' .. table.concat(keys(remote), ',') .. ' vs ' .. table.concat(keys(direct), ','))
  checks = checks + 1
else
  -- Not a pass: a node whose own name does not resolve cannot show the parity, and this row says so by
  -- name instead of pretending it checked (unknown is not yes).
  check(false, 'this node does not resolve to itself through nodes.find, so the remote shape could not be '
    .. 'checked: ' .. json.encode(remote or {}) .. ' (name: ' .. here .. ')')
end

print(json.encode({ ok = true, checks = checks, removed = #removed, slim_bytes = #json.encode(direct) }))
