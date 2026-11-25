-- THE THIRD CANARY STATE (25/11): not_proven, beside pass/fail/off.
--
-- MEASURED (v0.1.2 cut, 25/11, on the laptop that cuts): mail, whatsapp-receive, whatsapp-index and
-- whatsapp-transcription answered FAIL index_empty / no_voice_notes - the index answers and holds nothing,
-- because no account of that kind is configured on that machine at all. A FAIL there says the feature is
-- broken, about a node that has no mailbox and no linked device. The honest answer is a third state.
--
-- WHAT THIS ROW HOLDS:
--   1. no account configured -> NOT PROVEN, by name, with the reason (and it is the component own file
--      that is read, not the index - lua/core/canaries/account.lua);
--   2. an account present with an empty index -> still FAIL (the gate steps aside; the canary keeps looking);
--   3. not_proven on every node asked -> RED, by name (proven nowhere), from feature_canary.aggregate;
--   4. release-update reports the reason status() actually returns (why), not a placeholder sentence, and
--      on the node that CUTS it is not_proven rather than red.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local canaries = dofile('lua/core/feature_canary.lua')
local account = dofile('lua/core/canaries/account.lua')

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

-- ---- 1. no account configured -> not_proven ---------------------------------------------------------
local root = paths.config()
local empty = root .. '/not-proven-fixture'
local present, why = account.present('wa-email', empty)
eq(present, false, 'no component file: the account gate refuses to call it present')
has(why, 'the service registry answered nothing about wa-email', 'and the reason names the registry answer it got')

local mail = dofile('lua/core/canaries/mail.lua')
local ran, stage, detail = mail.run({})
eq(ran, 'not_proven', 'the real mail canary answers not_proven where no account is configured')
eq(stage, 'no_account', 'and its stage says which fact is missing')
has(detail, 'this node runs no wa-email component', 'and the detail says what the registry answered')

-- ---- 2. the registry answer IS the signal (wa services status, field `state`) -----------------------
local running = account.present('wa-whatsapp', json.encode({ state = 'running', component = 'wa-whatsapp' }))
eq(running, true, 'the registry saying running means the account is served here')
local stopped, why_stopped = account.present('wa-whatsapp', json.encode({ state = 'stopped', name = 'wa-whatsapp' }))
eq(stopped, false, 'a component that is installed but stopped does not serve the account')
has(why_stopped, 'stopped', 'and the reason carries the registry own word')
local absent, why_absent = account.present('wa-email', json.encode({ name = 'wa-email' }))
eq(absent, false, 'no state at all: no such service in the registry')
has(why_absent, 'no such service in the registry', 'and it says that, not "not installed"')
local owned, why_owned = account.present('wa-whatsapp', json.encode({ state = 'stopped', owner = 'openclaw' }))
has(why_owned, 'the account is served by openclaw', 'and names the node the registry says serves it')

-- ---- 2b. RULING (c): account present, nothing of the kind the canary needs -> no_data, not a failure ----
local real_service = host.service
host.service = function() return json.encode({ state = 'running' }) end
local ran_t, stage_t, detail_t = dofile('lua/core/canaries/whatsapp-transcription.lua').run({})
eq(ran_t, 'not_proven', 'with the account served here, an empty voice index is not_proven')
eq(stage_t, 'no_data', 'and its stage is no_data')
eq(detail_t, 'no_data: no voice note in the index', 'with the words Fable ruled')
local ran_m, stage_m, detail_m = dofile('lua/core/canaries/mail.lua').run({})
eq(ran_m, 'not_proven', 'the same for mail with an empty index')
eq(stage_m, 'no_data', 'stage no_data')
has(detail_m, 'no_data: no message in the index', 'and the message says which kind is missing')
host.service = real_service

-- ---- 3. proven nowhere is RED only for no_account / cutting ------------------------------------------
local nowhere = canaries.aggregate({
  { node = 'this node', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_account' } } },
  { node = 'peer-b', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_account' } } },
})
eq(#nowhere.proven_nowhere, 1, 'no_account on every node asked is proven nowhere')
has(nowhere.proven_nowhere[1], 'mail (not proven on 2 node(s) asked)', 'named, with how many nodes were asked')
eq(#nowhere.failed, 0, 'and it is not a failure of any node')
local cuts = canaries.aggregate({ { node = 'this node', results = { { feature = 'release-update', ok = false, not_proven = true, stage = 'cutting' } } } })
eq(#cuts.proven_nowhere, 1, 'cutting on the only node asked is proven nowhere too')
local nodata = canaries.aggregate({
  { node = 'openclaw', results = { { feature = 'whatsapp-transcription', ok = false, not_proven = true, stage = 'no_data' } } },
})
eq(#nodata.proven_nowhere, 0, 'no_data on the account node does NOT block')
eq(#nodata.not_proven_no_data, 1, 'it is listed instead')
has(nodata.not_proven_no_data[1], 'whatsapp-transcription (no_data)', 'by name and reason')
local mixed = canaries.aggregate({
  { node = 'this node', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_account' } } },
  { node = 'openclaw', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_data' } } },
})
eq(#mixed.proven_nowhere, 0, 'no_account somewhere + no_data elsewhere is not proven nowhere')
eq(#mixed.not_proven_no_data, 1, 'and the no_data node is listed')
local proven_somewhere = canaries.aggregate({
  { node = 'this node', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_account' } } },
  { node = 'peer-b', results = { { feature = 'mail', ok = true, stage = 'index' } } },
})
eq(#proven_somewhere.proven_nowhere, 0, 'proven on ONE node clears proven nowhere')
eq(#proven_somewhere.failed, 0, 'and a pass is not a failure either')

-- ---- 4. the line and the count ----------------------------------------------------------------------
local lines = canaries.lines({
  { feature = 'chat', ok = true, mode = 'child-node', stage = 'answered' },
  { feature = 'mail', ok = false, not_proven = true, stage = 'no_account', detail = 'no mailbox here' },
  { feature = 'graph', ok = false, off = true, stage = 'off (switched off)' },
})
has(table.concat(lines, '\n'), 'mail                   NOT PROVEN  no_account: no mailbox here', 'the state prints by name with its reason')
has(lines[1], '1 passed, 0 failed, 1 off, 1 not proven, 0 off-node', 'and is counted on its own')

-- ---- 5. release-update: the real reason, and the cutting node ----------------------------------------
local status = dofile('lua/core/build_status.lua').status()
local release_update = dofile('lua/core/canaries/release-update.lua')
local up_ok, up_stage, up_detail = release_update.run({})
if status.relation == 'unknown' then
  eq(up_stage, 'identity_unknown', 'release-update still fails on an unknown identity')
  ok(status.why ~= nil and up_detail == status.why,
    'and it prints the reason status() returns (why), not a placeholder: ' .. tostring(up_detail))
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
