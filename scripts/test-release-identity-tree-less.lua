-- A TREE-LESS NODE NAMES ITS OWN IDENTITY (26/11, openclaw).
--
-- The release stopped because release-update read 'the tree (none) is not a git work tree this node can read'
-- on a node that had just installed the release - a FAIL for a node running exactly the bytes it was given.
-- A release install has no checkout; the identity it can prove is its binary own build commit against the
-- install record scripts/lib/install-record.sh writes (<config>/installed.txt). Its identity line is the NAMED
-- key commit=<id>: the short form a build reports in --build-info, the full id for a prebuilt install.
-- tree=, sha256= and installed_commit= also carry hex, so the key is what is read, never the first run of hex.
local paths = dofile('lua/core/paths.lua')
local status = dofile('lua/core/build_status.lua')
local canary = dofile('lua/core/canaries/release-update.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function eq(got, want, label) ok(tostring(got) == tostring(want), label .. ' (got ' .. tostring(got) .. ')') end

local root = paths.config()
local function record(text) ok(pcall(host.write_file, root .. '/installed.txt', text), 'the fixture record is written') end
local function clear() pcall(host.write_file, root .. '/installed.txt', '') end

local FULL = '6b6afc72f188a1a5724c16f1453cd5d956dd2e2'
local SHORT = '6b6afc72'

-- 1. the record reader, on every shape the writer produces
record('commit=' .. SHORT .. '\nbranch=main\ndirty=no\ntree=' .. FULL .. '\nbuild_info=yes\n')
eq(status.recorded_commit(), SHORT, 'a build record (commit=8 hex, the laptop shape) reads its commit, not tree=')
record('commit=' .. FULL .. '\nbranch=main\nsha256=4248d61b\n')
eq(status.recorded_commit(), FULL, 'a prebuilt record (commit=full id) reads the full id')
record('sha256=9f2c4d1e8a7b6c5d\ntree=4248d61b\ndropped_caller_field=commit\ncommit=' .. SHORT .. '\n')
eq(status.recorded_commit(), SHORT, 'other hex BEFORE commit= is not taken for the program (sha256=, tree=)')
record('installed_commit=deadbeefdeadbeefcafe\ncommit=' .. SHORT .. '\n')
eq(status.recorded_commit(), SHORT, 'installed_commit= is another key and is not read as the build commit')
record('sha256=9f2c4d1e8a7b6c5d\n')
eq(status.recorded_commit(), nil, 'a record with no commit= names no commit')
clear()
eq(status.recorded_commit(), nil, 'an empty record names no commit')

-- 2. the relation on a node with no tree: the record is the target, the prefix compare stays
record('commit=' .. SHORT .. '\n')
local rel, why = status.relation({ root = nil }, { commit = FULL })
eq(rel, 'fresh', 'no tree, 8-hex record against a full build commit: fresh (prefix)')
ok(tostring(why):find('has no tree', 1, true) ~= nil, 'and the reason says the node has no tree')
local rel_rev = status.relation({ root = nil }, { commit = SHORT })
eq(rel_rev, 'fresh', 'a short build commit against a short record is fresh too')
record('commit=' .. FULL .. '\n')
eq(select(1, status.relation({ root = nil }, { commit = SHORT })), 'fresh', 'and the full record against a short commit')
record('commit=a1857d15887cc8f7f3c07419f6af2639e852a8d5\n')
local rel_stale, why_stale = status.relation({ root = nil }, { commit = FULL })
eq(rel_stale, 'stale', 'a binary that is not what the record names is stale')
ok(tostring(why_stale):find('not running what it was installed with', 1, true) ~= nil, 'and says exactly that')
clear()
eq(select(1, status.relation({ root = nil }, { commit = FULL })), 'unknown', 'no tree AND no record is still unknown - never fresh')

-- 3. the canary on such a node is not a red
record('commit=' .. SHORT .. '\n')
local ran, stage = canary.run({})
ok(stage ~= 'identity_unknown', 'release-update does not answer identity_unknown where a record names the commit (got ' .. tostring(ran) .. '/' .. tostring(stage) .. ')')
clear()

if failed > 0 then print(string.format('release identity tree-less FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('release identity tree-less ok (%d checks)', checks))
return 0
