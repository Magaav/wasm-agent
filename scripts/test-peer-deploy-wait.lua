-- WHAT A CALLING NODE DOES WITH A PEER'S `deploy_waiting` ANSWER (23/11, Fable's review 1c).
--
-- MEASURED in this tree before the change: `nodes.remote_chat` turned every non-200 into `remote_unreachable`
-- with the status as `detail` and threw the body away - so a peer that was alive, installing a build and had run
-- nothing, was reported to the caller's model as a lost peer, and the one number that makes a retry sane
-- (`retry_after_seconds`) was gone. This row pins the mapping: a door refusal is a named, retryable answer that
-- says the peer started nothing and when to ask again; everything else keeps its old answer.
--
--   WA_SCRIPT=scripts/test-peer-deploy-wait.lua wa --db <scratch>/t.db
local json = dofile('lua/vendor/json.lua')
local ok_load, nodes = pcall(dofile, 'lua/core/nodes.lua')
if not ok_load or type(nodes) ~= 'table' or type(nodes.chat_answer) ~= 'function' then
  print('REFUSED test-peer-deploy-wait: lua/core/nodes.lua does not answer chat_answer')
  os.exit(2)
end

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end

local door = json.encode({ error = 'deploy_waiting', not_started = true, retry_after_seconds = 30,
  hint = 'deploy_waiting: this node is waiting for or installing a new build. ...' })

local answer = nodes.chat_answer({ status = 503, body = door }, 'peer-b')
ok(answer.error == 'remote_deploy_waiting', 'a door refusal is named as a deploy wait, not as unreachable: ' .. tostring(answer.error))
ok(answer.not_started == true, 'it says the peer started nothing')
ok(answer.retryable == true, 'it is retryable')
ok(answer.retry_after_seconds == 30, 'and it carries the peer number to retry after: ' .. tostring(answer.retry_after_seconds))
ok(tostring(answer.message or ''):find('peer-b', 1, true) ~= nil, 'the message names the peer')
ok(tostring(answer.message or ''):find('30', 1, true) ~= nil, 'and the number in the words a model reads')
ok(tostring(answer.message or ''):lower():find('nothing was lost', 1, true) ~= nil, 'and says nothing was lost')

-- An older peer that refuses without a number: still retryable, no invented number.
local old = nodes.chat_answer({ status = 503, body = json.encode({ error = 'deploy_waiting', not_started = true }) }, 'peer-c')
ok(old.error == 'remote_deploy_waiting' and old.retryable == true, 'a door refusal without a number is still retryable')
ok(old.retry_after_seconds == nil, 'and no number is invented: ' .. tostring(old.retry_after_seconds))

-- Everything else keeps its old answer, so this change cannot turn a real failure into a promise to retry.
ok(nodes.chat_answer({ status = 500, body = 'oops' }, 'peer-d').error == 'remote_unreachable', 'a 500 is still unreachable')
ok(nodes.chat_answer({ status = 503, body = json.encode({ error = 'node_thread_stalled' }) }, 'peer-d').error == 'remote_unreachable',
  'a 503 that is not the door is still unreachable')
ok(nodes.chat_answer({ status = 200, body = door }, 'peer-d').error == 'remote_unreachable',
  'a 200 is answered by the caller before this function (no chat body is read as an error)')
ok(nodes.chat_answer(nil, 'peer-d').error == 'remote_unreachable', 'no answer at all is unreachable')
ok(nodes.chat_answer({ error = 'timeout' }, 'peer-d').detail == 'timeout', 'and the old detail is kept')

print('peer deploy wait ok (' .. checks .. ' checks: a door refusal is a named retryable answer, everything else unchanged)')

