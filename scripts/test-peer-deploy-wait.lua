-- WHAT A CALLING NODE DOES WITH A PEER'S `deploy_waiting` ANSWER (23/11, Fable's review 1c).
--
-- MEASURED in this tree before the change: `nodes.remote_chat` turned every non-200 into `remote_unreachable`
-- with the status as `detail` and threw the body away - so a peer that was alive, installing a build and had run
-- nothing was reported to the caller's model as a lost peer, and the one number that makes a retry sane
-- (`retry_after_seconds`) was gone.
--
-- This row goes through the REAL entry point (`remote_chat`, the one `lua/core/server.lua` calls for a peer run)
-- with the transport stubbed and no network at all: the node's roster and `M.request` are replaced, so what is
-- asserted is the decision `remote_chat` makes about a status and a body - which is exactly what the base got
-- wrong, and why this row fails on the base code (`error = remote_unreachable`).
--
--   WASM_AGENT_HOME=$(mktemp -d) WASM_AGENT_LUA_ROOT=<tree> WA_SCRIPT=scripts/test-peer-deploy-wait.lua wa --db <t>/t.db
local json = dofile('lua/vendor/json.lua')
local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-peer-deploy-wait')
if why_home then print('REFUSED test-peer-deploy-wait: ' .. why_home); os.exit(2) end

local nodes = dofile('lua/core/nodes.lua')

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end

-- A peer that answers with this status and body, and a caller that reaches it: no endpoint, so `remote_chat` asks
-- `M.request` directly, which is the stub.
local function call(status, body)
  nodes.find = function(selector)
    return { name = tostring(selector), node_id = string.rep('ab', 16), endpoints = {}, online = true }
  end
  nodes.request = function() return { status = status, body = body } end
  return nodes.remote_chat('peer-b', 'carry on with the mission')
end

local door = json.encode({ error = 'deploy_waiting', not_started = true, retry_after_seconds = 30,
  hint = 'deploy_waiting: this node is waiting for or installing a new build. ...' })

-- 1. A waiting deploy on the peer is a named, retryable answer that says nothing ran there.
local answer = call(503, door)
ok(answer.error == 'remote_deploy_waiting',
  'a door refusal is named as a deploy wait, not as unreachable: ' .. tostring(answer.error))
ok(answer.not_started == true, 'it says the peer started nothing')
ok(answer.retryable == true, 'it is retryable')
ok(answer.retry_after_seconds == 30, 'and it carries the peer number to retry after: ' .. tostring(answer.retry_after_seconds))
ok(tostring(answer.message or ''):find('peer-b', 1, true) ~= nil, 'the message names the peer')
ok(tostring(answer.message or ''):find('30', 1, true) ~= nil, 'and the number in the words a model reads')
ok(tostring(answer.message or ''):lower():find('nothing was lost', 1, true) ~= nil, 'and says nothing was lost')

-- 2. An older peer that refuses without a number: still retryable, no invented number.
local old = call(503, json.encode({ error = 'deploy_waiting', not_started = true }))
ok(old.error == 'remote_deploy_waiting' and old.retryable == true, 'a door refusal without a number is still retryable')
ok(old.retry_after_seconds == nil, 'and no number is invented: ' .. tostring(old.retry_after_seconds))

-- 3. Everything else keeps its old answer, so this change cannot turn a real failure into a promise to retry.
local failed = call(500, 'oops')
ok(failed.error == 'remote_unreachable', 'a 500 is still unreachable: ' .. tostring(failed.error))
ok(failed.detail == 500, 'with the status as its detail: ' .. tostring(failed.detail))
ok(call(503, json.encode({ error = 'node_thread_stalled' })).error == 'remote_unreachable',
  'a 503 that is not the door is still unreachable')
local served = call(200, door)
ok(served.ok == true and served.error == nil,
  'a 200 is a served turn, not an error (the body is the peer stream, even if it names a deploy): ' .. tostring(served.error))
nodes.request = function() return nil end
local silent = nodes.remote_chat('peer-b', 'x')
ok(silent.error == 'remote_unreachable', 'no answer at all is unreachable: ' .. tostring(silent.error))

print('peer deploy wait ok (' .. checks .. ' checks: a door refusal is a named retryable answer, everything else unchanged)')

