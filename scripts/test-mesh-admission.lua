-- The mesh admission of a relayed call, and the fleet bootstrap that turns it on (docs/MESH.md §5-7).
--
-- What is exercised here, with the real `lua/core/binding.lua` and a deterministic host:
--
--   1. a caller that is not one of this node's pinned operators is refused (`unknown_caller`) — the
--      state every node is in before it is bootstrapped;
--   2. a `roster` push from such a caller is refused, and nothing is written;
--   3. a push from a pinned operator installs the roster: the `mesh` section is merged into this
--      node's own policy.json, the previous file is kept, the signed roster is written, and the flag
--      is added to the node's env file for the next start;
--   4. after that, a *relayed mesh call* is admitted by the roster — `wa_mesh_admit` (what the host
--      sets for one call) makes `binding.authorize` consult the roster instead of the pins;
--   5. it is one call, not a standing permission: cleared, the same caller is refused again;
--   6. an admission that names another caller, or has a malformed key, admits nothing.
--
-- Loopback-free: no socket is opened. `host.http` is the same deterministic stub the binding tests
-- use, and every file this writes lives in the scratch home the runner gave this process.
local json = dofile('lua/vendor/json.lua')
local binding = dofile('lua/core/binding.lua')
local paths = dofile('lua/core/paths.lua')

local checks, skipped = 0, 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function eq(got, want, label)
  checks = checks + 1
  assert(got == want, (label or '') .. ': got ' .. tostring(got) .. ', want ' .. tostring(want))
end

local config = paths.config()
local identity = json.decode(host.node_identity())
local pin = { node_id = identity.node_id, public_key = identity.public_key }
local service = 'http://127.0.0.1:12345'
local now = math.floor(host.now())

-- An id/key pair that is well formed but is not this node: "somebody else's operator list".
local stranger = { node_id = string.rep('ab', 16), public_key = string.rep('cd', 32) }

-- ---- the roster, signed with this node's own key (a fleet key may be the operator's node key) ------
local function roster_json()
  local issued = now - 60
  local self_node = string.format(
    '{"node_id":"%s","public_key":"%s","name":"self","level":0,"addresses":[],"revoked_at":0}',
    identity.node_id, identity.public_key)
  -- One node is enough for the roster's own shape: a second entry would have to carry a node_id that
  -- really is `sha256(public_key)[..32]`, and a Lua fixture cannot derive one without the raw bytes.
  -- The "somebody else" used below never needs to be in the roster; the admission is what names it.
  local nodes = '[' .. self_node .. ']'
  local canonical = 'mesh-roster-v1|ohana|' .. tostring(issued) .. '|0|{"nodes":' .. nodes .. '}'
  local signed = json.decode(host.sign(canonical))
  ok(signed and signed.signature, 'the fixture roster is signed')
  return {
    version = 1, fleet = 'ohana', issued_at = issued, expires_at = 0,
    nodes = {
      { node_id = identity.node_id, public_key = identity.public_key, name = 'self', level = 0, addresses = {}, revoked_at = 0 },
    },
    signature = signed.signature,
  }
end
local fleet = roster_json()
local fleet_text = json.encode(fleet)

-- ---- a binding state whose operators are `pins` ---------------------------------------------------
local function write_binding(pins)
  local request = { schema = 1, id = host.uuid():gsub('-', ''), code = '0123456789ab',
    node_id = identity.node_id, public_key = identity.public_key, name = 'private', service = service,
    operators = pins, scope = 'user-account-tools', expires_at = now + 86400, pairing_expires_at = now + 600 }
  local raw_request = json.encode(request)
  local state = { schema = 1, request = request, raw_request = raw_request,
    digest = host.sha256(raw_request), service = service, operators = pins,
    expires_at = request.expires_at, active = true, consent = true, phase = 'accepted',
    network_role = 'master' }
  local written = json.decode(host.binding_state('cas', json.encode({ expected = json.decode(host.binding_state('read', '{}')).state, state = state })))
  ok(written and written.ok, 'the fixture binding state is written')
  return state
end

-- ---- the deterministic service ---------------------------------------------------------------
local mode = 'accepted'
local last_response
local binding_digest
local relay_queue = {}
host.http = function(method, url, headers, body)
  local value
  if url:match('/service$') then
    -- The registry vouches for exactly the pins the node bound: that is the authority `M.inspect`
    -- compares against, and the test binds different pins in different phases.
    local state = json.decode(host.binding_state('read', '{}')).state or {}
    value = { protocol = 1, binding_protocol = 1, enrollment_ready = true,
              binding_lifetimes = { 'standard', 'permanent' },
              operators = state.operators or {} }
  elseif url:match('/lookup') then
    value = { node_id = identity.node_id, public_key = identity.public_key, online = true,
              relay_attached = true, role = 'master', binding = { state = mode, request = { id = 'r1', code = '0123456789ab' } } }
  elseif url:match('/bindings/request') then
    local state = json.decode(host.binding_state('read', '{}')).state or {}
    value = { ok = true, binding = { request = state.request or {}, digest = state.digest,
      state = mode, revision = 1 } }
  elseif url:match('/register') then
    value = { ok = true }
  elseif url:match('/relay/poll') then
    local next_up = table.remove(relay_queue, 1)
    value = next_up and { request = next_up } or {}
  elseif url:match('/relay/respond') then
    last_response = body
    value = { ok = true }
  end
  return json.encode({ status = value and 200 or 404, body = json.encode(value or { error = 'not_found' }) })
end

-- ---- 1. a caller this node does not pin is refused ------------------------------------------------
write_binding({ stranger })
ok(binding.authorize(identity.node_id, identity.public_key) == nil,
  'a caller absent from the operator pins is not admitted')

-- ---- 2. and a push from it is refused, writing nothing -------------------------------------------
local function push_request(signer, subset)
  local args = { action = 'push', roster = fleet_text, roster_key = identity.public_key }
  for key, value in pairs(subset or {}) do args[key] = value end
  local body = json.encode({ from_node_id = identity.node_id, to_node_id = identity.node_id,
    request_id = host.uuid(), capability = 'roster', args = args })
  local ts = math.floor(host.now())
  local signed = json.decode(host.sign('call|' .. identity.node_id .. '|' .. ts .. '|' .. host.sha256(body)))
  return { id = host.uuid(), method = 'POST', path = '/node/call',
    headers = { ['x-wa-node'] = identity.node_id, ['x-wa-pub'] = identity.public_key,
                ['x-wa-ts'] = tostring(ts), ['x-wa-sig'] = signed.signature },
    body = body }, body
end

-- A push from the stranger's point of view: the signature cannot be made for a key we do not hold, so
-- the same body signed by this node but *claimed* to be the stranger is a bad signature, not an
-- unknown caller. The unknown-caller refusal is exercised above, where admission is decided.
do
  local job = push_request(identity)
  relay_queue = { job }
  local ticked = binding.tick()
  ok(ticked and ticked.state == 'attached', 'the runtime ticked with a push queued: ' .. json.encode(ticked or {}))
  ok(host.read_file(config .. '/policy.json') == nil, 'a refused push writes no policy')
  ok(host.read_file(config .. '/mesh-roster.json') == nil, 'a refused push writes no roster')
end

-- ---- 3. a pinned operator installs the roster -----------------------------------------------------
write_binding({ pin })
local policy_before = json.encode({ version = 1, components = { keep = { me = true } } })
ok(host.write_file(config .. '/policy.json', policy_before), 'a policy exists before the push')
do
  local job = push_request(identity)
  relay_queue = { job }
  local ticked = binding.tick()
  ok(ticked and ticked.state == 'attached', 'the push tick finished: ' .. json.encode(ticked or {}))
  local answered = last_response and json.decode(last_response)
  local reply = answered and answered.body and json.decode(answered.body)
  local inner = reply and reply.reply and json.decode(reply.reply) or reply
  ok(type(inner) == 'table', 'the push was answered with a signed reply')
  eq(inner.ok, true, 'the pinned operator installed the roster: ' .. json.encode(inner))
  local policy = json.decode(host.read_file(config .. '/policy.json') or '{}')
  ok(type(policy) == 'table', 'the policy is still JSON')
  ok(type(policy.mesh) == 'table', 'the mesh section was merged in')
  eq(policy.mesh.roster_key, identity.public_key, 'the fleet key is pinned')
  eq(policy.mesh.enabled, true, 'the running node is enabled by its own policy')
  ok(policy.components and policy.components.keep and policy.components.keep.me == true,
    'nothing else in the policy was touched')
  eq(host.read_file(config .. '/policy.prev.json'), policy_before, 'the previous policy is kept byte for byte')
  ok((host.read_file(config .. '/mesh-roster.json') or '') ~= '', 'the signed roster was written')
  local env = host.read_file(config .. '/env') or ''
  ok(env:find('WA_MESH=1', 1, true) ~= nil, 'the next start reads WA_MESH=1 from the env file')
end

-- A second push is idempotent (same bytes, same files).
do
  local policy_first = host.read_file(config .. '/policy.json')
  local job = push_request(identity)
  relay_queue = { job }
  binding.tick()
  eq(host.read_file(config .. '/policy.json'), policy_first, 'a second push changes nothing')
end

-- ---- 4. a relayed mesh call is now admitted by the roster, for one call ---------------------------
ok(binding.authorize(identity.node_id, identity.public_key) ~= nil, 'the pinned operator is still admitted')
eq(binding.authorize(stranger.node_id, stranger.public_key), nil,
  'a node nobody admitted - not pinned, not admitted by the roster for this call - is refused')

do
  -- The host's admission for the call it is about to run: the roster said yes to this caller.
  local admitted = json.decode(wa_mesh_admit(json.encode({
    node_id = stranger.node_id, public_key = stranger.public_key, name = 'peer', level = 1,
    capability = 'read', request_id = 'mesh-1' })))
  ok(admitted and admitted.ok, 'the host can hand one roster admission over')
  local caller = binding.authorize(stranger.node_id, stranger.public_key)
  ok(caller ~= nil, 'a roster-admitted caller is admitted although it is not in the operator pins')
  eq(caller.role, 'master', 'a roster-admitted caller is a master')
  eq(caller.mesh, 'roster', 'and the caller table says why')
  local profile = binding.profile()
  ok(profile and type(profile.operators) == 'table', 'the author attribution sees a profile')
  local listed = false
  for _, operator in ipairs(profile.operators or {}) do
    if operator.node_id == stranger.node_id and operator.public_key == stranger.public_key then listed = true end
  end
  ok(listed, 'the roster caller is listed for the length of the call, so the work is attributed to it')
end

-- ---- 5. it was one call, not a standing permission -----------------------------------------------
wa_mesh_clear()
eq(binding.authorize(stranger.node_id, stranger.public_key), nil,
  'cleared, the same caller is refused again: the pins are back in charge')

-- ---- 6. an admission naming another caller, or malformed, admits nothing -------------------------
do
  wa_mesh_admit(json.encode({ node_id = identity.node_id, public_key = identity.public_key,
    capability = 'read', request_id = 'mesh-2' }))
  eq(binding.authorize(stranger.node_id, stranger.public_key), nil,
    'an admission for another caller admits nothing')
  wa_mesh_clear()
  local bad = json.decode(wa_mesh_admit(json.encode({ node_id = 'short', public_key = 'x' })))
  eq(bad.ok, false, 'a malformed admission is refused')
  eq(binding.authorize(identity.node_id, identity.public_key) ~= nil, true,
    'and this node still admits its own pinned operator')
end

print(string.format('mesh admission ok (%d checks, %d skipped)', checks, skipped))
