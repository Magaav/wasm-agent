-- A local write or edit receipt names the node it wrote on (mission write-names-its-node).
--
-- Measured 22/11 on a DeepSeek session working on nextcloud: `tools.write` defaulted to the local node,
-- so a path meant for the peer landed on avell, and the receipt said `ok: true` and no more - binary
-- success with the wrong target, which cost a whole round. The `remote` result already named its peer
-- ({"node":"nextcloud","ok":true,"path":...}); the local one did not.
--
-- What this holds:
--   * the result a run block gets from tools.write and tools.edit carries node = this node's name, the
--     same word `nodes` reports for it, so a script compares the two without learning a second word;
--   * every field the receipt had before is still there (path, ok, graph_index, applied, version): the
--     node is added, nothing is replaced;
--   * a refusal of the same two tools carries it as well - a refusal on the wrong node is the same
--     confusion with less damage;
--   * when the name cannot be read the field is ABSENT, never invented: unknown is not yes.
--
-- It adds no `node` parameter to write or edit: the schema text is what the model reads at the start of
-- every session, and changing that is a release-time decision, not this mission's. It runs under
-- scripts/fast.sh with its own scratch home and refuses the real ~/.wasm-agent first.

local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local function refuse(why) print('REFUSED test-write-node-receipt: ' .. why); os.exit(2) end
-- The scratch-home rule from one place, the same four refusals the shell guard makes.
local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-write-node-receipt')
if why_home then refuse(why_home) end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local nodes = dofile('lua/core/nodes.lua')

local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end

-- A name this test owns, in this test's own home, so the assertion does not depend on what machine it
-- runs on. node_name() reads this file first, which is also what keeps the row hermetic.
local chosen = 'wn-receipt-node'
check((host.write_file(paths.config() .. '/node.name', chosen .. '\n') ~= false), 'the scratch home takes a node name')
local named = nodes.node_name()
check(named == chosen, 'the fixture node is named by its own home, got: ' .. tostring(named))
-- The word `nodes` reports for this node is the word the receipt must use: one vocabulary, not two.
local listed
for _, item in ipairs(nodes.list({ cached = true })) do
  if item.local_node then listed = item.name; break end
end
check(listed == chosen, 'nodes reports the same name, got: ' .. tostring(listed))

local tools = dofile('lua/core/tools.lua')
local sid = memory.start_session('', 'write node receipt', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master', role = 'master' }
local target = paths.data() .. '/receipt-fixture.txt'

-- ONE REAL RUN BLOCK, the path a model's script takes: the value the script receives from
-- `await tools.write(...)` is the tool's own result, which is what carries the node.
local function run(code)
  local result = tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx)
  if not result.ok then error('run block failed: ' .. json.encode(result):sub(1, 600)) end
  local item = result.items and result.items[1]
  if not item or type(item.text) ~= 'string' then error('run block printed no text: ' .. json.encode(result):sub(1, 600)) end
  return json.decode(item.text), result
end

-- The refusal is caught inside the script: a call that failed is a failed script (docs/CODEMODE.md), and
-- the text it carries is the refusal a model reads.
local got = run('const w=await tools.write({path:' .. json.encode(target) .. ',content:"hi"});'
  .. ' const e=await tools.edit({path:' .. json.encode(target) .. ',edits:[{old_text:"hi",new_text:"ho"}]});'
  .. ' let refused; try{ await tools.edit({path:' .. json.encode(target) .. ',edits:[{old_text:"ho",new_text:"ha"}],old_text:"ho",new_text:"ha"}); }'
  .. ' catch(err){ refused=String((err&&err.message)||err); }'
  .. ' text(JSON.stringify({w,e,refused})); return 1;')

-- The write receipt: the node, and every field it had before (the golden shape recorded from the base
-- path: ok, path, graph_index - a write that applies keeps all three).
check(got.w and got.w.ok == true, 'the write applied: ' .. json.encode(got.w))
check(got.w.node == chosen, 'the write receipt names the node it wrote on: ' .. json.encode(got.w))
check(got.w.path == target, 'the write receipt still names the path: ' .. json.encode(got.w))
check(type(got.w.graph_index) == 'table', 'the write receipt still carries graph_index: ' .. json.encode(got.w))
check(host.read_file(target) == 'ho', 'the edit in the same block applied after the write')

-- The edit receipt: node plus the fields an applied edit always had.
check(got.e and got.e.applied == true, 'the edit applied: ' .. json.encode(got.e))
check(got.e.node == chosen, 'the edit receipt names the node it edited on: ' .. json.encode(got.e))
check(got.e.path == target, 'the edit receipt still names the path: ' .. json.encode(got.e))

-- A refusal is a result too, and it is the one a model reads when it aimed at the wrong node. Two
-- forms, one dispatcher: the text the script catches and the object a direct call gets.
local refusal = json.decode(got.refused or '{}')
check(refusal.error == 'mixed_edit_forms', 'the edit refusal still refuses by name: ' .. tostring(got.refused))
check(refusal.node == chosen, 'the refusal names the node it refused on: ' .. tostring(got.refused))
local direct = tools.dispatch(memory, 'edit', { path = target, edits = { { old_text = 'ho', new_text = 'ha' } },
  old_text = 'ho', new_text = 'ha' }, 'master', ctx)
check(direct.error == 'mixed_edit_forms' and direct.node == chosen,
  'a direct refusal carries the same node: ' .. json.encode(direct))

-- UNKNOWN IS NOT YES. A fresh dofile is its own module with its own cache (the same property the file's
-- own comments rely on), so the name lookup can be made to fail before anything is cached: the receipt
-- then has no node at all - not "host", not an empty string, not the path's directory.
local real_read = host.read_file
local name_file = (paths.config() .. '/node.name'):gsub('\\', '/')
host.read_file = function(path)
  if type(path) == 'string' and path:gsub('\\', '/') == name_file then error('fixture: the name is unreadable') end
  return real_read(path)
end
local unreadable_ok, unreadable = pcall(function()
  local blind = dofile('lua/core/tools.lua')
  return blind.dispatch(memory, 'write', { path = paths.data() .. '/blind.txt', content = 'x' }, 'master', ctx)
end)
host.read_file = real_read
check(unreadable_ok, 'the blind dispatch ran: ' .. tostring(unreadable))
check(type(unreadable) == 'table' and unreadable.ok == true, 'the blind write still applied: ' .. json.encode(unreadable))
check(unreadable.node == nil, 'an unreadable name leaves the field absent, never invented: ' .. json.encode(unreadable))

-- Nothing was left behind on the operator store: this row wrote only inside its own home.
check(host.read_file(target) == 'ho', 'the fixture path is the scratch home, not a real checkout')

print(json.encode({ ok = true, checks = checks, node = chosen }))
