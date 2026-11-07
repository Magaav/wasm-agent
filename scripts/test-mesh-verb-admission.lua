-- What a managed node admits from a verified peer, and on whose authority (docs/MESH.md sections 2,
-- 7 and 8.1).
--
-- The gate is `wa_node_call`'s managed branch. It has always admitted an inbound peer call by a list
-- of capability *names*, because a name list is all it had. This file pins the second admission the
-- mesh adds: a call the mesh's own mount authorized against a verified fleet roster and the
-- operator's grants is admitted by the *verb* the mesh decided on (`read`, `control` or `call`), and
-- that widening is reachable only with an attestation signed by this node's own key - never with a
-- name the caller chose.
--
-- Hermetic and model-free: the enrollment module is the one piece replaced (a managed profile needs a
-- registry service on the network to answer, and none of the rule under test lives there). Everything
-- else - server.lua, `verify_peer`, the signature helpers, `node_capability` - is the real code, and
-- the signing key is the node's own identity in this run's private home.
local json = dofile("lua/vendor/json.lua")

local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

local identity = json.decode(host.node_identity())
ok(type(identity) == "table" and identity.node_id and identity.public_key, "this node has an identity")

-- ---- load the real server with a stubbed enrollment ----------------------------------------------
local real_dofile = dofile
local audited = {}
local seen = {}
local enrollment_stub = {
  managed = function() return true end,
  target = function() return true end,
  caller = function(id, key) return { node_id = id, public_key = key, role = "master", name = id } end,
  author = function(caller) return caller and caller.node_id or nil end,
  role = function() return "master" end,
  -- The real one is a table in the ledger; this one is the same rule in memory, so the replay guard
  -- under test is still a replay guard.
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

-- ---- a caller the node verifies, and the attestation the mesh's mount would sign ----------------
-- The "peer" is this node's own identity, so the test can sign a request the node will verify. Every
-- call carries a fresh nonce: Ed25519 is deterministic, and the replay guard refuses a byte-identical
-- request twice.
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

-- Exactly what `rust/wa-mesh`'s mount signs after `authorize()` said allow: this node (the signer)
-- attests that it admitted this caller, by this verb, for this capability, for this one request.
local function attest(caller_id, capability, verb, request_signature, stamp)
  local material = table.concat({ caller_id, verb, capability, tostring(request_signature or "") }, "|")
  local ts = stamp or math.floor(host.now())
  local signed = json.decode(host.sign("mesh-allow|" .. identity.node_id .. "|" .. ts .. "|" .. host.sha256(material)))
  return { caller = caller_id, capability = capability, verb = verb, ts = ts, signature = signed.signature }
end

-- One inbound peer call. `opts` says what to attest and how to bend it:
--   attest            - attach an attestation at all
--   verb              - the verb the mount decided on (default: the capability's own)
--   attest_capability - the capability the attestation names (default: the one being called)
--   caller            - the caller the attestation names (default: the caller signing the call)
--   signature         - the request signature the attestation binds (default: this call's)
--   stamp             - the attestation's own timestamp
--   tamper            - corrupt the signature after signing
local function attempt(capability, verb, opts)
  opts = opts or {}
  local body, ts, signature = sign_call(capability)
  local attestation
  if opts.attest then
    attestation = attest(opts.caller or identity.node_id, opts.attest_capability or capability,
      opts.verb or verb, opts.signature or signature, opts.stamp)
    if opts.tamper then
      attestation.signature = (attestation.signature:sub(1, 2) == "0" and "1" or "0") .. attestation.signature:sub(3)
    end
  end
  local raw = wa_node_call(body, identity.node_id, identity.public_key, ts, signature, attestation)
  local outer = json.decode(raw) or {}
  local inner = json.decode(outer.reply or "{}") or {}
  return inner
end

local function refused(capability, verb, opts)
  return attempt(capability, verb, opts).error == "capability_not_granted"
end

-- ---- the legacy list is untouched ----------------------------------------------------------------
-- A name on the list is admitted with no attestation at all, exactly as before this change.
ok(not refused("status"), "a listed capability is admitted with no attestation")
ok(not refused("write"), "a listed capability with an effect is admitted with no attestation")
ok(not refused("stt"), "the speech-worker capability keeps its place on the list")
-- A name off the list is refused, and the refusal is the same word it always was.
ok(refused("sessions", "read"), "a read-shaped capability off the legacy list is still refused")
ok(refused("subagent", "control"), "a control-shaped capability off the legacy list is still refused")

-- ---- the mesh's admission, by verb ---------------------------------------------------------------
ok(not refused("sessions", "read", { attest = true }),
  "an attested read capability off the legacy list is admitted by its verb")
ok(not refused("subagent", "control", { attest = true }),
  "an attested control capability off the legacy list is admitted by its verb")
ok(not refused("some_future_tool", "call", { attest = true }),
  "a capability nobody classified is graded `call`, the verb that needs the strongest grant")
ok(not refused("read", "read", { attest = true }),
  "a listed capability with a valid attestation is admitted once, not twice")
do
  -- Every admitted call appends "started" and then its outcome; an admitted attested call is in that
  -- trail with the capability name the caller asked for.
  local started = false
  for _, entry in ipairs(audited) do
    if entry == "some_future_tool:started" then started = true end
  end
  ok(started, "an admitted attested call is audited like any other")
end

-- ---- nothing else widens -------------------------------------------------------------------------
ok(refused("sessions", "read", { attest = true, verb = "control" }),
  "an attestation for a stronger verb than the capability grades does not admit it")
ok(refused("sessions", "read", { attest = true, verb = "call" }),
  "an attestation for a different verb does not admit a read capability")
ok(refused("subagent", "control", { attest = true, attest_capability = "sessions" }),
  "an attestation for another capability does not admit this one")
ok(refused("sessions", "read", { attest = true, caller = string.rep("f", 32) }),
  "an attestation for another caller does not admit this one")
ok(refused("sessions", "read", { attest = true, stamp = math.floor(host.now()) - 3600 }),
  "a stale attestation is refused")
ok(refused("sessions", "read", { attest = true, tamper = true }),
  "a tampered attestation is refused")
-- The attestation is bound to one request: a signature minted for another call does not authorize this one.
local _, _, other_signature = sign_call("sessions")
ok(refused("sessions", "read", { attest = true, signature = other_signature }),
  "an attestation minted for a different request does not admit this one")

print("mesh admission ok (" .. checks .. " checks)")
