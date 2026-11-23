-- A QUARANTINE KEEPS THE EVIDENCE THAT EXPLAINS IT: two quarantines of one store leave two copies.
--
-- Measured on this node, 22/11: `quarantine_database` deleted every earlier `graph.db.malformed-*` of the
-- same store before renaming the new one, so the copy that explained a quarantine was destroyed by the
-- next quarantine. The mission brief's own evidence file
-- `~/.wasm-agent/graph.db.malformed-20261122T144358Z` was gone 71 s after it was made, and the copy kept from
-- 23/11T000626Z lasted one cycle less than the report that cited it. A quarantine nobody can read afterwards
-- cannot be answered: this row is what makes the retention rule real, through the path a user's node takes.
--
-- THE PATH IS THE REAL ONE, and it crosses a process boundary: the store is built by the `graph` component
-- inside wasmtime, damaged the way a killed writer leaves it (a torn page, `scripts/lib/crash-store.sh`'s
-- sibling class), and the quarantine is decided by the scheduler thread of the node binary while the row is
-- answering. Nothing here calls the scheduler directly.
--
-- What it asserts, and what each assertion is worth on the code before this change:
--   * the first quarantine leaves exactly one copy, and that copy is the store that was broken (its own
--     `integrity_check` names damage: evidence that cannot be read is not evidence);
--   * the SECOND quarantine leaves TWO copies, the older one byte for byte as it was - this is the
--     assertion that fails on the code before this change, which kept one;
--   * the node answers again afterwards, so the quarantine is still the rebuild it always was.
--
-- THE COMPONENT THIS ROW NEEDS, named so the runner installs it: `WA_GRAPH_COMPONENT_WASM`. The fast path
-- builds each component from THIS tree and gives every row that names `WA_<NAME>_COMPONENT_WASM` that
-- artifact in the row's own home (`scripts/fast.sh`, "the components the Lua rows need"). Measured on this
-- node, 23/11: without the name the row runs against a home with no component and answers
-- `graph_component_unavailable: component_not_installed:graph`, which is a failure of the runner's promise,
-- not of the store.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local guard = dofile('scripts/lib/test-home-guard.lua')
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function decode(raw, what)
  local value = json.decode(raw)
  assert(type(value) == 'table', what .. ' answered nothing: ' .. tostring(raw))
  return value
end

-- Rule 2: a row that writes state builds its own scratch home and refuses the live one by name.
local home = host.getenv('WASM_AGENT_HOME')
local scratch = host.getenv('GATE_ROOT') or host.getenv('TMPDIR')
local refusal = guard.reason({home = home, scratch = scratch})
assert(refusal == nil, 'refusing to run: ' .. tostring(refusal) .. ' - this row builds and quarantines a graph store')

local data = paths.data()
local root = data .. '/evidence-tree'
for f = 1, 80 do
  local body = {}
  for i = 1, 5 do body[#body + 1] = ('local function evidence_%d_%d(a) return a+%d end'):format(f, i, i) end
  body[#body + 1] = ('local function evidence_caller_%d() return evidence_%d_1(1) end'):format(f, f)
  assert(host.write_file(root .. ('/e%03d.lua'):format(f), table.concat(body, '\n') .. '\n'))
end

local first = decode(host.graph_index(json.encode({root = root, wait_ms = 120000})), 'the first index')
assert(first.ok and (first.nodes or 0) > 0, 'the first index did not build: ' .. json.encode(first.error or first))
local db = assert(first.db, 'the index answer does not name its store')
local dir = assert(db:match('^(.*)[/\\][^/\\]+$'), 'the store path has no directory')

local function sql(uri, statement)
  local answer = decode(host.exec('sqlite3 ' .. q(uri) .. ' ' .. q(statement), data, 60), 'sqlite3')
  return (answer.stdout or ''):gsub('%s+$', ''), answer.code
end
local function immutable(path) return 'file:' .. path .. '?immutable=1' end
local function listing()
  local answer = decode(host.exec('ls -a ' .. q(dir), data, 30), 'ls')
  return answer.stdout or ''
end
local function copies()
  local found = {}
  for name in listing():gmatch('[^\n]+') do
    if name:find('graph%.db%.malformed%-') then found[#found + 1] = name end
  end
  table.sort(found)
  return found
end

-- The damage a killed writer leaves when its journal is gone: one page of the table b-tree zeroed. The
-- rollback journal exists for exactly this class, and no journal means no rollback - so the store really is
-- inconsistent, and a quarantine is the honest answer.
local function tear_the_store()
  local page = sql(db, "select rootpage from sqlite_master where name='edges'")
  local size = sql(db, 'pragma page_size')
  assert(tonumber(page) and tonumber(page) > 1, 'the store has no edges b-tree to tear: ' .. tostring(page))
  local answer = decode(host.exec('dd if=/dev/zero of=' .. q(db) .. ' bs=' .. size .. ' seek=' .. (tonumber(page) - 1)
    .. ' count=1 conv=notrunc status=none', data, 60), 'dd')
  assert(answer.code == 0, 'the store was not torn: ' .. tostring(answer.stderr))
end

-- A quarantine is decided by the scheduler's worker after a failed component call, so the row tears the
-- store, CHANGES CONTENT, enqueues the root exactly as an edit does and waits for the copy: the real path,
-- never a direct call. The content change is not decoration - admission compares a manifest fingerprint
-- first, so a store nobody edited is declared fresh and is never written, and a torn store in that state
-- would be discovered by no index run at all.
local round = 0
local function quarantine_once(what, wanted)
  round = round + 1
  tear_the_store()
  local verdict, code = sql(immutable(db), 'pragma integrity_check(100000);')
  assert(code ~= 0 or verdict ~= 'ok', what .. ': the torn store still passes integrity_check, so this row would measure nothing')
  assert(host.write_file(root .. ('/changed_%d.lua'):format(round), ('local function changed_%d(a) return a end'):format(round)))
  local before = #copies()
  decode(host.graph_notify(json.encode({root = root})), 'notify')
  local deadline = os.time() + 120
  while #copies() <= before do
    assert(os.time() < deadline, what .. ': no quarantine copy appeared within 120 s; listing: ' .. listing())
    host.exec('sleep 1', data, 10)
  end
  local found = copies()
  assert(#found == wanted, what .. ': expected ' .. wanted .. ' cop(y/ies), found ' .. #found .. ': ' .. table.concat(found, ' '))
  return found
end

local one = quarantine_once('the first quarantine', 1)
local copy = dir .. '/' .. one[1]
local copy_text, copy_code = sql(immutable(copy), 'pragma integrity_check(100000);')
assert(copy_code ~= 0 or copy_text ~= 'ok', 'the kept copy is not the broken store: it passes integrity_check')
local preserved = assert(host.read_file(copy), 'the kept copy cannot be read, so it is not evidence')

-- The node rebuilds and answers again: a quarantine is still a quarantine.
local deadline = os.time() + 120
local answered = false
while os.time() < deadline do
  local answer = decode(host.graph_query('evidence_1_1', json.encode({root = root})), 'the query after the rebuild')
  if not answer.error and #answer > 0 then answered = true break end
  host.exec('sleep 1', data, 10)
end
assert(answered, 'the node never answered again after the quarantine: ' .. listing())

-- THE RULE: the second quarantine keeps the first one's evidence.
local two = quarantine_once('the second quarantine', 2)
assert(#two == 2, 'the retention rule kept ' .. #two .. ' copies instead of two: ' .. table.concat(two, ' '))
local older = two[1] == one[1] and two[2] or two[1]
assert(older == one[1], 'the copy that survived is not the one the first quarantine made: ' .. table.concat(two, ' '))
assert(host.read_file(dir .. '/' .. older) == preserved, 'the older copy was rewritten, so it is no longer the store that was quarantined')
print('graph quarantine evidence ok: ' .. #two .. ' copies kept, the older one byte for byte, and the node answered again')
