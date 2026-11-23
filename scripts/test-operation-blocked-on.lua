-- WHAT A PENDING ANSWER SAYS ABOUT A PARKED OPERATION (item 1, 23/11).
--
-- The measured complaint: a mission's suite queued behind another mission's ~/Work/missions/.suite.lock
-- answered a bare "running" for 20-50 minutes, so the worker spent its turns running ps to find the holder
-- (ledger notes 0, 1, 3, 189, 244, 264, 269). The node now reads that fact from the kernel
-- (rust/wa-operation/src/blocked.rs: `blocked_on` + `blocked_note` on the operation's state), and this row
-- pins the half the MODEL reads: the bounded `progress` a code-mode pending answer carries, and the rule
-- that a wait still parked on the same lock is not mistaken for progress.
--
-- Pure: the shape is built from a state table, no operation is started, no child is spawned, and this row
-- writes nothing. It still refuses to run inside a real home, because loading the module the node loads is
-- only meaningful under a scratch one.
local pending = dofile('lua/core/codemode_pending.lua')
local paths = dofile('lua/core/paths.lua')
local data = tostring(paths.data())
local home = tostring(host.getenv and host.getenv('HOME') or '')
assert(data:find('scratch', 1, true) or data:find('/tmp/', 1, true) or data:find('wa%-test')
  or data:find('wa%-operation'),
  'this row needs a scratch HOME (it loads the pending-handle module); it refused to run in ' .. data)
local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end

local executor = pending.EXECUTORS.operation
check(type(executor) == 'table', 'the operation executor exists')
check(type(executor.progress) == 'function', 'it answers a bounded progress')
local dispatch = function() return nil end
local record = { op = 'op-blocked-fixture-1', kind = 'operation' }

-- A parked operation: the facts and the sentence both travel.
local parked = {
  state = 'running', elapsed_ms = 120000, output_bytes = 0,
  blocked_on = { kind = 'file_lock', lock_path = '/home/victor/Work/missions/.suite.lock', holder_pid = 4242 },
  blocked_note = 'waiting on a file lock: /home/victor/Work/missions/.suite.lock (FLOCK WRITE) is held by pid 4242 (flock -o /home/victor/Work/missions/.suite.lock bash scripts/fast.sh); that process started 12m 4s ago, so the lock has been held at most that long',
}
local entry = executor.progress(dispatch, {}, record, parked)
check(type(entry) == 'table', 'a progress entry')
check(entry.state == 'running', 'the state is unchanged: ' .. tostring(entry.state))
check(type(entry.blocked) == 'table', 'the pending answer names WHAT it waits on: ' .. tostring(entry.blocked))
check(entry.blocked.lock == '/home/victor/Work/missions/.suite.lock',
  'the LOCK FILE is named, not just "a lock": ' .. tostring(entry.blocked.lock))
check(entry.blocked.holder_pid == 4242, 'and the holder: ' .. tostring(entry.blocked.holder_pid))
check(type(entry.blocked_note) == 'string' and entry.blocked_note:find('suite.lock', 1, true) ~= nil,
  'and the sentence a reader can quote: ' .. tostring(entry.blocked_note))
check(entry.blocked_note:find('pid 4242', 1, true) ~= nil, 'the sentence carries the holder pid')

-- Work that is merely computing says nothing: a wrong cause costs more than no cause.
local computing = executor.progress(dispatch, {}, record, { state = 'running', elapsed_ms = 5000, output_bytes = 0 })
check(computing.blocked == nil, 'a running command that is not waiting on a lock adds no cause')
check(computing.blocked_note == nil, 'and no sentence')

-- A wait that is still parked on the SAME lock is not progress: the sentence carries the held-for duration,
-- which changes every second, so it must stay out of the fingerprint the whole-budget bound counts on.
local later = {}
for key, value in pairs(parked) do later[key] = value end
later.blocked_note = parked.blocked_note:gsub('12m 4s', '13m 5s')
check(later.blocked_note ~= parked.blocked_note, 'the fixture really does carry a changing duration')
check(pending.progress_fingerprint(executor.progress(dispatch, {}, record, parked))
  == pending.progress_fingerprint(executor.progress(dispatch, {}, record, later)),
  'a park on the same lock fingerprints as the same state, so the wait bound still counts it')

print('operation blocked-on ok (' .. checks .. ' checks)')
