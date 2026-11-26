-- THE MODE PREFLIGHT (26/11, Fable, from the v0.1.2 (c) stop): a ring mode a node cannot install is named
-- BEFORE the deploy step, not 186 s into it. Two refusals the cut kept meeting mid-flight:
--   no_runtime_tree - a tree-less node asked for tree mode (remote_update.lua:578);
--   canonical_busy  - a tree node whose HEAD is not exactly origin/main (scripts/deploy.sh:600), which is what
--                     stopped v0.1.2 (c) when a train landing moved main to ec7525e0 under a cut targeting T5.
-- Release mode reads no checkout, so for those two shapes it is the answer - and the preflight says so.
local rehearse = dofile('lua/core/release_rehearse.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 120) .. ')') end

ok(type(rehearse.mode_preflight) == 'function', 'release_rehearse.mode_preflight is a named check')

local RING = {
  { node = 'this node', mode = 'local' },
  { node = 'tree-fresh', mode = 'tree' },
  { node = 'tree-behind', mode = 'tree' },
  { node = 'no-tree', mode = 'tree' },
  { node = 'prebuilt-tree', mode = 'release' },
}
local FACTS = {
  ['this node'] = { mode = 'local', tree = '/wt' },
  ['tree-fresh'] = { mode = 'tree', tree = '/wt', head = 'aaaa1111', origin_main = 'aaaa1111' },
  ['tree-behind'] = { mode = 'tree', tree = '/wt', head = 'bbbb2222', origin_main = 'aaaa1111' },
  ['no-tree'] = { mode = 'tree' },
  ['prebuilt-tree'] = { mode = 'release', tree = '/wt', head = 'bbbb2222', origin_main = 'aaaa1111' },
}
local preflight = rehearse.mode_preflight(RING, function(node) return FACTS[node] end)
local by = {}
for _, row in ipairs(preflight.rows) do by[row.node] = row end

-- 1. a tree deploy on a tree node whose HEAD IS main is fine
ok(by['tree-fresh'].verdict == 'ok', 'tree mode on a node at origin/main is ok')
-- 2. the refusal that stopped v0.1.2 (c) is named before the deploy
ok(by['tree-behind'].verdict == 'refuse', 'tree mode on a node behind main is refused')
ok(tostring(by['tree-behind'].error) == 'canonical_busy', 'named canonical_busy (' .. tostring(by['tree-behind'].error) .. ')')
has(by['tree-behind'].detail, 'not origin/main', 'and it names the two commits')
has(by['tree-behind'].detail, 'deploy.sh:600', 'citing the refusal the deploy would make')
-- 3. a tree-less node asked for tree mode
ok(tostring(by['no-tree'].error) == 'no_runtime_tree', 'a tree-less node in tree mode is named no_runtime_tree')
has(by['no-tree'].detail, '--release', 'and the way out is on it')
-- 4. RELEASE MODE IS FINE ON A NODE WITH A TREE THAT IS NOT MAIN - that is the answer for the ring
ok(by['prebuilt-tree'].verdict == 'ok', 'release mode is ok on a tree node whose HEAD is not main')
has(by['prebuilt-tree'].detail, 'no tree moved', 'because it moves no tree')
-- 5. unchecked is never green
local blind = rehearse.mode_preflight({ { node = 'quiet', mode = 'tree' } }, function() return nil end)
ok(blind.rows[1].verdict == 'unchecked', 'a node that reports no facts is unchecked')
ok(#blind.red == 0, 'unchecked is not silently red either - it is printed and never called ok')
-- 6. an unknown mode is refused by name
local odd = rehearse.mode_preflight({ { node = 'x', mode = 'relase' } }, function() return {} end)
ok(tostring(odd.rows[1].error) == 'mode_unknown', 'a typo mode is mode_unknown')
-- 6b. THIS NODE IS NOT A DEPLOY TARGET (measured on the first LIVE run, 26/11: the rehearsal refused its own
--     ring labels - this node came out as mode local, peers as mode peer, and both are not modes a node accepts).
local own = rehearse.mode_preflight({ { node = 'this node', mode = 'local' } }, function() return nil end)
ok(own.rows[1].verdict == 'skipped', 'this node is skipped, not judged (' .. tostring(own.rows[1].verdict) .. ')')
has(own.rows[1].detail, 'never deployed', 'and says the ring never moves the node it runs on')
ok(#own.red == 0, 'so it adds nothing to the red list')
local peer = rehearse.mode_preflight({ { node = 'p', mode = 'tree' } }, function() return nil end)
ok(peer.rows[1].verdict == 'unchecked', 'a peer with no facts is unchecked, never judged from a label')
-- 7. the red list is the deploy step's early warning
local reds = table.concat(preflight.red, ' | ')
has(reds, 'tree-behind (canonical_busy)', 'the red names the node and the refusal')
has(reds, 'no-tree (no_runtime_tree)', 'both of them')
ok(not reds:find('prebuilt-tree', 1, true), 'and never a node release mode can install')
-- 8. and the rehearsal runs it, so a cut sees it before the deploy step
local report = rehearse.rehearse({
  ring = { { node = 'tree-behind', mode = 'tree' } },
  facts_of = function(node) return FACTS[node] end,
  read = function() return { ok = true, state = 'installed', installed_commit = 'aaaa1111' } end,
  canaries = function() return { features = { { feature = 'release-update', ok = true, stage = 'identity' } } } end,
  local_results = { results = { { feature = 'release-update', ok = true, stage = 'identity' } } },
})
ok(report.ok == false, 'the rehearsal is RED for a node the ring cannot deploy in that mode')
has(table.concat(report.red, ' | '), 'canonical_busy', 'with the refusal named')
has(table.concat(report.lines, '\n'), 'mode tree', 'and the report prints the mode line')

if failed > 0 then print(string.format('release mode preflight FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('release mode preflight ok (%d checks)', checks))
return 0
