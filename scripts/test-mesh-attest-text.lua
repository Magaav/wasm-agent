-- THE ATTESTATION THE HOST ACTUALLY HANDS OVER (mission run-images-two-node, the fact item 1 needs).
--
-- docs/MESH.md section 9 item 2 is the second trust basis a peer call has: after the mount's roster
-- allowed this caller, capability and verb, the mount signs 'mesh-allow|...' and the node's own
-- admission (wa_node_call) admits the call by that verb instead of by the legacy name list.
--
-- scripts/test-mesh-attest.lua measures that with the attestation as a LUA TABLE, because that is what
-- it decoded itself. On the real path the host hands every argument over with lua_pushlstring
-- (rust/wa-host-support/src/lua.rs, call_string), so what wa_node_call receives is the JSON TEXT of
-- that proof - and until this row's change the first line of mesh_caller refused anything that is not a
-- table, so the basis never applied on a real call: a roster-authorized peer the rendezvous had not
-- seen was refused unknown_caller (measured on a scratch pair, 24/11).
--
-- What this row pins, with this node's own identity and the Rust signer:
--   1. the TEXT shape is the same proof as the table (managed node: a capability off the legacy list is
--      admitted by its verb);
--   2. and on the UNMANAGED path it is the whole answer: the caller is admitted although
--      nodeslib.verify_caller (the rendezvous, the pins) would refuse it unknown_caller;
--   3. nothing widens: a tampered text still admits nothing, an unreadable one admits nothing, and a
--      call with no attestation at all keeps today's refusal.
--
-- Hermetic: its own scratch home (the runner's), its own key, no rendezvous, no relay, no peer, no
-- network. The one piece replaced in the managed half is lua/core/enrollment.lua (a managed profile
-- needs a registry service to answer, and none of the rule under test lives there).
if not host then error("this row runs under the node (WA_SCRIPT), not plain Lua") end
local json = dofile("lua/vendor/json.lua")
local guard = dofile("scripts/lib/test-home-guard.lua")
local reason = guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if reason then error("this row refuses to run (" .. reason .. ")") end

-- No fleet, by construction: the node cannot ask a rendezvous even if the operator's shell names one.
local real_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_RENDEZVOUS" or key == "WASM_AGENT_RELAY" or key == "WASM_AGENT_MESH" then return "" end
  return real_getenv(key)
end
host.http = function() error("network forbidden in this row") end

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end

local identity = json.decode(host.node_identity()) or {}
ok(type(identity.node_id) == "string" and #identity.node_id == 32, "this node has an identity")
local paths = dofile("lua/core/paths.lua")
ok(host.write_file(paths.config() .. "/policy.json",
  json.encode({ version = 1, components = {}, mesh = { version = 1, enabled = true } })),
  "this node is enabled by its own policy, not by an environment variable")
ok(type(host.mesh_call) == "function", "this host answers host.mesh_call")

local real_dofile = dofile
local seen, audited = {}, {}
local enrollment_stub = {
  managed = function() return true end,
  target = function() return true end,
  caller = function(id, key) return { node_id = id, public_key = key, role = "master", name = id } end,
  author = function(caller) return caller and caller.node_id or nil end,
  role = function() return "master" end,
  seen_before = function(id) if seen[id] then return true end seen[id] = true return false end,
  audit = function(caller, capability, state) audited[#audited + 1] = capability .. ":" .. state end,
}

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
    attest = { caller = caller, verb = verb, capability = capability, signature = signature } }))
  local answer = json.decode(raw or "{}") or {}
  if answer.ok ~= true then return nil, answer.error or "attest_failed" end
  return answer.attestation
end

-- What the node answered: an admitted call is sealed in {reply = ...}; a call refused at admission
-- answers the refusal itself (there is nothing to seal).
local function answered(raw)
  local outer = json.decode(raw or "{}") or {}
  local inner = outer.reply and json.decode(outer.reply) or outer
  if type(inner) ~= "table" then inner = {} end
  return inner
end

-- THE SHAPE THE HOST HANDS OVER: the JSON text of that proof, not the table.
local function as_text(attestation) return json.encode(attestation) end

local function admit(capability)
  return json.decode(wa_mesh_admit(json.encode({
    node_id = identity.node_id, public_key = identity.public_key, capability = capability,
    request_id = "attest-text", name = "peer", level = 1 }))).ok == true
end

local function attempt(capability, verb, shape)
  local body, ts, signature = sign_call(capability)
  local attestation = rust_attestation(identity.node_id, verb or "read", capability, signature)
  ok(attestation ~= nil, "the host signed an attestation for " .. capability)
  ok(admit(capability), "the mount's one-shot admission is handed over")
  local handed = shape == "text" and as_text(attestation) or attestation
  local raw = wa_node_call(body, identity.node_id, identity.public_key, ts, signature, handed)
  wa_mesh_clear()
  return answered(raw)
end

-- ---- 1. the managed half: the TEXT shape widens the legacy list exactly like the table ----------
dofile = function(path)
  if path == "lua/core/enrollment.lua" then return enrollment_stub end
  return real_dofile(path)
end
real_dofile("lua/core/server.lua")
dofile = real_dofile
ok(type(wa_node_call) == "function", "server.lua defines wa_node_call")

local by_text = attempt("sessions", "read", "text")
ok(by_text.error ~= "capability_not_granted",
  "a managed node admits a capability off the list when the attestation arrives as text: " .. json.encode(by_text))
local by_table = attempt("sessions", "read", "table")
ok(by_table.error ~= "capability_not_granted", "and the table says the same: " .. json.encode(by_table))

do
  -- A tampered text admits nothing: the shape is accepted, never the claim.
  local body, ts, signature = sign_call("sessions")
  local attestation = rust_attestation(identity.node_id, "read", "sessions", signature)
  attestation.signature = (attestation.signature:sub(1, 2) == "0" and "1" or "0") .. attestation.signature:sub(3)
  ok(admit("sessions"), "the mount's admission is handed over for the tampered case")
  local inner = answered(wa_node_call(body, identity.node_id, identity.public_key, ts, signature,
    as_text(attestation)))
  wa_mesh_clear()
  ok(inner.error == "capability_not_granted", "a tampered attestation in TEXT is refused like a tampered table")
end
do
  -- A text that is not JSON at all is left alone: nothing crashes, nothing widens.
  local body, ts, signature = sign_call("sessions")
  ok(admit("sessions"), "the mount's admission is handed over for the unreadable case")
  local inner = answered(wa_node_call(body, identity.node_id, identity.public_key, ts, signature,
    "not json at all"))
  wa_mesh_clear()
  ok(inner.error == "capability_not_granted", "an unreadable attestation admits nothing")
end

-- ---- 2. the unmanaged half: the text is the whole basis ---------------------------------------
-- The real enrollment now: this node is not managed, and there is no rendezvous to vouch for the
-- caller, so nodeslib.verify_caller answers nothing and the call would be unknown_caller.
for _, name in ipairs({ "lua/core/server.lua", "lua/core/binding.lua", "lua/core/nodes.lua",
    "lua/core/enrollment.lua" }) do
  package.loaded[name] = nil
end
real_dofile("lua/core/server.lua")
local nodes = real_dofile("lua/core/nodes.lua")
ok(nodes.verify_caller(identity.node_id, identity.public_key, { fresh = true }) == nil,
  "nothing on this node vouches for the caller: the rendezvous is empty, as a scratch pair's is")

local with_text = attempt("read", "read", "text")
ok(with_text.error ~= "unknown_caller",
  "the text attestation is the caller's basis on an unmanaged node: " .. json.encode(with_text))

local body, ts, signature = sign_call("read")
local unattested = answered(wa_node_call(body, identity.node_id, identity.public_key, ts, signature, nil))
ok(unattested.error == "unknown_caller",
  "and with no attestation at all the same call is refused exactly as before: " .. json.encode(unattested))

print(string.format("mesh attestation text ok (%d checks)", checks))
