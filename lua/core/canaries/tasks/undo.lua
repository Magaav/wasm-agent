-- CANARY TASK: /undo, end to end, in this child's own ledger and its own files.
--
-- The path a user takes: a tool WRITES a file (which records the change), and /undo puts the previous text
-- back. Both halves are the shipping ones - lua/core/tools.lua's write dispatch records into
-- lua/core/changeset.lua, and lua/core/undo_command.lua restores and verifies the version it restored -
-- so a change in the record, the restore, or the verification fails here by name.
local json = dofile('lua/vendor/json.lua')
local h = dofile('lua/core/canaries/tasks/harness.lua')

h.stage('ledger')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local changeset = dofile('lua/core/changeset.lua')
local undo = dofile('lua/core/undo_command.lua')
local nodes = dofile('lua/core/nodes.lua')
local tools = dofile('lua/core/tools.lua')

h.stage('session')
local sid = memory.start_session('', 'canary: undo', { user_id = 'master' })
h.check(type(sid) == 'string' and sid ~= '', 'session', 'no session was created: ' .. tostring(sid))

h.stage('file')
local home = os.getenv('WASM_AGENT_HOME') or ''
local demo = home .. '/canary-undo.txt'
h.check(host.write_file(demo, 'one\ntwo\nthree\n'), 'file', 'the file to change could not be written: ' .. demo)

h.stage('write')
local ctx = { session_id = sid, user_id = 'master', changes = changeset.new() }
local written = tools.dispatch(memory, 'write', { path = demo, content = 'one\nTWO\nthree\n' }, 'master', ctx)
h.check(type(written) == 'table' and written.ok == true, 'write', 'the write tool refused: ' .. tostring(json.encode(written)))
h.check(host.read_file(demo) == 'one\nTWO\nthree\n', 'write', 'the write tool did not change the file')
memory.append_turn(sid, { id = host.uuid(), role = 'assistant', content = 'changed the second line',
  changes = changeset.summary(ctx.changes) })

h.stage('undo')
local report = undo.run({ session_id = sid, memory = memory, changeset = changeset, nodes = nodes })
h.check(type(report) == 'table' and report.ok == true, 'undo', 'the undo refused: ' .. tostring(json.encode(report)))
h.check(host.read_file(demo) == 'one\ntwo\nthree\n', 'undo', 'the file does not hold its previous text again')

h.stage('readback')
local again = undo.run({ session_id = sid, memory = memory, changeset = changeset, nodes = nodes })
h.check(type(again) == 'table' and again.ok == false and again.category == 'version_moved', 'readback',
  'a second undo did not refuse by name: ' .. tostring(json.encode(again)))
h.ok()
