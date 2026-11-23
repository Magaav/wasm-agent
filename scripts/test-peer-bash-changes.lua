-- A PEER'S COMMAND SAYS WHICH FILES IT CHANGED (chat-view-round-2, item 2, the other half).
--
-- Victor's session changed files by running python on the peer, and no change was ever printed for it:
-- the watcher in the dispatcher's bash branch ran only for a caller with a LOCAL view, and a peer call has
-- none - so the answer this node received carried no list at all, and the reader was told nothing.
--
-- Two halves, both measured here through the real dispatcher:
--   PEER  - a call with `ctx.peer_call`/`ctx.record_change` (what lua/core/server.lua builds from a
--           caller's request) answers `changes`: one entry per file, with the path and its line counts
--           and NO text - a file's content is not what crosses a wire for a display row;
--   CALLER- the `remote` branch turns that list into one `remote_change` event per file, with the node,
--           the path, the counts and the create/delete fact, and drops the list from the value the model
--           reads (a card is the reader's, never the model's);
--   VIEW  - the CLI draws those events as the same rows a local command's changes draw.
--
-- Hermetic: its own scratch home, its own git work tree, and the peer's transport is the MODULE seam
-- scripts/test-federation.lua uses (`dofile('lua/core/nodes.lua')` answers a stub) - no socket, no
-- fleet, no peer process. A stub is used only where the real host cannot answer in a test, and it says
-- so here: `nodes.remote_call` is the one capability this test cannot have for real.
local json = dofile('lua/vendor/json.lua')
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local checks, failed, first_fail = 0, 0, nil
local function check(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    if first_fail == nil then first_fail = label end
    print('FAIL ' .. label)
  end
end

local have_git = false
do
  local ok, raw = pcall(host.exec, 'git --version', '', 10, json.encode({ tool = 'bash' }))
  local decoded = ok and type(raw) == 'string' and json.decode(raw) or nil
  have_git = type(decoded) == 'table' and decoded.code == 0
end
if not have_git then error('this test needs git; nothing was measured', 0) end

-- The scratch work tree this test seeds (its own, under the test's home: nothing of the operator's).
local paths = dofile('lua/core/paths.lua')
local tree = tostring(paths.data()) .. '/peer-tree'
local seed = table.concat({
  'rm -rf ' .. string.format('%q', tree),
  'mkdir -p ' .. string.format('%q', tree),
  'cd ' .. string.format('%q', tree),
  'git init -q .',
  'git config user.email test@example.invalid',
  'git config user.name test',
  'printf "a\\nb\\n" > tracked.txt',
  'git add -A',
  'git commit -qm seed',
}, ' && ')
local seeded = os.execute(seed)
check(seeded == true or seeded == 0, 'the scratch work tree is a git repository with one committed file')

-- ---- the peer half: a caller's request reaches a bash that changes a file ---------------------
local env_get = host.getenv
host.getenv = function(key) if key == 'WASM_AGENT_CODEMODE' then return 'native' end return env_get(key) end
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local sid = memory.start_session('', 'peer bash changes', { user_id = 'master' })

-- What lua/core/server.lua builds for a peer's call (node_capability): the caller's own words about
-- itself, and nothing of this node's view.
local peer_ctx = { session_id = sid, user_id = 'master', peer_call = true, record_change = true,
  read_only_command = function(command)
    return dofile('lua/core/orchestration_mode.lua').read_only_command(command)
  end }
local answered = tools.dispatch(memory, 'bash', { command = 'printf "a\\nB\\n" > tracked.txt', cwd = tree },
  'master', peer_ctx)
check(type(answered) == 'table' and answered.error == nil, 'the peer ran the command: '
  .. tostring(answered and answered.error))
check(type(answered.changes) == 'table' and #answered.changes == 1,
  'and answered one changed file: ' .. json.encode(answered.changes))
local entry = (answered.changes or {})[1] or {}
check(entry.path == 'tracked.txt', 'named: ' .. tostring(entry.path))
check(entry.added == 1 and entry.removed == 1, 'with its counts (one added, one removed): '
  .. json.encode(entry))
check(entry.before_text == nil and entry.after_text == nil,
  'and NO text: a display row does not move a file across a wire')

-- A created file is a create, not an edit.
local created = tools.dispatch(memory, 'bash', { command = 'printf "new\\n" > made.txt', cwd = tree },
  'master', peer_ctx)
local created_entry = (created.changes or {})[1] or {}
check(created_entry.path == 'made.txt' and created_entry.created == true,
  'a created file says so: ' .. json.encode(created_entry))

-- ---- the caller half: the list becomes one row per file --------------------------------------
-- The transport is the one thing a test cannot have: `dofile('lua/core/nodes.lua')` answers a stub, the
-- seam scripts/test-federation.lua uses. Everything else (the branch, the event, the queue) is real.
local real_dofile = dofile
local stub = {
  find = function(selector) return { name = tostring(selector), node_id = 'peer-1', online = true,
    local_node = false } end,
  remote_call = function(_, capability, args)
    if capability ~= 'bash' then return { error = 'unexpected_capability' } end
    return { ok = true, code = 0, stdout = 'hello\\n', stderr = '', operation_id = 'op-peer',
      changes = { { path = 'srv/app/main.py', added = 3, removed = 0, created = true } } }
  end,
  mesh_enabled = function() return false end,
  refusal = function() return nil end,
}
dofile = function(path)
  if path == 'lua/core/nodes.lua' then return stub end
  return real_dofile(path)
end
local caller_tools = real_dofile('lua/core/tools.lua')
dofile = real_dofile
local sink, queue = {}, {}
local caller_ctx = { session_id = sid, user_id = 'master', watch_changes = true, emit = function(event)
  sink[#sink + 1] = event end, change_queue = queue }
local result = caller_tools.dispatch(memory, 'remote', { node = 'peer-one', capability = 'bash',
  command = 'python edit.py' }, 'master', caller_ctx)
check(type(result) == 'table' and result.error == nil, 'the remote call answered: '
  .. tostring(result and result.error))
local events = {}
for _, event in ipairs(queue) do events[#events + 1] = event end
for _, event in ipairs(sink) do events[#events + 1] = event end
local rows = {}
for _, event in ipairs(events) do
  if event.type == 'remote_change' and event.capability == 'bash' then rows[#rows + 1] = event end
end
check(#rows == 1, 'the caller emits one row per changed file: ' .. #rows)
local row = rows[1] or {}
check(row.node == 'peer-one' and row.path == 'srv/app/main.py' and row.created == true
  and row.added == 3 and row.removed == 0, 'naming the node, the path and the counts: ' .. json.encode(row))
check(result.changes == nil, 'and the model\'s value carries no list: a card is the reader\'s')

-- ---- the view: the row the CLI draws --------------------------------------------------------
local view_lib = real_dofile('lua/core/cli_view.lua')
local buffer = {}
local view = view_lib.new({ out = function(text) buffer[#buffer + 1] = text end, live = false,
  now = function() return 0 end, limit = 100 })
view:event(row)
local drawn = table.concat(buffer)
check(drawn:find('created srv/app/main.py on peer-one (added 3 lines)', 1, true) ~= nil,
  'a created file on a peer reads as one row with its node and its count: ' .. string.format('%q', drawn))
buffer = {}
view_lib.new({ out = function(text) buffer[#buffer + 1] = text end, live = false,
  now = function() return 0 end, limit = 100 }):event({ type = 'remote_change', capability = 'bash',
  node = 'peer-one', path = 'srv/app/main.py', ok = false, error = 'already_modified' })
check(table.concat(buffer):find('could not run srv/app/main.py on peer-one: already_modified', 1, true) ~= nil,
  'and a change it could not attribute says why: ' .. table.concat(buffer))

host.getenv = env_get
if failed > 0 then
  error(string.format('peer bash changes: %d of %d checks failed, first: %s', failed, checks,
    tostring(first_fail)), 0)
end
print('peer bash changes ok (' .. checks .. ' checks)')
