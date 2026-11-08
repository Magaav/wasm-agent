-- The roster is the *execution* trust basis (docs/MESH.md §9 item 2).
--
-- A mesh call reaches a target that has a verified roster, the hierarchy allows it, and the mount signs
-- an attestation for exactly that call. The last step — the node's own admission of the inner
-- `/node/call` request, `wa_node_call` — used to ask `nodeslib.verify_caller` and nothing else: the
-- operator pins a binding froze at bind time, the node's enrollment, or a *fresh* rendezvous lookup. On a
-- node whose pins do not name the caller, and with the directory unreachable, the call died there:
-- `layer=node reason=unknown_caller` (the live failure of 08/11 — a level-0 laptop calling a level-2
-- `nextcloud` that the roster had already allowed).
--
-- This file measures the accepting half of the fix against the real `lua/core/server.lua` and the real
-- `lua/core/binding.lua`; nothing is stubbed, including the enrollment module. This node is
-- deliberately unmanaged and unpinned, so `verify_caller` cannot vouch for anybody. The attestation is
-- produced by the **Rust** signer (`host.mesh_call`'s `{attest: …}`, the same `wa_mesh::attest::sign`
-- the mount calls), and `wa_mesh_admit` is the real handoff the host uses on both of its paths.
--
-- The caller here is this node's own identity, because a Lua process holds exactly one private key
-- (`host.sign`). That keeps the baseline honest in the way that matters: `verify_caller` still refuses
-- it, so anything that ran here ran on the attestation and on nothing else.
--
-- Loopback only: no rendezvous, no relay, no `wa serve`, no port, and the scratch home is the runner's.
local json = dofile("lua/vendor/json.lua")

local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function eq(actual, expected, label)
  checks = checks + 1
  assert(actual == expected, label .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end

local identity = json.decode(host.node_identity())
ok(type(identity) == "table" and identity.node_id and identity.public_key, "this node has an identity")

-- The gate for `host.mesh_call`'s attestation mode is the process flag **or** this node's own
-- `policy.json` (`mesh.enabled`) — the same statement a pushed roster writes.
local paths = dofile("lua/core/paths.lua")
ok(host.write_file(paths.config() .. "/policy.json",
  json.encode({ version = 1, components = {}, mesh = { version = 1, enabled = true } })),
  "this node is enabled by its own policy")

-- A file the target can really read, so "executed" means the capability ran and not that a reply shaped
-- like one came back.
local MARKER = "meshtrust-read-marker-6f2a"
local marker_path = paths.config() .. "/trust-marker.txt"
ok(host.write_file(marker_path, MARKER .. "\n"), "the target has a file to read")

-- ---- the real server.lua and the real binding.lua (no stubs at all) --------------------------------
dofile("lua/core/server.lua")
ok(type(wa_node_call) == "function", "server.lua defines wa_node_call")
ok(type(wa_mesh_admit) == "function" and type(wa_mesh_clear) == "function",
  "binding.lua defines the admission handoff the host uses")
local enrollment = dofile("lua/core/enrollment.lua")
eq(enrollment.managed(), false,
  "this node is unmanaged and unpinned: no operator list can vouch for a caller here")
ok(type(host.mesh_call) == "function", "this host answers host.mesh_call")

-- ---- a peer call this node verifies, and the attestation the mount would sign -----------------------
-- The "peer" is this node's own identity (the only key a Lua process holds), so the node can sign a
-- request it will verify. Every call carries a fresh nonce: Ed25519 is deterministic and the replay
-- guard refuses byte-identical bodies.
local nonce = 0
local function sign_call(capability, args)
  nonce = nonce + 1
  local body = json.encode({
    from_node_id = identity.node_id,
    to_node_id = identity.node_id,
    request_id = "trust-" .. tostring(nonce),
    capability = capability,
    args = args or {},
  })
  local ts = math.floor(host.now())
  local signed = json.decode(host.sign("call|" .. identity.node_id .. "|" .. ts .. "|" .. host.sha256(body)))
  return { body = body, ts = ts, signature = signed.signature }
end

-- The production signer: exactly what the mount calls after `authorize()` allowed the call.
local function rust_attestation(caller, verb, capability, signature)
  local raw = host.mesh_call(json.encode({
    attest = { caller = caller, verb = verb, capability = capability, signature = signature },
  }))
  local answer = json.decode(raw or "{}") or {}
  if answer.ok ~= true then return nil, answer.error or "attest_failed" end
  return answer.attestation
end

-- The same message built by hand, which is how an *old* or *differently bound* attestation is made here
-- (the Rust signer always stamps the current second). Only this node can sign it, which is the point.
local function lua_attestation(caller, verb, capability, signature, ts)
  local material = table.concat({ caller, verb, capability, tostring(signature or "") }, "|")
  local message = "mesh-allow|" .. identity.node_id .. "|" .. tostring(ts) .. "|" .. host.sha256(material)
  return { caller = caller, verb = verb, capability = capability, ts = ts,
    signature = json.decode(host.sign(message)).signature }
end

-- The one-shot admission this node's mount hands over for the call it is about to run, through the real
-- `binding.lua` function the host calls (`serve.rs`'s `mesh_admit_in_lua`, and `M.tick`'s relay path).
local function admit(capability, opts)
  opts = opts or {}
  local answer = json.decode(wa_mesh_admit(json.encode({
    node_id = opts.caller or identity.node_id,
    public_key = opts.public_key or identity.public_key,
    capability = opts.capability or capability,
    request_id = "mesh-" .. tostring(nonce),
    name = opts.name or "peer",
    level = opts.level,
  })) or "{}")
  assert(answer.ok == true, "the host can hand one roster admission over")
end

-- One call, exactly as a host would make it: an optional admission, an optional sixth argument.
-- Answers the inner reply (the capability's own result) and the outer envelope.
local function present(call, attestation, opts)
  opts = opts or {}
  if opts.admit ~= false then admit(opts.capability_hint or "read", opts) end
  local outer = json.decode(wa_node_call(call.body, identity.node_id, identity.public_key,
    opts.ts or call.ts, call.signature, attestation) or "{}") or {}
  if opts.admit ~= false then wa_mesh_clear() end
  return json.decode(outer.reply or "{}") or {}, outer
end

-- A refusal arrives at one of two levels: `{error = …}` when the *call* was not admitted (the trust
-- basis), `{reply = "{\"error\":…}"}` when the admitted call's capability was refused.
local function reason_of(inner, outer)
  if type(outer) == "table" and outer.error then return outer.error end
  if type(inner) == "table" and inner.error then return inner.error end
  return nil
end

-- One attempt with a fresh request of its own: the shape every real call has.
local function attempt(capability, args, opts)
  opts = opts or {}
  local call = sign_call(capability, args)
  local attestation = opts.attestation
  if attestation == nil and opts.attest ~= false then
    attestation = rust_attestation(opts.caller or identity.node_id, opts.verb or "read",
      opts.attest_capability or capability, call.signature)
    assert(attestation, "the host signed an attestation")
  end
  -- The mount's admission names the capability the caller asked for, unless a test is deliberately
  -- handing over an admission that names another one.
  opts.capability_hint = opts.capability_hint or capability
  return present(call, attestation, opts)
end

-- ---- 1. today's answer with none of it: the caller is not a pinned operator ------------------------
do
  local inner, outer = attempt("read", { path = marker_path }, { admit = false, attest = false })
  eq(reason_of(inner, outer), "unknown_caller",
    "no roster admission and no attestation: the node refuses the caller exactly as it did before")
  eq(outer.reply, nil, "an unpinned caller's refusal is not even a signed reply")
end

-- ---- 2. the attested caller executes, although nothing pins it -------------------------------------
do
  local call = sign_call("read", { path = marker_path })
  local attestation = rust_attestation(identity.node_id, "read", "read", call.signature)
  local inner, outer = present(call, attestation)
  eq(reason_of(inner, outer), nil, "the attested caller is admitted: " .. json.encode(inner))
  ok(json.encode(inner):find(MARKER, 1, true) ~= nil,
    "the `read` capability really ran and returned the file's text")
  -- The answer is the one `signed_reply` sends: this node's signature over the caller's own request
  -- signature and the reply bytes, so a relay cannot hand the caller a different result.
  ok(type(outer.reply_sig) == "string" and outer.reply_sig ~= "", "the answer carries a reply signature")
  local message = "reply|" .. identity.node_id .. "|" .. tostring(call.ts) .. "|"
    .. host.sha256(call.signature .. "\n" .. tostring(outer.reply))
  ok(host.verify(identity.public_key, message, outer.reply_sig),
    "the answer is signed over the caller's own request signature and the reply bytes")
end

-- ---- 3. a `control` capability by its control verb (the operator's `bash` case, without a shell) ----
do
  local target = paths.config() .. "/trust-written.txt"
  local inner, outer = attempt("write", { path = target, content = "written by the roster\n" },
    { verb = "control" })
  eq(reason_of(inner, outer), nil, "a control capability is admitted by the control verb: " .. json.encode(inner))
  eq(host.read_file(target), "written by the roster\n", "the write really happened on this node")
end

-- ---- 4. the window: expired proves nothing, one second inside it is a basis -----------------------
do
  local call = sign_call("read", { path = marker_path })
  local stale = lua_attestation(identity.node_id, "read", "read", call.signature, call.ts - 300)
  local inner, outer = present(call, stale)
  eq(reason_of(inner, outer), "unknown_caller", "an attestation five minutes old is refused, as today")

  -- The same request, the same bytes, stamped now: admitted. So it is the window that refused, not the
  -- shape of the message (this is also the byte-for-byte agreement between Rust's signer and the Lua
  -- verifier, measured on the accepting side).
  local fresh = lua_attestation(identity.node_id, "read", "read", call.signature, math.floor(host.now()))
  local admitted, admitted_outer = present(call, fresh)
  eq(reason_of(admitted, admitted_outer), nil, "a fresh attestation over the same bytes is a basis")
end

-- ---- 5. a forged attestation proves nothing --------------------------------------------------------
do
  local call = sign_call("read", { path = marker_path })
  local forged = rust_attestation(identity.node_id, "read", "read", call.signature)
  forged.signature = (forged.signature:sub(1, 2) == "0" and "1" or "0") .. forged.signature:sub(3)
  local inner, outer = present(call, forged)
  eq(reason_of(inner, outer), "unknown_caller", "a tampered attestation admits nothing: as today")
  eq(outer.reply, nil, "and nothing is executed on the strength of it")
end

-- ---- 6. one attestation, one request ---------------------------------------------------------------
do
  -- Replayed: the very same attestation presented twice. A fresh admission each time, so the only thing
  -- that changed is that the proof was already spent.
  local call = sign_call("read", { path = marker_path })
  local attestation = rust_attestation(identity.node_id, "read", "read", call.signature)
  local first, first_outer = present(call, attestation)
  eq(reason_of(first, first_outer), nil, "the attestation is spent on the first call")
  local second, second_outer = present(call, attestation)
  eq(reason_of(second, second_outer), "unknown_caller",
    "the same attestation presented twice is refused, as today")

  -- Bound to one request: minted over another request's signature, it admits this one not at all.
  local mine = sign_call("read", { path = marker_path })
  local other = sign_call("read", { path = marker_path })
  local bound_elsewhere = rust_attestation(identity.node_id, "read", "read", other.signature)
  local inner, outer = present(mine, bound_elsewhere)
  eq(reason_of(inner, outer), "unknown_caller", "an attestation bound to a different request admits nothing")

  -- Another caller: the message names the caller, so an attestation for someone else is not usable.
  local foreign_caller = string.rep("f", 32)
  local foreign = rust_attestation(foreign_caller, "read", "read", mine.signature)
  local wrong, wrong_outer = present(mine, foreign, {
    caller = foreign_caller,
    capability_hint = "read",
  })
  eq(reason_of(wrong, wrong_outer), "unknown_caller", "an attestation for another caller admits nothing")
end

-- ---- 7. the wrong verb, or a capability the admission did not name ---------------------------------
do
  -- The request is a `read`; the attestation says `control`. Nothing is admitted.
  local strong_call = sign_call("read", { path = marker_path })
  local strong = lua_attestation(identity.node_id, "control", "read", strong_call.signature,
    math.floor(host.now()))
  local inner, outer = present(strong_call, strong)
  eq(reason_of(inner, outer), "unknown_caller",
    "an attestation for a stronger verb does not admit a read capability")

  -- The mount admitted `read`; the request is a `write` carrying an attestation for itself.
  local write_call = sign_call("write", { path = paths.config() .. "/never.txt", content = "x" })
  local write_attestation = rust_attestation(identity.node_id, "control", "write", write_call.signature)
  local refused, refused_outer = present(write_call, write_attestation, { capability_hint = "read" })
  eq(reason_of(refused, refused_outer), "unknown_caller",
    "an attestation the admission did not name for this capability admits nothing")
  eq(host.read_file(paths.config() .. "/never.txt"), nil, "and the capability did not run")
end

-- ---- 8. the admission is one call, not a standing permission ---------------------------------------
do
  local call = sign_call("read", { path = marker_path })
  local attestation = rust_attestation(identity.node_id, "read", "read", call.signature)
  -- The host always clears the admission after the call it set; this is the `mesh off` / no-mount shape.
  local inner, outer = present(call, attestation, { admit = false })
  eq(reason_of(inner, outer), "unknown_caller",
    "with no admission in force an attestation is not a basis (nothing widens when the mount is off)")
end

-- ---- 9. the attestation does not launder the rest of the peer rules --------------------------------
do
  local call = sign_call("read", { path = marker_path })
  local attestation = rust_attestation(identity.node_id, "read", "read", call.signature)
  local inner, outer = present(call, attestation, { ts = call.ts - 300 })
  eq(reason_of(inner, outer), "bad_signature",
    "a request re-dated outside its own signature is still bad_signature, attested or not")

  -- And a replayed *request* is still a replayed request.
  local again = sign_call("read", { path = marker_path })
  local second_attestation = rust_attestation(identity.node_id, "read", "read", again.signature)
  local ran, ran_outer = present(again, second_attestation)
  eq(reason_of(ran, ran_outer), nil, "the request runs once")
  local replayed, replayed_outer = present(again, second_attestation)
  eq(reason_of(replayed, replayed_outer), "unknown_caller",
    "the same request twice is refused (the attestation was spent with it)")
end

print(string.format("mesh trust ok (%d checks)", checks))
