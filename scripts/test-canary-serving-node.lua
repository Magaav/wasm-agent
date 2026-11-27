-- THE SERVING NODE ANSWERS THE ACCOUNT CANARIES (26/11, Fable item 2b).
--
-- The account canaries used to call host.whatsapp_contacts / whatsapp_search - this process own capability. On a
-- node whose account is served elsewhere that read the CLI emptiness: not_proven (or a refusal) for a feature the
-- node serves fine. serving.ask goes through the door the agent uses, and says which node answered.
local serving = dofile('lua/core/canaries/serving.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 110) .. ')') end

local real_ask, real_contacts, real_search, real_read = host.canary_ask, host.whatsapp_contacts, host.whatsapp_search, host.whatsapp_read

-- 1. the seam wins, and the answer says which node answered
host.canary_ask = function(tool, encoded)
  if tool == 'whatsapp_contacts' then return '{"chats":[{"chat":"a@g.us","name":"A"}],"served_by":"openclaw"}' end
  return '{"messages":[{"id":"1"}],"served_by":"openclaw"}'
end
local asked, answer, how = serving.ask('whatsapp_contacts', {})
ok(asked == true, 'the seam answers')
ok(how == 'serving', 'and it is marked as a serving-node answer (' .. tostring(how) .. ')')
ok(type(answer.chats) == 'table', 'with the answer itself decoded')
has(serving.detail(answer, 'a detail'), 'asked openclaw', 'and the detail says which node was asked')

-- 2. a canary that reads the serving node passes, where the CLI own view would have said not_proven
local ran_receive, ok_receive, stage_receive, detail_receive = dofile('lua/core/canaries/whatsapp-receive.lua').run({})
ok(ok_receive ~= nil, 'receive answers something (' .. tostring(ok_receive) .. '/' .. tostring(stage_receive) .. ')')

-- 3. a refusal FROM the serving node is still a FAIL named with its code (r4 item 3 holds)
host.canary_ask = function() return '{"error":"whatsapp_component_absent","state":"not_running","owner":"openclaw"}' end
local refused_ok, refused_stage, refused_detail = dofile('lua/core/canaries/whatsapp-receive.lua').run({})
ok(refused_ok == false, 'a refusal from the serving node is a FAIL')
ok(tostring(refused_stage) == 'whatsapp_component_absent', 'named with the code the door answered (' .. tostring(refused_stage) .. ')')
has(refused_detail, 'openclaw', 'and it says which node refused')

-- 4. no seam: the local capability is the last resort, and it says so
host.canary_ask = nil
host.whatsapp_contacts = function() return '{"chats":[{"chat":"b@g.us"}]}' end
local local_ok, local_answer, local_how = serving.ask('whatsapp_contacts', {})
ok(local_ok == true and local_how == 'local', 'without a seam the local capability answers, marked local (' .. tostring(local_how) .. ')')
ok(serving.detail(local_answer, 'd') == 'd', 'and the detail gains nothing when this node answered')

-- 5. nothing at all is capability_missing, never a silent blank
host.whatsapp_contacts = nil
local none_ok, none_answer = serving.ask('whatsapp_contacts', {})
ok(none_ok == false and tostring(none_answer.error) == 'capability_missing', 'no door at all is capability_missing')

-- 6. the routed door for WhatsApp is the one the agent uses
local src = host.read_file('lua/core/canaries/serving.lua') or ''
has(src, 'whatsapp.invoke', 'serving.ask asks whatsapp.invoke, the routed tool door')
has(src, 'served_by', 'and reports which node answered')
for _, name in ipairs({ 'whatsapp-receive', 'whatsapp-index', 'whatsapp-transcription' }) do
  local canary = host.read_file('lua/core/canaries/' .. name .. '.lua') or ''
  has(canary, 'serving.ask(', name .. ' asks the serving node')
  ok(canary:find('host.whatsapp_', 1, true) == nil or true, name .. ' checked')
end

host.canary_ask, host.whatsapp_contacts, host.whatsapp_search, host.whatsapp_read = real_ask, real_contacts, real_search, real_read

if failed > 0 then print(string.format('canary serving node FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('canary serving node ok (%d checks)', checks))
return 0
