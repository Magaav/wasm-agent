-- THE TWO INSTALL HAZARDS, NAMED (26/11, Fable, from the ring-mode answer).
--
-- 1. lua_core_shadows_release - a release install lays down the binary and nothing else of the Lua tree, so an
--    <install>/lua-core left by an earlier deploy keeps outranking the embedded copy while its manifest verifies
--    (rust/wa-host/src/main.rs:75-100): the node would run OLD Lua on NEW bytes. REFUSE, by name.
-- 2. release_update_reads_tree - build_status.relation compares the binary with the tree whenever a tree is
--    readable, so a release-installed node that still has a checkout answers stale in the release-update canary
--    while running exactly its release. WARN by name: the bytes are right and the judge is wrong, so it is
--    listed and never silently green, and it never blocks the rehearsal by itself.
local rehearse = dofile('lua/core/release_rehearse.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 130) .. ')') end

ok(type(rehearse.install_checks) == 'function', 'release_rehearse.install_checks is a named check')

local RING = { { node = 'release-node' }, { node = 'release-with-lua-core' }, { node = 'release-with-stale-tree' }, { node = 'tree-node' }, { node = 'quiet' } }
local FACTS = {
  ['release-node'] = { installed_from = 'release', lua_core = false, binary_commit = 'tttt1111', tree_commit = '', tree = '' },
  ['release-with-lua-core'] = { installed_from = 'release', lua_core = true, binary_commit = 'tttt1111', tree = '' },
  ['release-with-stale-tree'] = { installed_from = 'release', lua_core = false, binary_commit = 'tttt1111', tree_commit = 'ssss0000', tree = '/wt' },
  ['tree-node'] = { installed_from = 'tree', lua_core = true, binary_commit = 'ssss0000', tree_commit = 'ssss0000', tree = '/wt' },
}
local answer = rehearse.install_checks(RING, function(node) return FACTS[node] end)
local by = {}
for _, row in ipairs(answer.rows) do by[row.node] = row end

-- 1. a clean release install
ok(by['release-node'].verdict == 'ok', 'a release install with no <install>/lua-core is ok')
has(by['release-node'].detail, 'no <install>/lua-core', 'and says why')

-- 2. HAZARD 1: an old lua-core outranks the embedded copy
ok(by['release-with-lua-core'].verdict == 'refuse', 'an old <install>/lua-core on a release install is REFUSED')
ok(tostring(by['release-with-lua-core'].error) == 'lua_core_shadows_release', 'named lua_core_shadows_release (' .. tostring(by['release-with-lua-core'].error) .. ')')
has(by['release-with-lua-core'].detail, 'OLD', 'it says the node would run OLD Lua on the NEW binary')
has(by['release-with-lua-core'].detail, 'lua-core.prev', 'and the fix is on the line')
has(table.concat(answer.red, ' | '), 'lua_core_shadows_release', 'it joins the red list by name')

-- 3. HAZARD 2: the canary compares with a stale tree - named, and a warning
ok(by['release-with-stale-tree'].verdict == 'ok', 'the stale tree does not make the install itself wrong')
ok(tostring(by['release-with-stale-tree'].canary) == 'release_update_reads_tree', 'but release_update_reads_tree is named on the row')
has(table.concat(answer.warned, ' | '), 'release_update_reads_tree', 'and it is in the warned list')
has(table.concat(answer.warned, ' | '), 'binary tttt1111', 'naming the binary')
has(table.concat(answer.warned, ' | '), 'tree ssss0000', 'and the tree it would be compared with')
ok(#answer.red == 1, 'the warning is NOT counted as a refusal (' .. #answer.red .. ' red)')

-- 4. a tree node keeps its own rules: lua-core beside a tree install is deploy.sh's, not a shadow
ok(by['tree-node'].verdict == 'ok', 'lua-core on a TREE install is not a hazard')
ok(by['tree-node'].canary == nil, 'and a tree node at its own commit gets no canary warning')

-- 5. unchecked is never green
ok(by['quiet'].verdict == 'unchecked', 'a node that reported nothing is unchecked')

-- 6. and the rehearsal prints both, with the warning under its own heading
local report = rehearse.rehearse({
  ring = { { node = 'release-with-lua-core', mode = 'release' }, { node = 'release-with-stale-tree', mode = 'release' } },
  facts_of = function(node) return FACTS[node] end,
  read = function() return { ok = true, state = 'installed', installed_commit = 'tttt1111' } end,
  canaries = function() return { features = { { feature = 'release-update', ok = true, stage = 'identity' } } } end,
  local_results = { results = { { feature = 'release-update', ok = true, stage = 'identity' } } },
})
ok(report.ok == false, 'the rehearsal is RED for a node whose lua-core shadows the release')
has(table.concat(report.red, ' | '), 'lua_core_shadows_release', 'named in the red list')
local text = table.concat(report.lines, '\n')
has(text, 'WARNINGS', 'the report has a WARNINGS block')
has(text, 'release_update_reads_tree', 'with the canary warning inside it')
has(text, 'install release-with-lua-core', 'and the install check line for the refused node')

if failed > 0 then print(string.format('release install checks FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('release install checks ok (%d checks)', checks))
return 0
