-- THE THIRD CANARY STATE (25/11, Fable's final shape): not_proven, decided by the canary's OWN answer.
--
-- No detector, no account gate, no env seam: the canary asks its index and reads what came back.
--   * "the index answers and holds nothing" (index_empty / no_voice_notes) -> not_proven, stage no_data;
--   * anything else that fails (the index does not answer, an error, a wrong result) -> FAIL, unchanged;
--   * a canary not_proven on EVERY node asked is RED, by name - "proven nowhere" - with no stage exceptions.
--
-- WHAT THIS ROW HOLDS, with the real canary modules and only the host function stubbed:
--   1. an empty index answers not_proven / no_data (mail and whatsapp-transcription);
--   2. an index that errors stays a FAIL;
--   3. not_proven on every node asked is proven nowhere, whatever the stage;
--   4. proven on one node clears it, and a pass is never a failure;
--   5. release-update prints the reason status() returns, and on the node that cuts it is not_proven / cutting.
local json = dofile('lua/vendor/json.lua')
local canaries = dofile('lua/core/feature_canary.lua')

local checks, failed = 0, 0
local function ok(value, label)
  checks = checks + 1
  if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end
end
local function eq(actual, expected, label)
  ok(tostring(actual) == tostring(expected), label .. ' (got ' .. tostring(actual) .. ')')
end
local function has(text, needle, label)
  ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 90) .. ')')
end

-- ---- 1. the index answers and holds nothing -> not_proven / no_data ---------------------------------
local real_email = host.email_search
host.email_search = function() return json.encode({ messages = {} }) end
local ran_m, stage_m, detail_m = dofile('lua/core/canaries/mail.lua').run({})
eq(ran_m, 'not_proven', 'an empty mailbox index is not_proven, not a failure')
eq(stage_m, 'no_data', 'and its stage is no_data')
eq(detail_m, 'no_data: no message in the index', 'with the words Fable ruled')
host.email_search = real_email

local real_search = host.whatsapp_search
host.whatsapp_search = function() return json.encode({ hits = {} }) end
local ran_t, stage_t, detail_t = dofile('lua/core/canaries/whatsapp-transcription.lua').run({})
eq(ran_t, 'not_proven', 'an empty voice-note answer is not_proven')
eq(stage_t, 'no_data', 'stage no_data')
eq(detail_t, 'no_data: no voice note in the index', 'and it says which kind of item is missing')
host.whatsapp_search = real_search

-- ---- 2. an index that errors stays a FAIL ------------------------------------------------------------
host.email_search = function() error('the index is not there') end
local ran_e, stage_e = dofile('lua/core/canaries/mail.lua').run({})
eq(ran_e, false, 'an index that raises is a FAIL, never not_proven')
eq(stage_e, 'index_unreadable', 'and the stage names the reading that failed')
host.email_search = function() return json.encode('not a table') end
local ran_w, stage_w = dofile('lua/core/canaries/mail.lua').run({})
eq(ran_w, false, 'a wrong result is a FAIL too')
eq(stage_w, 'index_unreadable', 'with the same named stage')
host.email_search = real_email

-- ---- 3. proven nowhere -> red, whatever the stage -----------------------------------------------------
local nodata_all = canaries.aggregate({
  { node = 'this node', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_data' } } },
  { node = 'peer-b', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_data' } } },
})
eq(#nodata_all.proven_nowhere, 1, 'no_data on every node asked is proven nowhere (no stage exceptions)')
has(nodata_all.proven_nowhere[1], 'mail (no_data; not proven on 2 node(s) asked)', 'named, with its reason and how many nodes were asked')
eq(#nodata_all.failed, 0, 'and it is not a failure of any node')
local cuts = canaries.aggregate({ { node = 'this node', results = { { feature = 'release-update', ok = false, not_proven = true, stage = 'cutting' } } } })
eq(#cuts.proven_nowhere, 1, 'cutting on the only node asked is proven nowhere too')
local proven_somewhere = canaries.aggregate({
  { node = 'this node', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_data' } } },
  { node = 'openclaw', results = { { feature = 'mail', ok = true, stage = 'index' } } },
})
eq(#proven_somewhere.proven_nowhere, 0, 'proven on ONE node clears proven nowhere')
eq(#proven_somewhere.failed, 0, 'and a pass is not a failure either')
local failing = canaries.aggregate({ { node = 'openclaw', results = { { feature = 'mail', ok = false, stage = 'index_unreadable' } } } })
eq(#failing.failed, 1, 'a real failure is still a failure')
has(failing.failed[1], 'openclaw mail (index_unreadable)', 'named with its node and stage')

-- ---- 4. the line and the count -----------------------------------------------------------------------
local lines = canaries.lines({
  { feature = 'chat', ok = true, mode = 'child-node', stage = 'answered' },
  { feature = 'mail', ok = false, not_proven = true, stage = 'no_data', detail = 'no_data: no message in the index' },
  { feature = 'graph', ok = false, off = true, stage = 'off (switched off)' },
})
has(table.concat(lines, '\n'), 'mail                   NOT PROVEN  no_data: no_data: no message in the index', 'the state prints by name with its reason')
has(lines[1], '1 passed, 0 failed, 1 off, 1 not proven, 0 off-node', 'and is counted on its own')

-- ---- 5. release-update: the real reason, and the cutting node ---------------------------------------
local status = dofile('lua/core/build_status.lua').status()
local release_update = dofile('lua/core/canaries/release-update.lua')
local up_ok, up_stage, up_detail = release_update.run({})
if status.relation == 'unknown' then
  eq(up_stage, 'identity_unknown', 'release-update still fails on an unknown identity')
  ok(status.why ~= nil and up_detail == status.why, 'and it prints the reason status() returns (why): ' .. tostring(up_detail))
  ok(up_detail ~= 'the identity relation is unknown', 'so the placeholder sentence is gone')
else
  print('  ok   (this node is ' .. tostring(status.relation) .. ': the unknown-identity arm is not reachable here)')
  checks = checks + 1
end
local cutting_ok, cutting_stage, cutting_detail = release_update.run({ cutting = true })
eq(cutting_ok, 'not_proven', 'on the node that CUTS, release-update is not_proven, not red')
eq(cutting_stage, 'cutting', 'and says why')
has(cutting_detail, 'this node cuts; it does not run the new build yet', 'in words an operator can act on')

if failed > 0 then print(string.format('canary not proven FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('canary not proven ok (%d checks)', checks))
return 0
