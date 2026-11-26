-- NOT PROVEN ON ANY NODE IS LISTED, NOT RED (26/11, Fable r5).
--
-- It replaces the rule of 25/11. A canary answered `not_proven` on every node asked: the canary runs in a CLI
-- process on a serving node and cannot see what that node serves, so that is a fact about the probe, not a
-- break in the release. The step names each feature and its reason under "NOT PROVEN ON ANY NODE" and passes.
-- Still red: a FAIL (a node said it is broken, a refusal included - r4 item 3), and a cutting (release-update)
-- proven nowhere - a release that cannot prove its own cut did not cut.
local canaries = dofile('lua/core/feature_canary.lua')
local land = dofile('lua/core/land.lua')
local checks, failed_count = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed_count = failed_count + 1; print('  FAIL ' .. label) end end
local function eq(got, want, label) ok(tostring(got) == tostring(want), label .. ' (got ' .. tostring(got) .. ')') end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 110) .. ')') end

ok(type(land.release_not_proven) == 'function', 'land.release_not_proven is a named rule')

-- 1. the aggregate still names the feature AND the reason it gave
local nodata = canaries.aggregate({
  { node = 'this node', results = { { feature = 'mail', not_proven = true, stage = 'no_data' } } },
  { node = 'openclaw', results = { { feature = 'mail', not_proven = true, stage = 'no_data' } } },
})
eq(#nodata.proven_nowhere, 1, 'one feature is proven nowhere')
has(nodata.proven_nowhere[1], 'mail', 'named')
has(nodata.proven_nowhere[1], 'no_data', 'with the reason it gave')
has(nodata.proven_nowhere[1], '2 node(s)', 'and how many nodes were asked')

-- 2. a not_proven everywhere is LISTED and the step passes
local verdict = land.release_not_proven(nodata)
eq(#verdict.listed, 1, 'it is listed')
eq(#verdict.red, 0, 'and nothing is red')
eq(#verdict.cutting, 0, 'the cutting check has nothing to say')
has(verdict.listed[1], 'mail', 'the listed entry is the feature, by name')

-- 3. a FAIL stays red, refusal included, and it is never absorbed as not-proven
local failing = canaries.aggregate({
  { node = 'openclaw', results = { { feature = 'whatsapp-receive', ok = false, stage = 'whatsapp_component_absent' } } },
})
eq(#failing.failed, 1, 'a refusal is a FAIL')
has(failing.failed[1], 'whatsapp_component_absent', 'named with the code the door answered')
eq(#failing.proven_nowhere, 0, 'and it is not a not-proven entry')
eq(#land.release_not_proven(failing).listed, 0, 'the not-proven rule does not absorb it')
local broken = canaries.aggregate({ { node = 'this node', results = { { feature = 'mail', ok = false, stage = 'index_unreadable' } } } })
eq(#broken.failed, 1, 'a plain FAIL is a FAIL')

-- 4. a cutting proven nowhere stays red
local cutting = canaries.aggregate({ { node = 'openclaw', results = { { feature = 'release-update', not_proven = true, stage = 'no_data' } } } })
local cut_verdict = land.release_not_proven(cutting)
eq(#cut_verdict.red, 1, 'release-update proven nowhere is red')
eq(#cut_verdict.listed, 0, 'and it is not merely listed')
has(cut_verdict.cutting[1], 'release-update', 'named as the cutting canary')

-- 5. a mixed round: mail listed, release-update fresh somewhere, a peer FAIL red
local mixed = canaries.aggregate({
  { node = 'this node', results = {
    { feature = 'mail', not_proven = true, stage = 'no_data' },
    { feature = 'release-update', ok = true, stage = 'identity' },
    { feature = 'whatsapp-index', ok = false, stage = 'whatsapp_component_absent' },
    { feature = 'whatsapp-receive', off = true, stage = 'off_node' },
  } },
})
local mixed_verdict = land.release_not_proven(mixed)
eq(#mixed_verdict.listed, 1, 'one feature is listed')
has(mixed_verdict.listed[1], 'mail', 'mail')
eq(#mixed_verdict.red, 0, 'the not-proven rule finds nothing red')
eq(#mixed.failed, 1, 'while the FAIL is still counted for the step')
eq(#mixed.off, 1, 'and the off-node entry is still an off, not a listing')

-- 6. the step prints the heading and its reason, and the release report carries it
local src = host.read_file('lua/core/land.lua') or ''
has(src, 'NOT PROVEN ON ANY NODE', 'the step output has the heading')
has(src, 'cannot see what that node serves', 'with the reason in the output')
has(src, 'canary_cutting_nowhere', 'a cutting proven nowhere is its own named red')
has(src, '| NOT PROVEN ON ANY NODE: ', 'and the step result carries the list for the release report')
local i_failed = src:find('if #failed > 0 then', 1, true)
local i_unproven = src:find('if #unproven > 0 then', 1, true)
local i_cutting = src:find('if #not_proven.red > 0 then', 1, true)
local i_listed = src:find('if #not_proven.listed > 0 then', 1, true)
ok(i_failed and i_unproven and i_cutting and i_listed, 'all four branches are present')
ok(i_failed < i_cutting and i_unproven < i_cutting and i_cutting < i_listed, 'a FAIL and an unproven node return BEFORE the listed pass')
local gone = src:find('canary_proven_nowhere', 1, true)
ok(gone == nil, 'the 25/11 red (canary_proven_nowhere) is gone')

if failed_count > 0 then print(string.format('release not-proven FAILED (%d checks, %d failed)', checks, failed_count)) return 1 end
print(string.format('release not-proven ok (%d checks)', checks))
return 0
