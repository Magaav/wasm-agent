-- A WRITER KILLED MID-COMMIT IS NOT DAMAGE: the next call rolls the journal back and the index survives.
--
-- Measured 22/11 on this node: the install of 8862b600 swapped the running node while its graph worker was
-- writing, the killed writer left a database half the new revision and half the old one beside a rollback
-- journal holding the pre-images, and the component's read-only admission pre-flight answered
-- `database disk image is malformed`. The scheduler treats that verdict as damage - it moved 337 MB aside
-- (`graph_db_quarantined ... next=rebuild`) and rebuilt the index from nothing, three times in sixteen
-- minutes. The store was never damaged: the copy kept at `graph.db.malformed-20261123T000626Z` rolls back
-- to `integrity_check: ok` with all 101,422 of its nodes still there.
--
-- The fixture is `scripts/lib/crash-store.sh`: it builds the state a killed writer leaves and SQLite itself
-- verifies both halves of it (without the journal the read this row makes must FAIL, with it the store must
-- roll back to the exact answer it gave before the crash). So this row asserts recovery where the old path
-- quarantined: the same store answers, its journal is spent, no `graph.db.malformed-*` is created, and the
-- committed revision does not fall back to 1 as a rebuild's would.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function decode(raw, what)
  local value = json.decode(raw)
  assert(type(value) == 'table', what .. ' answered nothing: ' .. tostring(raw))
  return value
end
local data = paths.data()
local root = data .. '/crash-tree'
for f = 1, 120 do
  local body = {}
  for i = 1, 6 do body[#body + 1] = ('local function crash_%d_%d(a) return a+%d end'):format(f, i, i) end
  body[#body + 1] = ('local function crash_caller_%d() return crash_%d_1(1) end'):format(f, f)
  assert(host.write_file(root .. ('/m%03d.lua'):format(f), table.concat(body, '\n') .. '\n'))
end

local first = decode(host.graph_index(json.encode({root = root, wait_ms = 120000})), 'the first index')
assert(first.ok and (first.nodes or 0) > 0, 'the first index did not build: ' .. json.encode(first.error or first))
local db = assert(first.db, 'the index answer does not name its store')
local revision = (first.graph_snapshot and first.graph_snapshot.committed_revision) or first.committed_revision or 0
local answered = decode(host.graph_query('crash_1_1', json.encode({root = root})), 'the query before the crash')
assert(#answered > 0, 'the store did not answer before the crash')

-- The transaction a killed writer was in: every table the index writes, so the journal it leaves covers the
-- pages this store is read through.
local statements = data .. '/crash.sql'
assert(host.write_file(statements, table.concat({
  "UPDATE nodes SET name = name || ' crashed';",
  "UPDATE edges SET kind = kind || ' crashed';",
  "UPDATE files SET mtime = mtime + 1;",
  "UPDATE graph_sources SET source = x'00' || source;",
  "UPDATE graph_meta SET value = value || '';",
}, '\n') .. '\n'))
-- The read the component makes, in one query: table scans of the three tables its admission pre-flight
-- reads, so a torn page is a torn page and not an index the query happens to answer from.
local verify = "select (select count(*) from graph_sources where length(source)>0)+(select count(*) from graph_meta where length(value)>0);"
local helper = assert(host.getenv('WASM_AGENT_LUA_ROOT'), 'the row does not know the tree it runs from') .. '/scripts/lib/crash-store.sh'
local run = decode(host.exec('bash ' .. q(helper) .. ' ' .. q(db) .. ' ' .. q(statements) .. ' ' .. q(verify) .. ' ' .. q(data .. '/crash-work'), data, 300), 'crash-store')
assert(run.code == 0, 'the mid-commit fixture was not built (' .. tostring(run.code) .. '): ' .. tostring(run.stdout) .. tostring(run.stderr))
local dir = assert(db:match('^(.*)[/\\][^/\\]+$'), 'the store path has no directory')
local function listing()
  local answer = decode(host.exec('ls -a ' .. q(dir), data, 30), 'ls')
  return answer.stdout or ''
end
assert(listing():find('graph%.db%-journal'), 'the fixture left no rollback journal beside the store')

-- THE CALL THAT USED TO QUARANTINE.
local recovered = decode(host.graph_query('crash_1_1', json.encode({root = root})), 'the query after the crash')
assert(not recovered.error, 'a store a killed writer left mid-commit was refused: ' .. tostring(recovered.error))
assert(#recovered > 0, 'the recovered store did not answer')
assert(not listing():find('graph%.db%.malformed'), 'the crash state was quarantined, not rolled back: ' .. listing())
local second = decode(host.graph_index(json.encode({root = root})), 'the index after the crash')
assert(second.ok, 'indexing after the crash failed: ' .. json.encode(second.error or second))
local after = (second.graph_snapshot and second.graph_snapshot.committed_revision) or second.committed_revision or 0
assert(after >= revision and revision > 0, 'the store fell back to revision ' .. tostring(after) .. ' from ' .. tostring(revision) .. ', which is a rebuild and not a recovery')
assert(not listing():find('graph%.db%.malformed'), 'a quarantine copy was taken after the recovery: ' .. listing())
print('graph crash recovery ok: revision ' .. tostring(revision) .. ' kept, ' .. #recovered .. ' row(s) answered, no quarantine copy')
