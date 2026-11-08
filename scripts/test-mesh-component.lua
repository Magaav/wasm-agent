-- The `wa:mesh` capability, through the real interpreter: `host.mesh` is the same seam the node's own
-- call path uses (`wa_mesh::seam`), so what it answers here is what a decision costs at the boundary.
--
-- No key is needed and none is used: this test asks the *pure* questions - the hierarchy and the grants,
-- the verb a capability needs, the audit line, the dial order, the composed attestation message - and
-- the refusals a roster that is not the operator's gets. A signature would need the node's identity, and
-- that stays the node's (`docs/MESH.md` §9); the Rust side pins the signed cases
-- (`rust/wa-mesh/src/tests_component.rs`).
--
-- Run by `scripts/test-mesh-component.sh`, which installs the built artifact and turns the switch on.
-- Everything here is local: no node, no socket, no network, no `wa serve`.

-- Self-contained: the runner's own `--db`, a scratch WASM_AGENT_HOME, no node, no network, no model.
-- The capability half needs the built `mesh.wasm` reachable *by this process*, which means
-- `WA_MESH_COMPONENT_WASM` (the development override the other seams use) and `WA_MESH_COMPONENT=1`;
-- `scripts/test-mesh-component.sh` builds it and sets both. When either is missing the whole file
-- reports SKIPPED - printed as such - and a skip is never counted as a pass.
local json = dofile('lua/vendor/json.lua')

if host.getenv('WA_MESH_COMPONENT') ~= '1' then
  print('SKIP mesh component: the switch is off (set WA_MESH_COMPONENT=1 to route the seam through the guest)')
  return
end

local function fail(message)
  error('mesh-component: ' .. message, 2)
end

local function eq(actual, expected, what)
  if actual ~= expected then
    fail(string.format('%s: expected %s, got %s', what, tostring(expected), tostring(actual)))
  end
end

if type(host.mesh) ~= 'function' then
  print('SKIP mesh component: this binary has no host.mesh capability (build rust/wa-host from this tree)')
  return
end

local function ask(request)
  local raw = host.mesh(json.encode(request))
  local answer = raw
  if type(raw) == 'string' then answer = json.decode(raw) end
  if type(answer) ~= 'table' then fail('no answer from host.mesh for ' .. tostring(request.op)) end
  return answer
end

-- A four-node fleet. The ids are shaping, not identity: `decide` reads the level, the revocation and the
-- ids out of the facts it is given, and the *roster* that would supply them is `verify_roster`'s job.
local function node(id, name, level, revoked)
  return { id = id, public_key = id .. id, name = name, level = level, addresses = {}, revoked_at = revoked or 0 }
end
local laptop = node('aa', 'laptop', 0)
local oracle = node('bb', 'oracle', 1)
local phone = node('cc', 'phone', 1)
local guest = node('dd', 'guest', 2)

local function decide(caller, target, verb, grants)
  local answer = ask({
    op = 'decide', caller = caller, target = target, verb = verb, now = 1762000100, grants = grants or {},
  })
  if answer.ok ~= true or type(answer.result) ~= 'table' then
    fail('decide did not answer: ' .. json.encode(answer))
  end
  return answer.result
end

-- ---- the hierarchy: down and across are allowed, up needs a grant --------------------------------
local down = decide(laptop, oracle, 'control')
eq(down.allow, true, 'a level-0 node may control a level-1 node')
eq(down.reason, 'hierarchy_allowed', 'the reason names the hierarchy')

local across = decide(oracle, phone, 'control')
eq(across.allow, true, 'the same level may call each other')

local up = decide(oracle, laptop, 'control')
eq(up.allow, false, 'an upward call without a grant is denied')
eq(up.reason, 'hierarchy_denied', 'the refusal names the hierarchy')

local deeper = decide(laptop, guest, 'read')
eq(deeper.allow, true, 'a superior may call a subordinate')

-- ---- the four grant answers, and deny before allow ----------------------------------------------
local granted = decide(oracle, laptop, 'read', { { caller = '*', target = laptop.id, verb = 'read', effect = 'allow' } })
eq(granted.allow, true, 'an allow grant covers the upward call')
eq(granted.reason, 'grant_allowed', 'and the reason says it was the grant')

local uncovered = decide(oracle, laptop, 'control', { { caller = '*', target = laptop.id, verb = 'read', effect = 'allow' } })
eq(uncovered.allow, false, 'the same grant does not cover control authority')

local both = {
  { caller = '*', target = laptop.id, verb = 'control', effect = 'allow' },
  { caller = '*', target = laptop.id, verb = 'control', effect = 'deny' },
}
eq(decide(oracle, laptop, 'control', both).reason, 'grant_denied', 'a deny grant wins over an allow one')

-- ---- revocation and self-calls, before any grant ------------------------------------------------
local revoked = node('ee', 'stolen', 0, 1762000050)
eq(decide(revoked, laptop, 'read').reason, 'revoked', 'a revoked caller is refused')
eq(decide(laptop, revoked, 'read').reason, 'revoked', 'a revoked target is refused')

eq(decide(laptop, laptop, 'read').reason, 'self_call', 'a node does not call itself')

-- ---- the verb a capability needs ---------------------------------------------------------------
for capability, want in pairs({ read = 'read', grep = 'read', bash = 'control', write_file = 'control', something_new = 'call' }) do
  local answer = ask({ op = 'verb', capability = capability })
  eq(answer.result, want, 'the verb for ' .. capability)
end

-- ---- the audit line, character for character ----------------------------------------------------
-- The ids are the eight characters `Event::new` keeps (`short()`), because that is what the native
-- event carries by the time it is rendered; the renderer prints the fields it is given.
local line = ask({ op = 'render_audit', event = {
  kind = 'call', from = '8c11f0a2', to = '3f2a91cd',
  from_level = 0, to_level = 1, verb = 'control', decision = 'allow', reason = 'hierarchy_allowed',
  transport = 'direct:lan', addr_class = 'private', ok = true, status = 200, ms = 41, attempt = 1,
} }).result
eq(line,
  'mesh call from=8c11f0a2 to=3f2a91cd levels=0->1 verb=control decision=allow reason=hierarchy_allowed '
    .. 'transport=direct:lan addr_class=private ok=true status=200 ms=41 attempt=1',
  'the audit line is the one the node writes')

-- ---- the dial order: the roster's own list first, cheapest class first, then what was learned -----
local ordered = ask({ op = 'addresses',
  target = { id = 'aa', public_key = 'aaaa', name = 'laptop', level = 0, revoked_at = 0,
             addresses = { '147.15.64.233:8891', '192.168.1.10:8891' } },
  learned = { '8.8.8.8:8891', '10.0.0.4:8891' } }).result
eq(table.concat(ordered, ','), '192.168.1.10:8891,147.15.64.233:8891,10.0.0.4:8891,8.8.8.8:8891',
  'a private address is tried before a public one, the roster before the cache')

-- ---- the attestation's bytes, which the node signs (no key here) --------------------------------
local composed = ask({ op = 'attest_message', node_id = '3f2a', caller = '8c11', verb = 'read',
  capability = 'sessions', caller_signature = 'ab12', ts = 1762000000 }).result
-- The same string `wa_mesh_core::attest::message` composes, and the one `lua/core/server.lua`
-- reconstructs for `action = "mesh-allow"`: the domain, this node, the timestamp, and the hash of the
-- caller|verb|capability|request-signature material.
eq(composed, 'mesh-allow|3f2a|1762000000|e9f4625e7b10c0e8da7446218863174bdbca08ffcb272c5e4e1a322f22104cab',
  'the attestation message is the one the node signs')

-- ---- a roster: verified with the node's own key, refused for a stranger's ------------------------
--
-- The signer here is this node's identity (`host.sign`), which is also the fleet key for this test: it
-- proves the guest's ed25519 accepts a signature the node's ring identity made, byte for byte, and that
-- the levels it answers are the roster's. The *operator's* key is the one the node would pin; there is
-- nothing to pin in a scratch home, so the same identity plays both parts and the test says so.
local identity = json.decode(host.node_identity())
if type(identity.node_id) ~= 'string' or #identity.node_id ~= 32 then
  fail('this node has no identity to sign with: ' .. json.encode(identity))
end
-- `Roster::canonical()`: the domain, the fleet, the window, and the nodes as JSON in the field order
-- `RosterNode` declares (serde_json writes the struct's own order, not this script's).
local function canonical(fleet, issued, expires, nodes)
  return string.format('mesh-roster-v1|%s|%d|%d|{"nodes":%s}', fleet, issued, expires, nodes)
end
local one = string.format(
  '{"node_id":"%s","public_key":"%s","name":"laptop","level":0,"addresses":["127.0.0.1:8891"],"revoked_at":0}',
  identity.node_id, identity.public_key)
local nodes = '[' .. one .. ']'
local signature = json.decode(host.sign(canonical('ohana-1', 1762000000, 0, nodes))).signature
local document = string.format(
  '{"version":1,"fleet":"ohana-1","issued_at":1762000000,"expires_at":0,"signature":"%s","nodes":%s}',
  signature, nodes)

local verified = ask({ op = 'verify_roster', document = document, key = identity.public_key, now = 1762000100 })
if type(verified.result) ~= 'table' then fail('a roster the key signed did not verify: ' .. json.encode(verified)) end
eq(verified.result.fleet, 'ohana-1', 'the fleet name comes back')
eq(verified.result.levels[1].id, identity.node_id, 'the levels come back with the id')
eq(verified.result.levels[1].level, 0, 'and the level')
if #verified.result.fingerprint ~= 16 then fail('the fingerprint is sixteen hex characters: ' .. verified.result.fingerprint) end

-- A stranger's key does not verify it: nothing is believed because a peer wrote it down.
local refused = ask({ op = 'verify_roster', document = document, key = string.rep('a', 64), now = 1762000100 }).refused
eq(type(refused) == 'table' and refused.error, 'roster_unverified:bad_signature',
  'a roster signed by another key is a signature failure')

-- The same roster with the signature removed: still a signature failure, not a shape one.
local unsigned = document:gsub('"signature":"[0-9a-f]*"', '"signature":""')
local refused = ask({ op = 'verify_roster', document = unsigned, key = identity.public_key, now = 1762000100 }).refused
eq(type(refused) == 'table' and refused.error, 'roster_unverified:bad_signature',
  'an unsigned roster is a signature failure')

-- ... and past its window it is expired, with the same sentence the native path uses.
local expired = string.format(
  '{"version":1,"fleet":"ohana-1","issued_at":1762000000,"expires_at":1762000050,"signature":"%s","nodes":%s}',
  json.decode(host.sign(canonical('ohana-1', 1762000000, 1762000050, nodes))).signature, nodes)
local refused = ask({ op = 'verify_roster', document = expired, key = identity.public_key, now = 1762000100 }).refused
eq(type(refused) == 'table' and refused.error, 'roster_expired', 'an expired roster is refused as expired')

-- A document that is not a roster names the parse.
local refused = ask({ op = 'verify_roster', document = '{}', key = string.rep('a', 64) }).refused
if type(refused) ~= 'table' or type(refused.error) ~= 'string' then
  fail('an unreadable roster must be refused with a sentence: ' .. json.encode(refused))
end
if not refused.error:find('not a valid roster', 1, true) then
  fail('the refusal names the parse: ' .. refused.error)
end

-- A key that is not a key is refused as one, before anything is parsed out of it.
local refused = ask({ op = 'verify_roster', document = unsigned, key = 'short' }).refused
eq(type(refused) == 'table' and refused.error, 'mesh.roster_key:expected_64_hex_characters',
  'a malformed fleet key is refused as one')

-- ---- an unknown operation is a bad request, never an empty answer ---------------------------------
local unknown = ask({ op = 'delete_everything' })
eq(unknown.ok, false, 'an unknown operation is a failure, not an answer')
if type(unknown.error) ~= 'string' or not unknown.error:find('invalid_mesh_request', 1, true) then
  fail('an unknown operation names itself: ' .. json.encode(unknown))
end

print('mesh-component: ok (hierarchy, grants, revocation, verb, audit line, addresses, attestation, refusals)')
