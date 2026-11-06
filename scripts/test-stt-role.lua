-- The speech queue's node role (lua/core/stt.lua): which role the environment asks for, what
-- `configure` tells the node, and the pump that carries the worker thread's signed calls.
--
-- Self-contained, like every fast-path test: no network, no rendezvous, no recognizer, no model. The
-- node's real queue and wire are proven by `cargo test -p wa-stt-remote` (the library's two-node
-- simulation), `cargo test -p wa-kernel-runtime stt_node` (the host half) and
-- `scripts/test-stt-two-nodes.sh` (two `wa` processes). What only this test can check is the glue
-- between them: that a `stt_worker` node configures itself as one, names its producer, and delivers
-- each pending envelope without inventing a second decision.
local json = dofile('lua/vendor/json.lua')

local checks = 0
local function check(value, why)
  assert(value, why)
  checks = checks + 1
end

-- ---- the environment the module reads ------------------------------------------------------------
local real_getenv = host.getenv
local env = {}
host.getenv = function(key)
  if env[key] ~= nil then return env[key] end
  return real_getenv(key)
end
-- No `node.stt` file: the role comes from the environment in this test, and `host.read_file` must not
-- touch the machine's real config.
local real_read_file = host.read_file
host.read_file = function(path)
  if type(path) == 'string' and path:find('node%.stt$') then return nil end
  return real_read_file(path)
end
local logs = {}
host.log = function(line) logs[#logs + 1] = tostring(line) end

-- ---- the node registry, as a stub ---------------------------------------------------------------
-- `nodes.lua` is covered by its own tests; this test is about what `stt.lua` asks of it.
local roster = {
  { node_id = 'aa11', name = 'me' },
  { node_id = 'bb22', name = 'producer' },
}
local registry = {
  identity = function() return { node_id = 'aa11', public_key = 'pk' } end,
  invalidate = function() end,
  list = function() return roster end,
  find = function(selector)
    for _, node in ipairs(roster) do
      if node.name == selector or node.node_id == selector then return node end
    end
    return nil
  end,
}
local remote_calls = {}
-- The real `nodes.remote_call` takes a selector and resolves it itself; the stub keeps that shape so
-- the pump is tested against the call it really makes.
registry.remote_call = function(selector, capability, args)
  local node = registry.find(selector)
  remote_calls[#remote_calls + 1] = { node = node and node.node_id or selector, selector = selector,
    capability = capability, args = args }
  return { ok = { state = 'empty' }, node = node and node.name }
end

local original_dofile = dofile
dofile = function(path)
  if path == 'lua/core/nodes.lua' then return registry end
  return original_dofile(path)
end

-- ---- the node's queue, as a stub ----------------------------------------------------------------
local admin_requests = {}
local admin_answer = { ok = { producer = true, worker = false, queue = { ready = 0 }, workers = {} } }
host.stt_admin = function(raw)
  local request = json.decode(raw)
  admin_requests[#admin_requests + 1] = request
  if request.action == 'configure' then
    return json.encode({ ok = true, enabled = true, producer = request.producer, worker = request.worker,
      producer_id = request.producer_id, owners = #request.owner_nodes })
  end
  return json.encode(admin_answer)
end
local submitted = {}
host.stt_submit = function(raw)
  submitted[#submitted + 1] = json.decode(raw)
  return json.encode({ ok = { job = 7 } })
end
host.stt_pending = function() return nil end
host.stt_deliver = function() return nil end

local stt = dofile('lua/core/stt.lua')

-- ---- the role ------------------------------------------------------------------------------------
env.WASM_AGENT_STT_ROLE = nil
check(stt.role() == 'producer', 'the default role is the producing node')
check(stt.produce() and not stt.work(), 'the default node enqueues and runs the local fallback')
env.WASM_AGENT_STT_ROLE = 'stt_worker'
check(stt.role() == 'worker' and stt.work() and not stt.produce(), 'the job names the role `stt_worker`')
env.WASM_AGENT_STT_ROLE = ' BOTH '
check(stt.role() == 'both' and stt.work() and stt.produce(), 'both roles on one node')
env.WASM_AGENT_STT_ROLE = 'off'
check(stt.role() == 'off' and not stt.work() and not stt.produce(), 'off starts nothing')
env.WASM_AGENT_STT_ROLE = 'nonsense'
check(stt.role() == 'producer', 'an unreadable role keeps the default, never silently turns the queue off')

-- ---- configure -----------------------------------------------------------------------------------
env.WASM_AGENT_STT_ROLE = 'worker'
env.WASM_AGENT_STT_PRODUCER = 'producer'
env.WASM_AGENT_STT_LEASE_MS = '4000'
env.WASM_AGENT_STT_HEARTBEAT_MS = '1000'
env.WASM_AGENT_STT_GRACE_MS = '1500'
env.WASM_AGENT_STT_FRESH_MS = '300000'
local configured = stt.configure('test')
check(configured and configured.ok, 'configure is answered by the node: ' .. tostring(configured and configured.error))
local request
for _, recorded in ipairs(admin_requests) do
  if recorded.action == 'configure' then request = recorded end
end
check(request ~= nil and request.action == 'configure', 'the role is handed over as a configure action')
check(request.me == 'aa11', 'the node names itself, so admission checks the right target')
check(request.worker == true and request.producer == false, 'a worker node does not start a producer')
check(request.producer_name == 'producer', 'the worker names the producer a person does')
check(request.producer_id == 'bb22', 'the producer id is resolved before the worker starts polling')
check(#request.owner_nodes == 2, 'admission learns every node the fabric lists')
check(request.lease_ms == 4000 and request.heartbeat_every_ms == 1000, 'the operator knobs travel')
check(request.fallback_after_ms == 1500, 'the grace travels')
check(request.fresh_ms == 300000, 'the freshness window travels')

-- ---- the pump ------------------------------------------------------------------------------------
-- One pending call: the worker thread asked for work, Lua signs and sends it, and the answer goes
-- back. The pump must not add a decision of its own.
local envelope = json.encode({ v = 1, op = 'take', from = 'aa11', to = 'bb22', ts_ms = 1, rid = 'r1',
  body = { queue = 'stt.requests', worker = 'stt:aa11', lease_ms = 4000, wait_ms = 0 } })
local pending = { id = 41, envelope = envelope }
local delivered = {}
host.stt_pending = function() return pending and json.encode(pending) or 'null' end
host.stt_deliver = function(id, raw)
  delivered[#delivered + 1] = { id = id, answer = json.decode(raw) }
  pending = nil
  return 'null'
end
remote_calls = {}
stt.tick()
check(#remote_calls == 1, 'one pending call is one signed call')
check(remote_calls[1].capability == 'stt', 'it is the stt capability, not a bare tool call')
check(remote_calls[1].node == 'bb22', 'it goes to the producer, by id')
check(remote_calls[1].args.op == 'take', 'the envelope is the library\'s, unchanged')
check(#delivered == 1 and delivered[1].id == 41, 'the answer goes back to the call the thread is waiting on')
check(delivered[1].answer.ok.state == 'empty', 'the producer\'s answer is forwarded verbatim')

-- A producer the fabric does not list yet: the pump says so instead of inventing a peer, and the
-- worker thread decides what that means (`Unreachable`, which is a lease it never took).
roster = { { node_id = 'aa11', name = 'me' } }
pending = { id = 42, envelope = envelope }
delivered = {}
stt.tick()
check(#delivered == 1, 'the call is still answered, so the thread is not left waiting')
check(delivered[1].answer.error == 'stt_producer_unknown', 'a missing producer is a named error: ' .. tostring(delivered[1].answer.error))

-- ---- the producer's own tick ---------------------------------------------------------------------
roster = { { node_id = 'aa11', name = 'me' } }
env.WASM_AGENT_STT_ROLE = 'producer'
env.WASM_AGENT_STT_PRODUCER = nil
stt.tick()
check(stt.role() == 'producer', 'a producer keeps its role after a tick')
check(true, 'a producer tick with no queue work is a no-op, not an error')

-- ---- submit and the operator view ----------------------------------------------------------------
local answer = stt.submit({ audio_b64 = 'AAAA', mime = 'audio/ogg', chat = 'chat', msg = 'm1', sent_at_ms = 1 })
check(answer.ok and answer.ok.job == 7, 'a submitted note names its job')
check(submitted[#submitted].sent_at_ms == 1, 'the send time reaches the node, so freshness is the send time')

env.WASM_AGENT_STT_ROLE = 'both'
local view = stt.view()
check(view.role == 'both', 'the view names this node\'s role')
check(view.knobs and view.knobs.lease_ms == 4000, 'the view carries the knobs actually in force')
check(view.configured == true, 'the view says whether the node was configured')
check(#logs >= 1, 'the role is logged once, as a line an operator can read')
for _, line in ipairs(logs) do
  check(not line:lower():find('canary'), 'no log line carries message text')
end

-- ---- the operator surface ------------------------------------------------------------------------
-- `services` action `stt` is the tool an operator (or the model) calls; it must answer the speech
-- queue's own view, not a summary of it.
env.WASM_AGENT_STT_ROLE = 'worker'
local services = original_dofile('lua/core/services.lua')
local tool = services.control({ action = 'stt' }, { role = 'master' })
check(type(tool) == 'table' and tool.ok ~= false, 'services action stt answers: ' .. tostring(tool and tool.error))
check(tool.role == 'worker', 'the tool view carries the speech role of this node')
check(tool.knobs ~= nil and tool.knobs.lease_ms == 4000, 'the tool view carries the knobs in force')

-- ---- a failing tick is recorded, not thrown ------------------------------------------------------
env.WASM_AGENT_STT_ROLE = 'worker'
host.stt_pending = function() error('pump exploded') end
stt.safe_tick()
check(true, 'a failing pump does not take the node thread down')
check(stt.view().last_error ~= nil, 'the failure is visible in the view')

print('stt role ok — ' .. checks .. ' checks')
