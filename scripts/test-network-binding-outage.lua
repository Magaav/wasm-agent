-- A rendezvous OUTAGE must not turn an already-bound operator into a stranger.
--
-- Brief, second evidence (19/11 ~12:17 UTC, home network down): the work node answered no relayed call
-- for the length of the drop. Every inbound call runs M.authorize, which asks the registry twice (the
-- operator list, then the binding status) and refused with nil when either was unreadable - the value
-- the tree uses for "unknown". So the node could not answer the very calls whose answers let the fleet
-- drain, and the relay timer logged 'detach reason=authority_lost:binding_service_unavailable' 38
-- times. The rule now: a POSITIVE admission is remembered with its time, and only a LINK failure may
-- fall back to it, inside a window. Anything the registry actually ANSWERS still wins - revoked,
-- removed or expired refuses at once - and a caller never admitted before is refused as before, so a
-- new binding can never be created against an unreachable registry.
-- Hermetic: deterministic HTTP, the real native binding state.
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

local binding = dofile('lua/core/binding.lua')
local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

local id = json.decode(host.node_identity())
local service = 'http://127.0.0.1:12345'
local clock = math.floor(host.now())
host.now = function() return clock end
local function operator(digit, key) return {node_id = string.rep(digit, 32), public_key = string.rep(key, 64)} end
local first, stranger = operator('1', 'a'), operator('9', 'z')
local request = {schema = 1, id = host.uuid():gsub('-', ''), code = '0123456789ab', node_id = id.node_id,
  public_key = id.public_key, name = 'probe', service = service, operators = {first},
  scope = 'user-account-tools', expires_at = clock + 86400, pairing_expires_at = clock + 600}
local raw = json.encode(request)
local state = {schema = 1, request = request, raw_request = raw, digest = host.sha256(raw), service = service,
  operators = {first}, expires_at = request.expires_at, active = true, consent = true, phase = 'accepted',
  network_role = 'guest'}
ok(json.decode(host.binding_state('cas', json.encode({state = state}))).ok, 'private binding state installed')

-- mode.up: the registry answers. mode.link: the registry cannot be reached AT ALL (the outage).
local mode = {up = true, vouched = {first}, binding_state = 'accepted'}
host.http = function(method, url)
  if not mode.up then
    -- What a dropped link looks like: no answer. Never a 4xx, which would be a verdict.
    return json.encode({status = 503, body = ''})
  end
  if tostring(url):match('/service$') then
    return json.encode({status = 200, body = json.encode({protocol = 1, binding_protocol = 1,
      enrollment_ready = true, operators = mode.vouched})})
  end
  if tostring(url):find('/bindings/request?', 1, true) then
    return json.encode({status = 200, body = json.encode({ok = true, binding = {digest = state.digest,
      request = request, state = mode.binding_state, revision = 2}})})
  end
  return json.encode({status = 200, body = json.encode({})})
end

binding.admission_cache_clear()

-- 1. A live registry admits a vouched, pinned operator...
ok(binding.authorize(first.node_id, first.public_key) ~= nil, 'a vouched operator is admitted while the registry answers')
ok(binding.admission_cache_size() == 1, 'and the positive decision is remembered')
-- ...and never a stranger, before or after the outage.
ok(binding.authorize(stranger.node_id, stranger.public_key) == nil, 'an operator this node never pinned is refused')

-- 2. The link drops. The SAME operator is still admitted - the node keeps answering its operators.
mode.up = false
local during = binding.authorize(first.node_id, first.public_key)
ok(during ~= nil, 'an already-admitted operator is still admitted during a rendezvous outage')
ok(during.cached == true, 'and the answer says it came from the remembered decision')
-- A caller with no remembered decision is refused: an outage can never admit a NEW binding.
ok(binding.authorize(stranger.node_id, stranger.public_key) == nil,
  'a caller never admitted before is still refused during the outage')

-- 3. The window is finite: past it, the same caller is refused rather than trusted forever.
clock = clock + binding.ADMISSION_CACHE_SECONDS + 1
ok(binding.authorize(first.node_id, first.public_key) == nil,
  'the remembered decision expires, so an outage cannot grant admission indefinitely')
-- Back inside the window, the link returns and the decision is re-confirmed.
clock = math.floor(host.now()) - (binding.ADMISSION_CACHE_SECONDS + 1)
mode.up = true
ok(binding.authorize(first.node_id, first.public_key) ~= nil, 'the operator is admitted again once the registry answers')

-- 4. A registry that ANSWERS beats the cache: removed, revoked and expired all refuse at once.
--    The link is UP here on purpose: "no longer vouched" is a verdict, and a verdict is only
--    meaningful from a registry that could be read. A link that is down is case 2 above.
mode.up = true
mode.vouched = {}
local removed = binding.authorize(first.node_id, first.public_key)
ok(removed == nil, 'a registry that answers "no longer vouched" refuses, even though the cached decision exists')
mode.up = true
mode.vouched = {first}
ok(binding.authorize(first.node_id, first.public_key) ~= nil, 'the operator is re-admitted when the vouch returns')

mode.binding_state = 'revoked'
local revoked = binding.authorize(first.node_id, first.public_key)
ok(revoked == nil, 'a revoked binding refuses at once')
mode.binding_state = 'accepted'
ok(binding.authorize(first.node_id, first.public_key) ~= nil, 'and an accepted one admits again')

mode.up = false
clock = clock + 86400
ok(binding.authorize(first.node_id, first.public_key) == nil, 'an expired binding is refused even during an outage')
mode.up = true
clock = clock - 86400

print('network binding outage ok (' .. checks .. ' checks)')
