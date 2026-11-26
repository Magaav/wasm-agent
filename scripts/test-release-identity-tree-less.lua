-- A TREE-LESS NODE NAMES ITS OWN IDENTITY (26/11, openclaw).
--
-- The release stopped because release-update read 'the tree (none) is not a git work tree this node can read'
-- on a node that had just installed the release - a FAIL for a node running exactly the bytes it was given.
-- A release install has no checkout; the identity it can prove is its binary build commit against the
-- install record the installer wrote (<config>/installed.txt), which is the target it was asked for.
local paths = dofile('lua/core/paths.lua')
local status = dofile('lua/core/build_status.lua')
local canary = dofile('lua/core/canaries/release-update.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function eq(got, want, label) ok(tostring(got) == tostring(want), label .. ' (got ' .. tostring(got) .. ')') end

local root = paths.config()
local function record(text)
  local ok_w = pcall(host.write_file, root .. '/installed.txt', text)
  ok(ok_w, 'the fixture install record is written')
end
local function clear() pcall(host.write_file, root .. '/installed.txt', '') end

local FULL = '6b6afc72f188a1a5724c16f1453cd5d956dd2e2'
local SHORT = '6b6afc72f188'

-- 1. the record reader
record(FULL .. '\n')
eq(status.recorded_commit(), FULL, 'a full id in the install record is read whole')
record(SHORT .. '\n')
eq(status.recorded_commit(), SHORT, 'a short form is read as it is written')
clear()
eq(status.recorded_commit(), nil, 'an empty record names no commit')

-- 2. the relation on a node with no tree
record(FULL)
local rel, why = status.relation({ root = nil }, { commit = FULL })
eq(rel, 'fresh', 'no tree, binary and record agree: fresh')
ok(tostring(why):find('has no tree', 1, true) ~= nil, 'and the reason says the node has no tree: ' .. tostring(why))
local rel_short, _ = status.relation({ root = nil }, { commit = SHORT })
eq(rel_short, 'fresh', 'the short form and the full id are the same commit')
record('a1857d15887cc8f7f3c07419f6af2639e852a8d5')
local rel_stale, why_stale = status.relation({ root = nil }, { commit = FULL })
eq(rel_stale, 'stale', 'a binary that is not what the record names is stale')
ok(tostring(why_stale):find('not running what it was installed with', 1, true) ~= nil, 'and says exactly that')
clear()
local rel_none, _ = status.relation({ root = nil }, { commit = FULL })
eq(rel_none, 'unknown', 'no tree AND no record is still unknown - never fresh')

-- 3. the canary on such a node is not a red
record(FULL)
local ran, stage, detail = canary.run({})
ok(ran ~= false or stage ~= 'identity_unknown', 'release-update does not answer identity_unknown where a record names the commit (got ' .. tostring(ran) .. '/' .. tostring(stage) .. ')')
clear()

if failed > 0 then print(string.format('release identity tree-less FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('release identity tree-less ok (%d checks)', checks))
return 0
