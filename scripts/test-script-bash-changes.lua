-- A SCRIPT'S COMMAND CHANGED FILES, SAID THE WAY A DIRECT ONE IS (chat-view-round-2, item 2).
--
-- Victor, 23/11: "edit rounds does not get the code diff printed" - 3 of 115 messages carried a change
-- while the model made about 7 remote edits, 11 remote writes and several changes by running python
-- on the peer. Re-measured on the base through the real dispatcher (measured 23/11, scratch work
-- tree):
--
--   local write           -> change card                    (worked)
--   local edit            -> change card                    (worked)
--   direct bash, modified -> bash_changes[1] tracked.txt     (worked)
--   DIRECT bash, created  -> NOTHING                         (git status -uno hid the new file)
--   SCRIPT bash, modified -> NOTHING                         (the watcher is after the branch's
--                                                             managed-operation return, so a command
--                                                             run inside a `run` block was never
--                                                             watched at all - and code mode is the
--                                                             one execution path this node has)
--   SCRIPT bash, created  -> NOTHING
--
-- What this pins, through tools.dispatch and code mode exactly as a run does it:
--   1. a script's `tools.bash` that MODIFIES a tracked file emits one `bash_changes` with the two
--      texts a card is drawn from;
--   2. a script's `tools.bash` that CREATES a file emits it too, with an empty before side - a create
--      is a fact, not a guess;
--   3. a file that was already modified before the command is REFUSED by name instead of blamed on it
--      (the module's own rule, unchanged: a guessed before side would take a reader's earlier work);
--   4. a read-only command emits nothing (no snapshot, no card);
--   5. the DIRECT bash path still emits exactly one event - the fix must not draw a command twice.
--
-- Hermetic: its own scratch home, its own git work tree inside it, no peer and no fleet. A run where
-- the tree cannot be made (no git) refuses by name instead of passing.
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

-- git is what the module reads the work tree with: no git, no measurement, and a named refusal.
local have_git = false
do
  local ok, raw = pcall(host.exec, 'git --version', '', 10, json.encode({ tool = 'bash' }))
  local decoded = ok and type(raw) == 'string' and json.decode(raw) or nil
  have_git = type(decoded) == 'table' and decoded.code == 0
end
if not have_git then
  error('this test needs git (lua/core/bash_changes.lua reads the work tree with it); nothing was measured', 0)
end

local env_get = host.getenv
host.getenv = function(key) if key == 'WASM_AGENT_CODEMODE' then return 'native' end return env_get(key) end
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local changeset = dofile('lua/core/changeset.lua')
local paths = dofile('lua/core/paths.lua')

-- The sandbox itself: no code-mode assets means no script ran, and a row that could not run what it
-- measures is a refusal here, never a pass.
local ready = false
if type(host.quickjs) == 'function' then
  local ok, raw = pcall(host.quickjs, 'ready', '{}')
  local decoded = ok and type(raw) == 'string' and json.decode(raw) or nil
  ready = type(decoded) == 'table' and decoded.ok == true
end
if not ready then error('this node has no embedded code-mode assets, so no script ran and nothing here was measured', 0) end

local tree = tostring(paths.data()) .. '/tree'
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
-- os.execute answers true/nil on 5.4 and a status number on 5.1: both mean the same thing here.
check(seeded == true or seeded == 0, 'the scratch work tree is a git repository with one committed file')

local sid = memory.start_session('', 'script bash changes', { user_id = 'master' })
local sink = {}
local ctx = { session_id = sid, user_id = 'master', changes = changeset.new(), watch_changes = true,
  change_queue = {}, emit = function(event) sink[#sink + 1] = event end,
  read_only_command = function(command)
    return dofile('lua/core/orchestration_mode.lua').read_only_command(command)
  end }

-- Everything that reached the reader for one call: the queue the agent drains, then the direct sink.
local function drain()
  local out = {}
  for _, event in ipairs(ctx.change_queue) do out[#out + 1] = event end
  for i = #ctx.change_queue, 1, -1 do ctx.change_queue[i] = nil end
  for _, event in ipairs(sink) do out[#out + 1] = event end
  for i = #sink, 1, -1 do sink[i] = nil end
  return out
end
local function bash_events(events)
  local out = {}
  for _, event in ipairs(events) do if event.type == 'bash_changes' then out[#out + 1] = event end end
  return out
end
local function run_script(code)
  drain()
  local result = tools.dispatch(memory, 'run', { code = code }, 'master', ctx)
  return result, drain()
end
local function bash_in_script(command)
  return run_script('const r = await tools.bash({command:' .. string.format('%q', command)
    .. ', cwd:' .. string.format('%q', tree) .. '}); return 1;')
end

-- 1. a script's command that MODIFIES a tracked file
local result, events = bash_in_script('printf "a\\nB\\n" > tracked.txt')
check(type(result) == 'table' and result.error == nil, 'the script ran: ' .. tostring(result and result.error))
local found = bash_events(events)
check(#found == 1, 'a script\'s bash that changed a tracked file emits ONE bash_changes: ' .. #found)
local first = found[1] or { files = {} }
check(#first.files == 1, 'with one file in it: ' .. json.encode(first.files))
local entry = first.files[1] or {}
check(entry.path == 'tracked.txt', 'named: ' .. tostring(entry.path))
check(entry.before_text == 'a\nb\n' and entry.after_text == 'a\nB\n',
  'and with the two texts a card is drawn from: ' .. json.encode({ before = entry.before_text, after = entry.after_text }))
check(first.command ~= nil and first.command:find('tracked.txt', 1, true) ~= nil, 'the event names its command')

-- 2. a script's command that CREATES a file (the `-uno` snapshot used to hide every new file)
os.execute('git -C ' .. string.format('%q', tree) .. ' checkout -q -- .')
local created_result, created_events = bash_in_script('printf "new\\n" > created.txt')
check(type(created_result) == 'table' and created_result.error == nil, 'the second script ran')
local created = bash_events(created_events)
check(#created == 1, 'a script\'s bash that CREATED a file says so: ' .. #created)
local new_file = (created[1] and created[1].files and created[1].files[1]) or {}
check(new_file.path == 'created.txt', 'with the file it created: ' .. tostring(new_file.path))
check(new_file.before_text == '' and new_file.after_text == 'new\n',
  'an empty before side, which is what a create IS: ' .. json.encode({ before = new_file.before_text, after = new_file.after_text }))

-- 3. a file already modified before the command is refused by name, never blamed on it
os.execute('git -C ' .. string.format('%q', tree) .. ' checkout -q -- .')
os.execute('printf "dirty\\n" > ' .. string.format('%q', tree .. '/tracked.txt'))
local _, dirty_events = bash_in_script('git add tracked.txt')
local dirty = bash_events(dirty_events)
local refused = (dirty[1] and dirty[1].refused) or {}
check(#refused == 1 and refused[1].path == 'tracked.txt' and refused[1].why == 'already_modified',
  'a file that was already modified is refused with its reason: ' .. json.encode(refused))

-- 4. a read-only command: nothing to say, and nothing asked of git
os.execute('git -C ' .. string.format('%q', tree) .. ' checkout -q -- .')
local _, quiet = bash_in_script('git status --porcelain')
check(#bash_events(quiet) == 0, 'a read-only command emits no change at all: '
  .. json.encode({ #bash_events(quiet) }))

-- 5. the DIRECT path still emits exactly one event (the fix must not draw a command twice)
os.execute('git -C ' .. string.format('%q', tree) .. ' checkout -q -- .')
drain()
local direct = tools.dispatch(memory, 'bash', { command = 'printf "a\\nZ\\n" > tracked.txt', cwd = tree },
  'master', ctx)
local direct_events = bash_events(drain())
check(type(direct) == 'table' and direct.error == nil, 'the direct call ran')
check(#direct_events == 1, 'a DIRECT bash that changed a tracked file emits ONE event, not two: '
  .. #direct_events)

host.getenv = env_get
if failed > 0 then
  error(string.format('script bash changes: %d of %d checks failed, first: %s', failed, checks,
    tostring(first_fail)), 0)
end
print('script bash changes ok (' .. checks .. ' checks)')
