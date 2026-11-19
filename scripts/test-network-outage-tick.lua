-- The NODE's half of a relay outage, at unit level: it keeps trying to poll, backs off its register,
-- re-attaches with no restart, and a real caller gets a verified answer once the relay is back.
--
-- WHAT THIS IS NOT: an end-to-end storm. Earlier rounds shipped a row named "storm" here and it was
-- not one - no separate OS processes, no separate registry, no real cut in the transport. Review r3
-- (item 2) asked for the name to match the proof, so it does: this row drives the REAL
-- lua/core/binding.lua M.tick and the REAL lua/core/nodes.lua remote_call against a relay the test
-- owns, and that is exactly what it claims. The end-to-end storm (real nodes, real cut, redesign of
-- the relay) MOVED to the fabric-transport mission, where the relay is rebuilt.
--
-- The outage: the relay answers nothing for 60 s. The assertions are that the node KEEPS TRYING to
-- poll on every second of it (before the fix a failed /register returned before the poll: the 19/11
-- deadlock), that it re-attaches without a restart, and that a caller then gets the node's own answer.
local json = dofile('lua/vendor/json.lua')

-- ---- the scratch-home guard ----------------------------------------------------------------
local function refuse_real_home()
  local scratch = tostring(host.getenv('WASM_AGENT_HOME') or '')
  local data = dofile('lua/core/paths.lua').data()
  local live = host.path_kind(data .. '/keys') == 'dir' or host.path_kind(data .. '/secrets') == 'dir'
  if scratch == '' or data:find(scratch, 1, true) ~= 1 or live then
    print('SKIP refusing to write under ' .. data .. ' (set WASM_AGENT_HOME to a scratch directory)')
    os.exit(77)
  end
end
refuse_real_home()

-- The mesh layer answers a call BEFORE the relay when the host says it is enabled, and this row is
-- about the relay path. The host binary decides that itself (measured: host.mesh_call gate answered
-- enabled=true and a caller got mesh_refused/policy_unreadable, never reaching /relay/send), so the
-- gate is answered here explicitly rather than inherited from the machine running the test.
host.mesh_call = function(ask)
  local decoded_ok, question = pcall(json.decode, ask)
  if decoded_ok and type(question) == 'table' and question.gate then
    return json.encode({enabled = false, reason = 'storm-test: relay path only'})
  end
  return json.encode({error = 'mesh_disabled_for_test'})
end

local binding = dofile('lua/core/binding.lua')
local nodes = dofile('lua/core/nodes.lua')
local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

-- A clock the test moves, so 60 s of outage costs no real time and the assertion is deterministic.
local clock = 1792000000
host.now = function() return clock end
host.sleep = function() end

-- The relay URL is what makes remote_call take the RELAY path; without it the mesh layer answers first
-- (measured: mesh_refused/policy_unreadable, and no /relay/send was ever attempted).
local native_getenv = host.getenv
host.getenv = function(key)
  if key == 'WASM_AGENT_RELAY' or key == 'WASM_AGENT_RENDEZVOUS' then return 'http://127.0.0.1:1' end
  -- The MESH layer answers before the relay when it is on, and this row is about the relay path. The
  -- ambient environment of this very session sets WA_MESH (measured: a caller got
  -- mesh_refused/policy_unreadable and never reached /relay/send), so it is cleared HERE rather than
  -- left to whatever the runner happens to export.
  if key == 'WA_MESH' or key == 'WA_MESH_COMPONENT' then return nil end
  return native_getenv(key)
end

local id = json.decode(host.node_identity())
local service = 'http://127.0.0.1:1'
local first = {node_id = string.rep('1', 32), public_key = string.rep('a', 64)}
local request = {schema = 1, id = host.uuid():gsub('-', ''), code = '0123456789ab', node_id = id.node_id,
  public_key = id.public_key, name = 'storm-node', service = service, operators = {first},
  scope = 'user-account-tools', expires_at = clock + 86400, pairing_expires_at = clock + 600}
local raw = json.encode(request)
local state = {schema = 1, request = request, raw_request = raw, digest = host.sha256(raw),
  service = service, operators = {first}, expires_at = request.expires_at, active = true,
  consent = true, phase = 'accepted', network_role = 'master'}
ok(json.decode(host.binding_state('cas', json.encode({state = state}))).ok, 'private binding state installed')

-- ---- the relay the test owns --------------------------------------------------------------------
-- down = true is the CUT: every call answers the way a dropped link does (no answer at all), which is
-- what the transport reports as "io: Peer disconnected".
local relay = {down = false, polls = 0, poll_attempts = 0, sends = 0}
host.http = function(method, url, headers, body)
  -- The ATTEMPT is counted first: during the outage every call still LEAVES the node, and that
  -- is the property this row proves. Counting only the answered ones made the during-cut
  -- assertion vacuous - it measured the stub's own short-circuit (review r3, item 2).
  local target = tostring(url)
  if target:find('/relay/poll', 1, true) then relay.poll_attempts = relay.poll_attempts + 1 end
  if relay.down then return json.encode({status = 0, body = ''}) end
  url = tostring(url)
  if url:match('/service$') then
    return json.encode({status = 200, body = json.encode({protocol = 1, binding_protocol = 1,
      enrollment_ready = true, operators = {first}})})
  end
  if url:find('/bindings/request?', 1, true) then
    return json.encode({status = 200, body = json.encode({ok = true, binding = {digest = state.digest,
      request = request, state = 'accepted', revision = 2}})})
  end
  if url:find('/register', 1, true) then
    if relay.register_fails then return json.encode({status = 500, body = '{"error":"nope"}'}) end
    return json.encode({status = 200, body = json.encode({ok = true})})
  end
  if url:find('/relay/poll', 1, true) then
    relay.polls = relay.polls + 1
    return json.encode({status = 200, body = '{}'})
  end
  if url:find('/relay/send', 1, true) then
    relay.sends = relay.sends + 1
    -- A SIGNED reply, the shape the real relay returns and the caller verifies: the node answers in
    -- "reply" and signs it against the request timestamp and signature. An unsigned body is refused
    -- (measured: the first version of this answered with a bare body and the caller - rightly -
    -- rejected it as unsigned_reply).
    local envelope = json.decode(body or '{}')
    local headers = (envelope and envelope.headers) or {}
    local out = json.encode({ok = true, content = 'answered after the storm'})
    local _, signature = nodes.sign_action('reply', tonumber(headers['X-WA-Ts']),
      tostring(headers['X-WA-Sig']) .. string.char(10) .. out)
    return json.encode({status = 200, body = json.encode({ok = true, status = 200,
      body = json.encode({reply = out, reply_sig = signature})})})
  end
  if url:find('/lookup?', 1, true) then
    return json.encode({status = 200, body = json.encode({public_key = id.public_key,
      role = 'master', online = true, relay_attached = true})})
  end
  return json.encode({status = 200, body = json.encode({})})
end

-- ---- the 60 s outage -----------------------------------------------------------------------------
-- A tick loop like the transport's: poll, and keep polling. Before the fix a failed /register (or an
-- unreadable authority) returned BEFORE the poll, so the node went silent for the whole outage.
-- ONE healthy tick first, which is the real situation: the node was attached when the relay went
-- away, so it has an observation to fall back on. A node that never reached the registry at all is
-- not attached and has nothing to keep polling FOR - and the assertion below would be measuring that
-- different case (review r3, item 2: count attempts, but count them for the right scenario).
local healthy = binding.tick()
ok(healthy.state == 'attached', 'the node is attached before the outage: ' .. json.encode(healthy))

local ATTEMPTS = 60
local ran = 0
relay.down = true
for _ = 1, ATTEMPTS do
  clock = clock + 1
  local tick = binding.tick()
  ran = ran + 1
  -- Every second of the outage, the tick ANSWERS something: it never disappears.
  ok(type(tick) == 'table' or tick == nil, 'the tick ran on second ' .. ran .. ' of the outage')
end
ok(ran == ATTEMPTS, 'the tick ran on every second of the outage, not once')
ok(relay.poll_attempts >= ATTEMPTS,
  'the node TRIED to poll on every second of the outage, not once: attempts '
    .. relay.poll_attempts .. ' over ' .. ATTEMPTS .. ' seconds')

-- ---- the deadlock itself: /register fails, the poll lane still answers ------------------------------
-- 19/11: the tick returned BEFORE its /relay/poll when /register failed, and did not advance the
-- heartbeat, so every 2 s it retried only the register and never polled. The node went unreachable, so
-- the calls waiting for it could not be answered, so the queue never drained. This is the assertion the
-- BASE binary fails: it polls zero times.
relay.down = false
relay.register_fails = true
collectgarbage()
local before_register_failure = relay.polls
local tick_reg = binding.tick()
ok(relay.polls > before_register_failure,
  'a FAILED /register still polls the relay (the 19/11 deadlock): polls '
    .. before_register_failure .. ' -> ' .. relay.polls)
ok(type(tick_reg) == 'table' and tick_reg.state == 'attached',
  'and the node reports itself attached, not stuck on the register: ' .. json.encode(tick_reg))
relay.register_fails = false

-- ---- the restore -----------------------------------------------------------------------------------
relay.down = false
clock = clock + 60
local before = relay.polls
local after = binding.tick()
ok(relay.polls > before, 'the node POLLS again the moment the link returns, with no restart')
ok(after.state == 'attached', 'and it is attached: ' .. json.encode(after))

-- ---- a real caller gets an answer ------------------------------------------------------------------
-- nodes.remote_call is the production caller: the roster, the slot and the retry are all its own.
local peer = {node_id = id.node_id, name = 'storm-target', endpoints = {}, public_key = id.public_key,
  relay_attached = true, online = true}
nodes.find = function(selector)
  if selector == 'storm-target' or selector == id.node_id then return peer end
  return nil
end
local answer = nodes.remote_call('storm-target', 'bash', {command = 'true'})
ok(relay.sends == 1, 'the caller sent exactly one relayed call, got ' .. relay.sends)
-- A verified reply is the node's own decoded body (nodes.verified_reply), not the relay envelope: what
-- proves the round trip is the content the node answered with.
ok(type(answer) == 'table' and answer.ok == true
  and tostring(answer.content or ''):find('answered after the storm', 1, true) ~= nil,
  'and the caller holds the node answer, verified: ' .. json.encode(answer))

-- ---- and the slots are all back --------------------------------------------------------------------
ok(nodes.slots_held(id.node_id) == 0,
  'no slot is left held after the outage and the call, got ' .. tostring(nodes.slots_held(id.node_id)))

print('network outage tick ok (' .. checks .. ' checks)')
