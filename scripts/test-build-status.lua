-- A row inherits nothing it was not given, and a build is graded against the bytes it embeds.
--
-- Item 4 of the node-ops round (#45). Two measured defects, and they are different questions:
--   * a row inherited whatever WASM_AGENT_* the session had (scripts/fast.sh cleared four names and grew
--     the list one leak at a time), so a fixture could reach the operator's real vault or ledger;
--   * nothing a MODEL could call said whether the binary it was grading was this tree's build. A row
--     was green against another commit's node.
--
-- What this holds:
--   * lua/core/build_status.lua reports fresh/stale/edited/unknown from real git state, and never answers
--     fresh when a fact is missing;
--   * the tools.build tool answers the same facts;
--   * scripts/fast.sh clears by ALLOW-LIST: every WASM_AGENT_* but the five the runner sets is removed,
--     which is checked by reading the runner's own source (a block-list would pass this only by luck).
--
-- It runs in a scratch home and refuses the real ~/.wasm-agent first.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local function refuse(why) print('REFUSED test-build-status: ' .. why); os.exit(2) end
-- THE SCRATCH-HOME RULE, FROM ONE PLACE (item 3 of the node-ops round): scripts/lib/scratch-home.lua
-- carries the same four refusals the shell guard makes. This row used to compare WASM_AGENT_HOME
-- with $HOME/.wasm-agent - the wrong side - so WASM_AGENT_HOME=$HOME passed it and the row acted on
-- the operator store.
local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-build-status')
if why_home then refuse(why_home) end
local home = host.getenv('WASM_AGENT_HOME') or ''
local function norm(v) return (tostring(v or ''):gsub('\\', '/'):gsub('/+$', '')):lower() end
if norm(paths.data()):sub(1, #norm(home)) ~= norm(home) then refuse('the data directory is outside the scratch home') end
pcall(host.exec, 'mkdir -p ' .. ("'%s'"):format(paths.data()), '', 60)
local memory = dofile('lua/core/memory.lua')
memory.setup()

local build = dofile('lua/core/build_status.lua')
local status = build.status()
assert(type(status) == 'table', 'build_status answered nothing')
assert(status.relation ~= nil, 'build_status named no relation')
assert(status.why ~= nil and status.why ~= '', 'build_status gave no reason for its verdict')
-- The verdict must be one of the four, and unknown must never be reported as fresh.
local allowed = { fresh = true, stale = true, edited = true, unknown = true }
assert(allowed[status.relation], 'build_status invented a relation: ' .. tostring(status.relation))
if status.relation == 'unknown' then
  assert(status.ok == false, 'an unknown relation was reported as ok, which is the failure this tool exists for')
end
if status.relation == 'fresh' then
  assert(status.binary.commit == status.tree.head, 'fresh was claimed with the binary and the tree at different commits')
  assert(status.tree.clean ~= false, 'fresh was claimed while the embedded paths are edited')
end

-- All four verdicts, driven as data rather than hoping this node happens to be in each state. A relation
-- that cannot be produced on demand is a relation nobody has tested.
local cases = {
  { name = 'fresh', tree = { head = 'a', clean = true }, binary = { commit = 'a' }, want = 'fresh' },
  { name = 'stale', tree = { head = 'a', clean = true }, binary = { commit = 'b' }, want = 'stale' },
  { name = 'edited', tree = { head = 'a', clean = false, edited = { ' M lua/core/x.lua' } }, binary = { commit = 'a' }, want = 'edited' },
  { name = 'unknown-no-commit', tree = { head = 'a', clean = true }, binary = {}, want = 'unknown' },
  { name = 'unknown-no-tree', tree = {}, binary = { commit = 'a' }, want = 'unknown' },
  { name = 'unknown-dirty-unreadable', tree = { head = 'a' }, binary = { commit = 'a' }, want = 'unknown' },
}
for _, case in ipairs(cases) do
  local got, why = build.relation(case.tree, case.binary)
  assert(got == case.want, case.name .. ' produced ' .. tostring(got) .. ', expected ' .. case.want)
  assert(type(why) == 'string' and why ~= '', case.name .. ' gave no reason')
end

-- Item 7 of the node-ops round: the two facts a commit comparison cannot see, driven as data.
-- A binary that records ITSELF as built from a dirty tree at this commit is 'edited', never 'fresh':
-- it embeds edits the clean tree does not have.
local dirty_cases = {
  { name = 'dirty-build-same-commit', tree = { head = 'a', tree = 't1', clean = true },
    binary = { commit = 'a', built_tree = 't1', built_dirty = 'true' }, want = 'edited' },
  { name = 'dirty-build-flag-true', tree = { head = 'a', tree = 't1', clean = true },
    binary = { commit = 'a', built_tree = 't1', built_dirty = true }, want = 'edited' },
  { name = 'clean-build-same-commit-and-tree', tree = { head = 'a', tree = 't1', clean = true },
    binary = { commit = 'a', built_tree = 't1', built_dirty = 'false' }, want = 'fresh' },
  { name = 'same-commit-different-tree', tree = { head = 'a', tree = 't2', clean = true },
    binary = { commit = 'a', built_tree = 't1', built_dirty = 'false' }, want = 'stale' },
}
for _, case in ipairs(dirty_cases) do
  local got, why = build.relation(case.tree, case.binary)
  assert(got == case.want, case.name .. ' produced ' .. tostring(got) .. ', expected ' .. case.want .. ' (' .. tostring(why) .. ')')
  assert(type(why) == 'string' and why ~= '', case.name .. ' gave no reason')
end
-- The tool answers the same facts, so a model can reach them.
local toolslib = dofile('lua/core/tools.lua')
local answer = toolslib.dispatch(memory, 'build', {}, 'admin', { user_id = 'fixture' })
assert(type(answer) == 'table' and answer.relation ~= nil, 'the build tool answered nothing: ' .. json.encode(answer))
assert(answer.relation == status.relation, 'the tool and the module disagree: ' .. tostring(answer.relation) .. ' vs ' .. tostring(status.relation))

-- The runner's clearing is an allow-list, read out of its own source: this is a source assertion on
-- purpose and it says so. A block-list cannot pass it, and a block-list is what let a fixture reach the
-- operator's vault.
local root = host.getenv('WASM_AGENT_LUA_ROOT') or '.'
local fast = host.read_file(root .. '/scripts/fast.sh')
assert(type(fast) == 'string', 'scripts/fast.sh could not be read')
-- The row exec (and with it the clearing) lives in scripts/lib/fast-row-exec.sh since item 1 of the
-- node-ops round, so the assertion reads BOTH files as one source: the rule is unchanged, the place
-- moved, and an assertion that stopped looking would pass by finding nothing.
local row_exec = host.read_file(root .. '/scripts/lib/fast-row-exec.sh')
assert(type(row_exec) == 'string', 'scripts/lib/fast-row-exec.sh could not be read')
fast = fast .. '\n' .. row_exec
assert(fast:find('cleared_flags', 1, true), 'scripts/fast.sh computes no cleared set, so what a row inherits is still a hand-kept list')
assert(fast:find('WASM_AGENT_[A-Za-z0-9_]*', 1, false), 'scripts/fast.sh does not scan the WASM_AGENT_* namespace')
assert(fast:find('grep -vx', 1, true), 'scripts/fast.sh does not exclude the runner-set names by exact match, so an allow-list is not what it applies')
for _, name in ipairs({ 'WASM_AGENT_LUA_ROOT', 'WASM_AGENT_HOME', 'WASM_AGENT_RENDEZVOUS', 'WASM_AGENT_RELAY', 'WASM_AGENT_MANAGED' }) do
  assert(fast:find(name, 1, true), 'scripts/fast.sh does not name ' .. name .. ' as a runner-set variable, so its allow-list is incomplete')
end
assert(not fast:find('env -u WASM_AGENT_VAULT_URL', 1, true),
  'scripts/fast.sh still clears by an explicit block-list, so a variable nobody listed still reaches a row')


-- ITEM 4 OF THE NODE-OPS ROUND, THROUGH THE REAL host.runtime_info (not a synthetic table): the
-- document a MODEL can reach must carry the fact that makes 'edited' possible. A binary built from a
-- dirty work tree embeds code this checkout does not have, so the same commit is not the same bytes;
-- before this field existed, build_status graded such a binary 'fresh' at the tree HEAD, and the
-- report said 'edited' about a comparison that could never produce it.
local raw = host.runtime_info and host.runtime_info()
assert(type(raw) == 'string', 'host.runtime_info answered no JSON string')
local decoded, runtime = pcall(json.decode, raw)
assert(decoded and type(runtime) == 'table', 'host.runtime_info did not decode: ' .. tostring(raw):sub(1, 120))
assert(runtime.build_source_commit ~= nil, 'host.runtime_info names no build_source_commit')
local dirty = runtime.build_source_dirty
assert(dirty ~= nil,
  'host.runtime_info carries no build_source_dirty, so build_status cannot tell a dirty build from this tree (item 4)')
assert(dirty == 'true' or dirty == 'false' or dirty == 'unknown',
  'build_source_dirty is ' .. tostring(dirty) .. ', not true/false/unknown')
-- And the relation the module reports for THIS process must be consistent with that field: a binary
-- that says it was built dirty cannot be 'fresh' at its own commit.
local live = build.status()
assert(live.binary and live.binary.built_dirty == dirty, 'build_status read ' .. tostring(live.binary and live.binary.built_dirty)
  .. ' where runtime_info says ' .. tostring(dirty) .. ': the module and the document disagree')
if dirty == 'true' and live.binary.commit and live.tree.head and live.binary.commit == live.tree.head then
  assert(live.relation == 'edited', 'a binary built from a DIRTY tree at the tree commit was graded ' .. tostring(live.relation)
    .. ', and ' .. tostring(live.why))
end
print('build status: runtime_info names build_source_dirty=' .. tostring(dirty) .. ', and this process is graded ' .. tostring(live.relation))
print('build status ok: relation ' .. status.relation .. ' with its reason, the tool agrees, and the runner clears WASM_AGENT_* by allow-list')
