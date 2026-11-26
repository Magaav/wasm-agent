-- A REFUSAL IS NOT AN EMPTY INDEX (26/11, openclaw diagnosis).
--
-- The node runs no wa-whatsapp component, so every WhatsApp tool answers `whatsapp_component_absent` (with the
-- state and the owner) BEFORE the index is touched. The two canaries read that reply as an empty index and
-- reported not_proven no_data - a stopped component reading as an account with nothing in it. A refusal is a
-- FAIL, named with the code the door answered, and the state and owner it named with it.
local json = dofile('lua/vendor/json.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function eq(got, want, label) ok(tostring(got) == tostring(want), label .. ' (got ' .. tostring(got) .. ')') end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 100) .. ')') end

local REFUSAL = json.encode({ error = 'whatsapp_component_absent', state = 'not_running', owner = 'openclaw' })
local quiet = { whatsapp_contacts = host.whatsapp_contacts, whatsapp_read = host.whatsapp_read,
  whatsapp_search = host.whatsapp_search, email_search = host.email_search }

-- 1. the two WhatsApp readers
host.whatsapp_contacts = function() return REFUSAL end
local ran_r, stage_r, detail_r = dofile('lua/core/canaries/whatsapp-receive.lua').run({})
eq(ran_r, false, 'receive: a refusal is a FAIL, not not_proven')
eq(stage_r, 'whatsapp_component_absent', 'receive: the stage is the code the door answered')
has(detail_r, 'REFUSED, not answered', 'receive: the detail says it was refused')
has(detail_r, 'not_running', 'receive: and carries the state')
has(detail_r, 'openclaw', 'receive: and the owner that serves it')
local ran_i, stage_i, detail_i = dofile('lua/core/canaries/whatsapp-index.lua').run({})
eq(ran_i, false, 'index: a refusal is a FAIL')
eq(stage_i, 'whatsapp_component_absent', 'index: named with the door code')
has(detail_i, 'not_running', 'index: with the state')

-- 2. the voice search and the mailbox take the same guard
host.whatsapp_search = function() return REFUSAL end
local ran_t, stage_t = dofile('lua/core/canaries/whatsapp-transcription.lua').run({})
eq(ran_t, false, 'transcription: a refusal is a FAIL')
eq(stage_t, 'whatsapp_component_absent', 'transcription: named')
host.email_search = function() return json.encode({ error = 'email_account_absent', state = 'stopped' }) end
local ran_m, stage_m, detail_m = dofile('lua/core/canaries/mail.lua').run({})
eq(ran_m, false, 'mail: a refusal is a FAIL')
eq(stage_m, 'email_account_absent', 'mail: named with its own code')
has(detail_m, 'stopped', 'mail: with the state the door gave')

-- 3. and an ANSWER that happens to be empty is still the ruling (c) not_proven, not a failure
host.whatsapp_contacts = function() return json.encode({ chats = {} }) end
local ran_empty, stage_empty = dofile('lua/core/canaries/whatsapp-receive.lua').run({})
eq(ran_empty, 'not_proven', 'an empty answer stays not_proven')
eq(stage_empty, 'no_data', 'with stage no_data')
host.email_search = function() return json.encode({ messages = {} }) end
local ran_mail_empty, stage_mail_empty = dofile('lua/core/canaries/mail.lua').run({})
eq(ran_mail_empty, 'not_proven', 'and the same for mail')
eq(stage_mail_empty, 'no_data', 'stage no_data')

host.whatsapp_contacts, host.whatsapp_read = quiet.whatsapp_contacts, quiet.whatsapp_read
host.whatsapp_search, host.email_search = quiet.whatsapp_search, quiet.email_search

if failed > 0 then print(string.format('canary refusals FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('canary refusals ok (%d checks)', checks))
return 0
