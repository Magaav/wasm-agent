-- THE FIVE GATE DEFECTS THE CUT MET IN ITS OWN RELEASE (Fable 26/11, P0): each is a check here so the rehearsal
-- can carry it and the canaries stop lying about a healthy node.
local json = dofile('lua/vendor/json.lua')
local build = dofile('lua/core/build_status.lua')
local canaries = dofile('lua/core/feature_canary.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function eq(got, want, label) ok(tostring(got) == tostring(want), label .. ' (got ' .. tostring(got) .. ')') end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 110) .. ')') end

-- (d) THE RECORD BESIDE THE BINARY IS READ (measured: this laptop's record is ~/.local/bin/installed.txt)
local home = tostring(host.getenv and host.getenv('HOME') or '')
ok(home ~= '', 'the row has a HOME to work in')
local dir = home .. '/.local/bin'
ok(pcall(host.exec, 'mkdir -p ' .. dir, ''), 'the install dir exists')
ok(pcall(host.write_file, dir .. '/installed.txt', 'commit=6b6afc72\nbranch=main\ntree=deadbeef\n'), 'a release record is written')
eq(build.recorded_commit(), '6b6afc72', 'recorded_commit reads the record beside the binary, not only <config>')
-- and the <config> record still wins when it is the one that exists
local paths = dofile('lua/core/paths.lua')
ok(pcall(host.write_file, paths.config() .. '/installed.txt', 'commit=a1857d15\n'), 'a config record is written')
eq(build.recorded_commit(), 'a1857d15', 'the config record is still preferred')
pcall(host.write_file, paths.config() .. '/installed.txt', '')
pcall(host.write_file, dir .. '/installed.txt', '')

-- (e) THE CALLER'S cutting REACHES THE CANARY
local cutting = canaries.run('release-update', { cutting = true })
eq(cutting.stage, 'cutting', 'with cutting = true the canary answers cutting (a node that cuts does not run the new build)')
eq(cutting.not_proven, true, 'and it is not_proven, not a failure')
local not_cutting = canaries.run('release-update', { cutting = false })
ok(tostring(not_cutting.stage) ~= 'cutting', 'without it the canary judges the node (' .. tostring(not_cutting.stage) .. ')')

-- (c) A QUEUED ANSWER IS NOT A BREAK
local real_contacts = host.whatsapp_contacts
host.whatsapp_contacts = function() return json.encode({ error = 'whatsapp_contacts_slow', state = 'queued' }) end
local ran, stage, detail = dofile('lua/core/canaries/whatsapp-receive.lua').run({})
eq(ran, 'not_proven', 'a queued answer is not_proven')
eq(stage, 'queued', 'named queued')
has(detail, 'still queued', 'and the detail says the account question is still queued')
host.whatsapp_contacts = function() return json.encode({ error = 'whatsapp_component_absent', state = 'not_running' }) end
local ran2, stage2 = dofile('lua/core/canaries/whatsapp-receive.lua').run({})
eq(ran2, false, 'any other refusal is still a FAIL')
eq(stage2, 'whatsapp_component_absent', 'named with its own code')
host.whatsapp_contacts = real_contacts

-- (b) THE MAIL CANARY ASKS A REAL QUESTION
local real_search = host.email_search
local sent = nil
host.email_search = function(encoded) sent = encoded; return json.encode({ messages = {} }) end
dofile('lua/core/canaries/mail.lua').run({})
ok(type(sent) == 'string', 'the canary asked the connector')
has(sent, 'INBOX', 'with a real mailbox, not an empty query')
ok(tostring(sent):find('"q"', 1, true) ~= nil or tostring(sent):find('mailbox', 1, true) ~= nil, 'and a question the connector accepts')
host.email_search = real_search

-- (a) THE EARLIER-ROUND NODE IS ASKED: deployed_nodes is what the canary step reads
local land = host.read_file('lua/core/land.lua') or ''
local i_settled = land:find('if settled_nodes[name] then', 1, true)
ok(i_settled ~= nil, 'the already-installed branch exists')
local branch = i_settled and land:sub(i_settled, i_settled + 900) or ''
has(branch, 'deployed_nodes[#deployed_nodes + 1]', 'and it adds the node to deployed_nodes, so the canaries ask it')

if failed > 0 then print(string.format('release gate fixes FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('release gate fixes ok (%d checks)', checks))
return 0
