-- The remote-call mesh gate: one resolver, and the CLI's path follows it (docs/MESH.md).
--
-- The 07/11 failure this covers: a node whose own `policy.json` said `"mesh": {"enabled": true}` — a
-- roster pushed to a *running* node, which is the only way such a node can be turned on — still sent
-- `wa call nextcloud bash …` down the legacy path, because the client's gate read `WA_MESH` and nothing
-- else. The answer was `remote_refused: not a pinned operator`, from a node the roster would have
-- admitted.
--
-- What is exercised here, with the real `lua/core/nodes.lua` and a deterministic host:
--
--   1. the gate asks the host every time (`host.mesh_call`'s `{gate: true}`), so an answer that changes
--      under a running node is followed on the next call — no module-level cache, no restart;
--   2. the environment is not consulted behind the host's back: the runner of this test does not set
--      `WA_MESH`, and the gate follows what the host says;
--   3. `remote_call` tries the mesh first when the gate is on, and answers with the mesh's response;
--   4. a mesh *denial* is an answer: it is returned, never retried down the legacy path (a refusal must
--      not be laundered through a carrier that knows nothing of the hierarchy);
--   5. with the gate off, nothing is sent to the mesh at all and `remote_call` does exactly what it did
--      before — the legacy `/node/call` route.
--
-- Discovery is not what this test is about, so `nodes.find` returns one peer; `host.http` answers the
-- legacy route and counts it. No socket is opened, and every file lives in the scratch home the runner
-- gave this process.
local json = dofile('lua/vendor/json.lua')
local nodes = dofile('lua/core/nodes.lua')

local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function eq(got, want, label)
  checks = checks + 1
  assert(got == want, (label or '') .. ': got ' .. tostring(got) .. ', want ' .. tostring(want))
end

local identity = json.decode(host.node_identity())
ok(identity and identity.node_id, 'this process has an identity to sign a call with')

-- ---- the peer discovery would have found, so the test is only about the gate ----------------------
--  The peer is this node's own key, so the stubbed mesh answer below can be *really* signed: what
--  `remote_call` verifies is the signature, and a test that skipped it would not be testing the path.
local peer = {
  node_id = identity.node_id,
  public_key = identity.public_key,
  name = 'nextcloud',
  level = 1,
  endpoints = { '127.0.0.1:9999' },
}
nodes.find = function(selector)
  if tostring(selector) == peer.node_id or tostring(selector) == peer.name then return peer end
  return nil
end

-- ---- the host: the gate, the mesh call, and the legacy route ------------------------------------
local gate_enabled, gate_from = true, 'policy.json mesh.enabled'
local gate_asks, mesh_calls, legacy_calls = 0, 0, 0
local mesh_answer = nil -- override one answer, so the test can make the mesh deny a call

-- The peer's answer to the caller's own request, signed the way `server.lua` signs one
-- (`reply|node|ts|sha256(sig\nreply)`): the inner headers the caller sent travel in the envelope, so the
-- stub can sign over exactly the bytes `verified_reply` will check.
local function signed_body(decoded)
  local inner = {}
  for _, pair in ipairs(decoded.inner_headers or {}) do inner[pair[1]] = pair[2] end
  local reply = json.encode({ ran = tostring(decoded.capability), from = peer.name })
  local message = table.concat({ 'reply', peer.node_id, tostring(inner['X-WA-Ts']),
    host.sha256(tostring(inner['X-WA-Sig']) .. '\n' .. reply) }, '|')
  local signed = json.decode(host.sign(message))
  return json.encode({ reply = reply, reply_sig = signed.signature })
end

-- The host's own `mesh_call`, kept *before* the stub replaces it: section 6 asks the real one.
local real_mesh_call = host.mesh_call

host.mesh_call = function(request)
  local decoded = json.decode(request) or {}
  if decoded.gate then
    gate_asks = gate_asks + 1
    return json.encode({ ok = true, enabled = gate_enabled, from = gate_from })
  end
  mesh_calls = mesh_calls + 1
  if mesh_answer then return mesh_answer end
  return json.encode({
    ok = true, status = 200, transport = 'direct', verified = true,
    body = signed_body(decoded),
  })
end

local real_http = host.http
host.http = function(method, url, headers, body)
  if tostring(url):find('/node/call', 1, true) then
    legacy_calls = legacy_calls + 1
    return json.encode({ status = 200, body = json.encode({ ran = 'legacy' }) })
  end
  return real_http(method, url, headers, body)
end

-- ---- 1. the gate is on because the host says so, and it is asked every time ---------------------
--  The host is stubbed here, so this test is about the *client*: it asks, it follows the answer, and it
--  never caches one itself. Which of `WA_MESH` / `policy.json mesh.enabled` makes the host answer on is
--  `rust/wa-mesh`'s `gate` unit tests (environment, then the operator's file, then off).
eq(nodes.mesh_enabled(), true, 'the gate follows the host: one policy-only node is enough')
local asks = gate_asks
ok(asks >= 1, 'the gate asked the host')
nodes.mesh_enabled()
ok(gate_asks > asks, 'the gate asks again on the next call: a pushed roster takes effect without a restart')

-- ---- 2. with the gate on, `remote_call` tries the mesh first -----------------------------------
mesh_calls, legacy_calls = 0, 0
local ran = nodes.remote_call(peer.name, 'read', { path = 'README.md' })
eq(mesh_calls, 1, 'the mesh carried the call')
eq(legacy_calls, 0, 'and the legacy route was not also used: nothing runs twice')
eq(ran.ran, 'read', 'the mesh answer is what the caller sees')
eq(ran.from, 'nextcloud', 'and it is the answer the peer signed, not a legacy round trip')

-- ---- 3. the gate turning off is followed, and the legacy path is exactly what it was -----------
gate_enabled, gate_from = false, 'default off'
eq(nodes.mesh_enabled(), false, 'the gate follows the host back off')
mesh_calls, legacy_calls = 0, 0
nodes.remote_call(peer.name, 'read', { path = 'README.md' })
eq(mesh_calls, 0, 'with the gate off nothing is sent to the mesh')
eq(legacy_calls, 1, 'the legacy /node/call route is what runs, unchanged')

-- ---- 4. a mesh denial is an answer, not a transport failure ------------------------------------
gate_enabled, gate_from = true, 'policy.json mesh.enabled'
mesh_answer = json.encode({ ok = false, error = 'mesh_denied', reason = 'hierarchy_denied',
  verified = true, node = peer.name, node_id = peer.node_id, level = peer.level, fallback = nil })
mesh_calls, legacy_calls = 0, 0
local denied = nodes.remote_call(peer.name, 'bash', { command = 'uptime' })
eq(mesh_calls, 1, 'the mesh decided')
eq(legacy_calls, 0, 'and a denial is never retried on a path with weaker rules')
eq(denied.error, 'mesh_denied', 'the denial is reported as the mesh decision it is')
eq(denied.reason, 'hierarchy_denied', 'with the hierarchy\'s own reason')
eq(denied.verified, true, 'and it counts, unlike an unsigned refusal')
mesh_answer = nil

-- ---- 5. an unreachable mesh falls back, which is the one case that may ---------------------------
--  `mesh_unreachable` means nobody decided: the legacy path is then correct, and is what keeps an
--  older peer reachable for a node in a fleet.
mesh_answer = json.encode({ ok = false, error = 'mesh_unreachable', reason = 'no_address', fallback = 'relay' })
mesh_calls, legacy_calls = 0, 0
nodes.remote_call(peer.name, 'read', { path = 'README.md' })
eq(mesh_calls, 1, 'the mesh was tried')
eq(legacy_calls, 1, 'and an unreachable peer falls back to the legacy route, as before')
mesh_answer = nil

-- ---- 6. the real host, when the binary running this test has the gate mode ----------------------
--  Everything above stubs the host, so this test does not depend on *which* binary runs it. This last
--  section asks the real `host.mesh_call`: with the scratch home's own `policy.json` saying the mesh is
--  on and no `WA_MESH` anywhere, the gate must answer on. A binary built before the `{gate: true}` mode
--  existed cannot answer, and that is reported as SKIPPED — never as a check that passed.
local skipped = 0
local function real_gate()
  if type(real_mesh_call) ~= 'function' then return nil end
  local raw = real_mesh_call(json.encode({ gate = true }))
  if type(raw) ~= 'string' then return nil end
  local decoded = json.decode(raw)
  if type(decoded) ~= 'table' or type(decoded.enabled) ~= 'boolean' then return nil end
  return decoded
end
if real_gate() == nil then
  skipped = skipped + 1
  print('mesh gate: the real host SKIPPED (this binary has no {gate: true} mode)')else
  local paths = dofile('lua/core/paths.lua')
  local policy = paths.config() .. '/policy.json'
  ok(host.write_file(policy,
    '{"version":1,"components":{},"mesh":{"version":1,"enabled":true}}'),
    'the scratch home can hold the operator\'s policy')
  local answer = real_gate()
  eq(answer.enabled, true, 'the real host turns the mesh on from policy.json alone')
  eq(answer.from, 'policy.json mesh.enabled', 'and says where that came from')
  ok(host.write_file(policy, '{"version":1,"components":{}}'), 'the policy can be turned off again')
  eq(real_gate().enabled, false, 'and the next ask follows it: the answer is not cached forever')
  eq(real_gate().from, 'default off', 'with nothing written, the mesh is off by default')
end

print(string.format('mesh gate ok (%d checks, %d skipped)', checks, skipped))
