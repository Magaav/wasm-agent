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
has(why, empty .. '/components/wa-email.json', 'and the reason names the file it looked for')

local mail = dofile('lua/core/canaries/mail.lua')
local ran, stage, detail = mail.run({})
eq(ran, 'not_proven', 'the real mail canary answers not_proven where no account is configured')
eq(stage, 'no_account', 'and its stage says which fact is missing')
has(detail, 'no account of this kind is configured on this node', 'and the detail says so in words')

-- ---- 2. account present, empty index -> still FAIL ---------------------------------------------------
local with_account = root .. '/account-present-fixture'
local dir = with_account .. '/components'
os.execute('mkdir -p ' .. dir)
local f = assert(io.open(dir .. '/wa-email.json', 'w'))
f:write(json.encode({ name = 'wa-email', kind = 'component', target = 'wasm32', description = 'fixture',
  capabilities = { config = true }, limits = { memory_mb = 64 }, imap = { host = 'fixture.invalid' } }))
f:close()
eq(account.present('wa-email', with_account), true, 'a definition that carries an account block IS present')
local bare = root .. '/manifest-only-fixture'
os.execute('mkdir -p ' .. bare .. '/components')
local g = assert(io.open(bare .. '/components/wa-email.json', 'w'))
g:write(json.encode({ name = 'wa-email', kind = 'component', target = 'wasm32', description = 'fixture',
  capabilities = { config = true }, limits = { memory_mb = 64 } }))
g:close()
eq(account.present('wa-email', bare), false, 'a definition holding only the manifest skeleton is NOT an account')
local real_present = account.present('wa-email')
if real_present then
  local mail2 = dofile('lua/core/canaries/mail.lua')
  local ran2, stage2 = mail2.run({})
  ok(ran2 ~= 'not_proven', 'with a real account on this node the mail canary is not not_proven (it looks at the index)')
  ok(stage2 ~= 'no_account', 'and its stage is about the index, not about the account')
else
  print('  ok   (this node has no mail account: the account-present arm is covered by the fixture above)')
  checks = checks + 1
end

-- ---- 3. proven nowhere -> red -------------------------------------------------------------------------
local nowhere = canaries.aggregate({
  { node = 'this node', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_account' } } },
  { node = 'peer-b', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_account' } } },
})
eq(#nowhere.proven_nowhere, 1, 'a canary not_proven on every node asked is named once')
has(nowhere.proven_nowhere[1], 'mail (not proven on 2 node(s) asked)', 'and the name says how many nodes were asked')
eq(#nowhere.failed, 0, 'and it is not counted as a failure of any node')
local proven_somewhere = canaries.aggregate({
  { node = 'this node', results = { { feature = 'mail', ok = false, not_proven = true, stage = 'no_account' } } },
  { node = 'peer-b', results = { { feature = 'mail', ok = true, stage = 'index' } } },
})
eq(#proven_somewhere.proven_nowhere, 0, 'proven on ONE node clears proven nowhere')
eq(#proven_somewhere.failed, 0, 'and a not_proven on this node is not a failure either')

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
