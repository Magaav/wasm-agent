-- The attestation the mount signs, produced by Rust and verified by the real Lua admission.
--
-- The seam docs/MESH.md §9 names has two halves: the mount signs
-- `mesh-allow|<node>|<ts>|<sha256(caller|verb|capability|<caller signature>)>` after `authorize()`
-- said allow, and `wa_node_call` admits a *managed* node's capability by the verb that attestation
-- proves instead of by its legacy name list. `scripts/test-mesh-verb-admission.lua` measures the
-- receiving half with an attestation built in Lua; this file closes the loop by asking the **Rust**
-- production function (`host.mesh_call`'s `{attest: …}` mode, the same `wa_mesh::attest::sign` the
-- mount calls) for it and handing the answer to the real `wa_node_call`.
--
-- If the two sides ever disagree about a single character of that message this fails, which is the
-- only way a typo in the signing code can be caught without a fleet.
--
-- Hermetic and model-free: the enrollment module is the one piece replaced (a managed profile needs a
-- registry service on the network to answer, and none of the rule under test lives there); the key is
-- this run's own identity in the private home the runner gave us.
local json = dofile("lua/vendor/json.lua")

local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

local identity = json.decode(host.node_identity())
ok(type(identity) == "table" and identity.node_id and identity.public_key, "this node has an identity")

-- The feature gate is the process flag **or** this node's own `policy.json` (`mesh.enabled`). This
-- write is the second, so the test needs no environment variable of its own — and it is the same
-- switch a roster pushed to a running node uses (docs/MESH.md §8, "The flag, and the persisted
-- setting").
local paths = dofile("lua/core/paths.lua")
ok(host.write_file(paths.config() .. "/policy.json",
  json.encode({ version = 1, components = {}, mesh = { version = 1, enabled = true } })),
  "this node is enabled by its own policy, not by an environment variable")

-- ---- the real server.lua, with only the enrollment replaced ----------------------------------------
local real_dofile = dofile
local audited, seen = {}, {}
local enrollment_stub = {
  managed = function() return true end,
  target = function() return true end,
  caller = function(id, key) return { node_id = id, public_key = key, role = "master", name = id } end,
  author = function(caller) return caller and caller.node_id or nil end,
  role = function() return "master" end,
  seen_before = function(id)
    if seen[id] then return true end
    seen[id] = true
    return false
  end,
  audit = function(caller, capability, state) audited[#audited + 1] = capability .. ":" .. state end,
}
dofile = function(path)
  if path == "lua/core/enrollment.lua" then return enrollment_stub end
  return real_dofile(path)
end
real_dofile("lua/core/server.lua")
dofile = real_dofile
ok(type(wa_node_call) == "function", "server.lua defines wa_node_call")
ok(type(host.mesh_call) == "function", "this host answers host.mesh_call")

-- ---- a peer call this node will verify ------------------------------------------------------------
-- The caller is this node's own identity so the test can sign what the node verifies. Every call
-- carries a fresh nonce: Ed25519 is deterministic and the replay guard refuses byte-identical bodies.
local nonce = 0
local function sign_call(capability, args)
  nonce = nonce + 1
  args = args or {}
  args.nonce = nonce
  local body = json.encode({ to_node_id = identity.node_id, capability = capability, args = args })
  local ts = math.floor(host.now())
  local signed = json.decode(host.sign("call|" .. identity.node_id .. "|" .. ts .. "|" .. host.sha256(body)))
  return body, ts, signed.signature
end

-- The production signer: exactly what the mount calls after authorize() allowed the call.
local function rust_attestation(caller, verb, capability, signature)
  local raw = host.mesh_call(json.encode({
    attest = { caller = caller, verb = verb, capability = capability, signature = signature },
  }))
  local answer = json.decode(raw or "{}") or {}
  if answer.ok ~= true then return nil, answer.error or "attest_failed", answer.detail end
  return answer.attestation
end

local function attempt(capability, verb, opts)
  opts = opts or {}
  local body, ts, signature = sign_call(capability)
  local attestation
  if opts.attest ~= false then
    local refused
    attestation, refused = rust_attestation(opts.caller or identity.node_id,
      opts.verb or verb, opts.attest_capability or capability, opts.signature or signature)
    if opts.want_refusal then return { attest_refused = refused } end
    assert(attestation, "the host signed an attestation: " .. tostring(refused))
  end
  local raw = wa_node_call(body, identity.node_id, identity.public_key, ts, signature, attestation)
  local outer = json.decode(raw) or {}
  return json.decode(outer.reply or "{}") or {}
end

local function refused(capability, verb, opts)
  return attempt(capability, verb, opts).error == "capability_not_granted"
end

-- ---- the legacy list is untouched without an attestation -------------------------------------------
ok(not refused("status", "read", { attest = false }), "a listed capability is admitted with no attestation")
ok(refused("sessions", "read", { attest = false }),
  "a capability off the legacy list is still refused when nothing attests it")

-- ---- a Rust-signed attestation admits by verb -----------------------------------------------------
ok(not refused("sessions", "read"), "a Rust-signed read attestation admits a read capability off the list")
ok(not refused("subagent", "control"), "a Rust-signed control attestation admits a control capability off the list")
ok(not refused("bash", "control"), "the case the operator named: a roster-authorized `bash` call by its control verb")
ok(not refused("some_future_tool", "call"),
  "a capability nobody classified is graded `call`, the verb that needs the strongest grant")
do
  local started = false
  for _, entry in ipairs(audited) do
    if entry == "sessions:started" then started = true end
  end
  ok(started, "the call admitted by the Rust attestation is audited like any other")
end

-- ---- nothing else widens -------------------------------------------------------------------------
ok(refused("sessions", "read", { verb = "control" }), "an attestation for a stronger verb does not admit a read capability")
ok(refused("sessions", "read", { verb = "call" }), "an attestation for a different verb does not admit a read capability")
ok(refused("subagent", "control", { attest_capability = "sessions" }),
  "an attestation for another capability does not admit this one")
ok(refused("sessions", "read", { caller = string.rep("f", 32) }),
  "an attestation for another caller does not admit this one")
do
  local _, _, other = sign_call("sessions")
  ok(refused("sessions", "read", { signature = other }),
    "an attestation bound to a different request does not admit this one")
end
do
  -- A forged attestation: the caller tampers with what the host signed.
  local body, ts, signature = sign_call("sessions")
  local attestation = rust_attestation(identity.node_id, "read", "sessions", signature)
  assert(attestation, "the host signed one")
  attestation.signature = (attestation.signature:sub(1, 2) == "0" and "1" or "0") .. attestation.signature:sub(3)
  local raw = wa_node_call(body, identity.node_id, identity.public_key, ts, signature, attestation)
  local outer = json.decode(raw) or {}
  local inner = json.decode(outer.reply or "{}") or {}
  ok(inner.error == "capability_not_granted", "a tampered Rust attestation admits nothing")
end
do
  -- The production signer refuses to sign something that is not an attestation at all.
  local answer = json.decode(host.mesh_call(json.encode({
    attest = { caller = identity.node_id, verb = "everything", capability = "bash", signature = "x" },
  })) or "{}")
  ok(answer.ok == false and answer.error == "mesh_bad_request",
    "a verb outside read/control/call is refused by the signer: " .. json.encode(answer))
end

print(string.format("mesh attestation ok (%d checks)", checks))
