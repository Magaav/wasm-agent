-- WHERE AN OPERATION ACTUALLY STARTS (G blocker, Fable 24/11).
--
-- Measured by change/worker-write-guard (docs/missions/reports/worker-write-guard.md, section 15) and
-- reproduced here: an operation's starting directory came from `sessions.worktree` ALONE, so a session with
-- no bound worktree - every mission worker, every plain CLI session, every `peer:<node>` call - answered ""
-- and the child inherited whatever process served the turn. Under the CLI that is the mission directory and
-- it looked right; when the NODE serves the turn (a resumed session after a deploy pause, a wake, a job) the
-- same code ran the work in the node's own directory, the canonical checkout.
--
-- What this row pins, with the real dispatcher and real processes in a scratch home:
--   1. a session with no worktree runs where its FIRST RUN was served (the recorded directory), not where
--      the serving process happens to be;
--   2. a session with a worktree still runs in the worktree (the stronger binding wins);
--   3. an explicit `cwd` wins over both;
--   4. a resumed operation (await, then status) reports the directory it started in;
--   5. a recorded directory that is GONE is refused BY NAME - the node does not substitute its own, and a
--      silent substitution is how the work ended up in the canonical checkout;
--   6. the START receipt carries cwd / cwd_source / effective_cwd, so a caller needs no second call to learn
--      where its work runs.
-- NOT covered here, said plainly: the SENDING half of a peer call (a live peer is forbidden to a mission and
-- this row starts none). The receiving half it can hold - a call whose args carry `cwd` uses it and records
-- `source = "explicit"` - is case 3, and lua/core/tools.lua `peer_args_with_cwd` adds that argument from the
-- caller's own session directory.
-- Hermetic: its own scratch home and its own directories; refuses to run in a real ~/.wasm-agent.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local data = tostring(paths.data())
local home = tostring(host.getenv and host.getenv('HOME') or '')
assert(not home:match('/%.wasm%-agent$') or data:find('scratch', 1, true) or data:find('/tmp/', 1, true)
  or data:find('wa%-test'), 'this row starts real operations; it refused to run in ' .. data)
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local platform = dofile('lua/core/platform.lua')
local checks = 0
local function check(v, label) assert(v, label); checks = checks + 1 end
local function norm(p) return (tostring(p or ''):gsub('%s+$', ''):gsub('^%s+', ''):gsub('\\', '/'):gsub('/+$', '')) end

-- Two directories of this row's own, plus a third for the explicit case.
local base = data .. '/cwd-row-' .. tostring(math.floor((host.now() or 0) * 1000))
local function mkdir(path) local r = os.execute('mkdir -p "' .. path .. '"'); assert(r ~= nil and r ~= false, 'mkdir ' .. path) end
local run_dir, tree_dir, asked_dir = base .. '/run', base .. '/tree', base .. '/asked'
mkdir(run_dir); mkdir(tree_dir); mkdir(asked_dir)

local function dispatch(name, args, ctx) return tools.dispatch(memory, name, args, 'master', ctx) end
local function record(r, ctx)
  if type(r) ~= 'table' then return r end
  if type(r.effective_cwd) == 'string' then return r end
  if type(r.operation_id) ~= 'string' then return r end
  return dispatch('operation', { action = 'status', id = r.operation_id }, ctx)
end

-- 1. NO WORKTREE: the session's first run recorded `run_dir`; nothing else on this node knows it.
local plain = memory.start_session('', 'cwd row plain', { user_id = 'master' })
check(memory.session_cwd(plain) == '', 'a session starts with no recorded directory')
memory.set_session_cwd(plain, run_dir)
local ctx1 = { session_id = plain, user_id = 'master' }
local started = dispatch('operation', { action = 'start', command = 'pwd > where.txt', cwd = '' }, ctx1)
check(type(started) == 'table' and type(started.operation_id) == 'string', 'the operation started: ' .. tostring(started and started.error))
-- 6. THE RECEIPT ITSELF: the blocker's focus line.
check(type(started.cwd_source) == 'string', 'the START receipt carries cwd_source: ' .. tostring(started.cwd_source))
check(started.effective_cwd ~= nil, 'and effective_cwd: ' .. tostring(started.effective_cwd))
local settled = dispatch('operation', { action = 'await', id = started.operation_id, wait_ms = 20000 }, ctx1)
settled = record(settled, ctx1)
check(norm(settled.effective_cwd) == norm(run_dir),
  'the operation ran in the directory the session recorded, not the server\'s: got ' .. tostring(settled.effective_cwd)
  .. ' want ' .. run_dir .. ' (serving process is at ' .. tostring(platform.cwd()) .. ')')
check(settled.cwd_source == 'session_run', 'and the record says WHY, honestly: ' .. tostring(settled.cwd_source))
check(norm(settled.effective_cwd) ~= norm(platform.cwd()),
  'the serving process\'s own directory is not what an operation inherits any more')
local written = host.read_file and host.read_file(run_dir .. '/where.txt') or nil
check(type(written) == 'string' and norm(written) == norm(run_dir), 'and the shell really wrote there: ' .. tostring(written))

-- 4. RESUMED: the same record through `status`, after the settle.
local again = dispatch('operation', { action = 'status', id = started.operation_id }, ctx1)
check(norm(again.effective_cwd) == norm(run_dir), 'a resumed handle reports the directory it started in: ' .. tostring(again.effective_cwd))

-- 2. A WORKTREE STILL WINS: a bound checkout is a stronger statement than a starting directory.
local bound = memory.start_session('', 'cwd row bound', { user_id = 'master' })
memory.set_session_worktree(bound, tree_dir)
memory.set_session_cwd(bound, run_dir)
local ctx2 = { session_id = bound, user_id = 'master' }
local in_tree = dispatch('operation', { action = 'start', command = 'pwd > where.txt', cwd = '' }, ctx2)
in_tree = record(dispatch('operation', { action = 'await', id = in_tree.operation_id, wait_ms = 20000 }, ctx2), ctx2)
check(norm(in_tree.effective_cwd) == norm(tree_dir), 'a session with a worktree runs in the worktree: ' .. tostring(in_tree.effective_cwd))
check(in_tree.cwd_source == 'session_workspace', 'and says session_workspace: ' .. tostring(in_tree.cwd_source))

-- 3. EXPLICIT WINS OVER BOTH, and is recorded as the caller's choice.
local asked = dispatch('operation', { action = 'start', command = 'pwd > where.txt', cwd = asked_dir }, ctx1)
asked = record(dispatch('operation', { action = 'await', id = asked.operation_id, wait_ms = 20000 }, ctx1), ctx1)
check(norm(asked.effective_cwd) == norm(asked_dir), 'an explicit cwd wins: ' .. tostring(asked.effective_cwd))
check(asked.cwd_source == 'explicit', 'and the record says explicit: ' .. tostring(asked.cwd_source))

-- 5. A GONE DIRECTORY IS REFUSED BY NAME, for both entry points, and nothing is launched.
local ghost = memory.start_session('', 'cwd row ghost', { user_id = 'master' })
memory.set_session_cwd(ghost, base .. '/released-tree')
local ctx3 = { session_id = ghost, user_id = 'master' }
local refused_bash = dispatch('bash', { command = 'pwd > gone.txt' }, ctx3)
check(type(refused_bash) == 'table' and refused_bash.error == 'session_cwd_gone',
  'a gone session directory refuses bash by name: ' .. tostring(type(refused_bash) == 'table' and refused_bash.error))
check(refused_bash.effect == 'none', 'and claims no effect: ' .. tostring(refused_bash.effect))
check(tostring(refused_bash.note or ''):find('worktree', 1, true) ~= nil, 'and says what to do instead: ' .. tostring(refused_bash.note))
local refused_op = dispatch('operation', { action = 'start', command = 'pwd > gone.txt', cwd = '' }, ctx3)
check(type(refused_op) == 'table' and refused_op.error == 'session_cwd_gone',
  'a gone session directory refuses operation start too: ' .. tostring(type(refused_op) == 'table' and refused_op.error))
check(host.read_file(base .. '/gone.txt') == nil or (host.read_file(base .. '/gone.txt') or '') == '',
  'and no shell ran: nothing was written')

print('operation cwd ok (' .. checks .. ' checks)')
