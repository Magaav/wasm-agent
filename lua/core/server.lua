-- Server entry for `wa serve`: one agent per user behind the web UI.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local changeset = dofile("lua/core/changeset.lua")
local provider = dofile("lua/core/provider.lua")
local windowlib = dofile("lua/core/model_window.lua")
local agentlib = dofile("lua/core/agent.lua")
local users = dofile("lua/core/users.lua")
local toolslib = dofile("lua/core/tools.lua")
local nodeslib = dofile("lua/core/nodes.lua")
local enrollment = dofile("lua/core/enrollment.lua")
local skillslib = dofile("lua/core/skills.lua")
-- Errors travel to a browser, a log and a test harness; mask secrets as they
-- leave the server rather than trusting every future call site.
local redact = dofile("lua/core/redact.lua")
local telemetry = dofile("lua/core/telemetry.lua")
local updater = dofile("lua/core/update.lua")

memory.setup()
local agent

local function emit(event)
  host.stream(json.encode(event))
end

-- Rebuild the agent when the signed-in user, their role, or the target node
-- changes. The session is a resumable thread keyed by (user, node).
-- The role a *local* run actually gets.
--
-- On a guest node every local session is a guest, whatever the session's user says: the node
-- carries out a master's wish, it does not have a master's initiative of its own. Without this
-- the default user on a guest node is `master` (users.lua's fallback), so anyone who could
-- reach the port had a master agent with its tools - and, since those tools include a shell and
-- file writes, this machine. The peer path deliberately does not come through here: a signed
-- call from a verified master *is* a master's wish, which is the one way work originates on a
-- guest.
local function effective_role(user)
  if not nodeslib.is_master() then return "guest" end
  return user.role
end

-- The conversation a turn belongs to, when the client names one.
--
-- Without a name the node reuses the newest open session for (user, node) - so a
-- window can neither *start* a thread nor return to one: every turn from every
-- window lands in whatever was written to last, and that one thread grows without
-- end. The name is the client's only way to say "this one", and it is checked here
-- because this is the only place that knows who is asking. A thread belongs to its
-- author: a caller who is not a master must not address someone else's thread, and
-- must be refused rather than quietly served it.
local function agent_for(session, node, thread)
  local user = users.current(session)
  local role = effective_role(user)
  node = node or ""
  local want = thread or ""
  if want ~= "" then
    local existing = memory.session(want)
    if existing and existing.user_id ~= user.id and not users.is_master(role) then
      return nil, "forbidden_thread"
    end
  end
  -- The *requested* name is part of the cache key, not the resolved session id: an
  -- unnamed turn resolves to a real session, and comparing that against "" would
  -- rebuild the agent on every turn.
  if not agent or agent.user ~= user.id or agent.role ~= role or agent.node ~= node
     or agent.thread ~= want then
    if agent then agent:close() end
    agent = agentlib.new(want ~= "" and want or nil, emit, role, user.id, node,
                         { start_if_missing = want ~= "" })
    agent.thread = want
  end
  return agent
end

-- Exported so a test can ask which thread a turn would land in without a model:
-- building the agent touches the ledger and never the provider. It is a global like
-- every other handler in this file, and reachable only by name - the HTTP routes are
-- matched in Rust, so nothing on the wire can reach it.
wa_agent_for = agent_for

-- Is this selector a remote peer?
local function remote_target(node)
  if not node or node == "" or node == "local" then return nil end
  local target = nodeslib.find(node)
  if target and not target.local_node then return target end
  return nil
end

-- A /chat body may be plain text (the historical shape, still used by the CLI,
-- the ledger and peer relays) or a JSON object {"text":..., "images":[...]} when
-- the UI has pictures to send. The distinction is made here rather than in the
-- Rust HTTP layer so that the text path keeps working unchanged.
--
-- Returns text, images, or an error string when a named image cannot be stored.
local function parse_run_body(body)
  local raw = body or ""
  if raw:sub(1, 1) ~= "{" then return raw, {} end
  local ok, decoded = pcall(json.decode, raw)
  -- A body is structured when it carries something a plain string cannot: pictures,
  -- or the name of the conversation it belongs to. A body that is *only* text stays
  -- text even when it happens to parse as JSON, so a message someone typed as
  -- {"text":"hi"} still arrives verbatim rather than being silently reinterpreted.
  if not ok or type(decoded) ~= "table"
     or (decoded.images == nil and type(decoded.thread) ~= "string") then
    return raw, {}
  end
  local images = {}
  for _, entry in ipairs(decoded.images or {}) do
    local reference, problem = memory.store_image(entry)
    if not reference then return nil, nil, problem end
    images[#images + 1] = reference
  end
  local thread = decoded.thread
  if thread == "" then thread = nil end
  return tostring(decoded.text or ""), images, nil, thread
end

-- Exported for the same reason as `wa_agent_for`: what a body *means* is the one thing
-- a caller cannot see, and getting it wrong shows the model a different message than
-- the one that was typed. Text stays text; only pictures and a thread name make a body
-- structured.
wa_parse_run_body = parse_run_body

-- The authoritative pre-admission resolution for a run.
--
-- Admission happens in Rust, but *who* is asking and *which conversation* the run writes are decisions
-- only Lua can make: the credential is a DB-backed token, and a named thread belongs to its author.
-- Resolving here, before any worker is reserved, means the scheduler owns the real conversation (not the
-- credential, and not an empty key), a foreign thread is refused before a slot is taken, and an invalid
-- nonempty credential never reaches a run as the default user.
--
-- Returns JSON:
--   {"ok":true,"user":{...},"role":...,"conversation":<id>,"remote":<bool>}
--   {"error":"invalid_session"|"unknown_user"|"forbidden_thread"}
--
-- The body `thread` is untrusted, but it is only a scheduling key here: authority is still decided by
-- `agent_for` at run time, and this resolver refuses a thread the caller does not own before that.
function wa_admission(session, node, body)
  local user, problem = users.resolve(session)
  if not user then return json.encode({ error = problem or "invalid_session" }) end
  local role = effective_role(user)
  node = node or ""
  local thread = ""
  local raw = body or ""
  if raw:sub(1, 1) == "{" then
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == "table" and type(decoded.thread) == "string" then thread = decoded.thread end
  end
  -- A peer target runs on the peer; the local node owns no local conversation for it and creating a
  -- local session would be a phantom. The thread the caller named still travels so the peer can order it.
  if remote_target(node) then
    return json.encode({ ok = true, user = users.public(user), role = role, conversation = thread, remote = true })
  end
  if thread ~= "" then
    local existing = memory.session(thread)
    if existing and existing.user_id ~= user.id and not users.is_master(role) then
      return json.encode({ error = "forbidden_thread" })
    end
    return json.encode({ ok = true, user = users.public(user), role = role, conversation = thread, remote = false })
  end
  -- No thread: the run resumes the newest open conversation for (user, node), exactly as `agent_for`
  -- will. Returning the real id is what lets the scheduler enforce affinity; without it the key would be
  -- empty and two unnamed runs could write one transcript.
  local chosen = memory.ensure_session(user.id, node, "chat")
  return json.encode({ ok = true, user = users.public(user), role = role, conversation = chosen, remote = false })
end

-- Identity only, for a control route that is owner-scoped but must not be admitted as a run and must
-- not create a conversation. Used by `POST /runs` (status/cancel). Invalid credentials are an error,
-- never the default user.
function wa_identity(session)
  local user, problem = users.resolve(session)
  if not user then return json.encode({ error = problem or "invalid_session" }) end
  return json.encode({ ok = true, user = users.public(user), role = effective_role(user) })
end

function wa_reply(text, session, node)
  local prompt, images, problem, thread = parse_run_body(text)
  if problem then return json.encode({ error = redact.text(problem) }) end
  if remote_target(node) then
    local result = nodeslib.remote_call(node, "chat", { text = prompt or "" })
    if result and result.error then return json.encode({ error = redact.text(tostring(result.error)) }) end
    return json.encode({ reply = result and result.reply or "" })
  end
  local bot, refusal = agent_for(session, node, thread)
  if not bot then return json.encode({ error = refusal }) end
  local ok, reply = pcall(bot.run, bot, prompt or "", images)
  if not ok then return json.encode({ error = redact.text(tostring(reply)) }) end
  return json.encode({ reply = reply })
end

-- Streaming turn: events are pushed to the SSE client as the agent runs.
-- When a peer is selected, its stream is relayed here unchanged.
function wa_reply_stream(text, session, node)
  local prompt, images, problem, thread = parse_run_body(text)
  if problem then
    emit({ type = "error", error = redact.text(problem) })
    return ""
  end
  if remote_target(node) then
    local result = nodeslib.remote_chat(node, prompt or "")
    if result and result.error then emit({ type = "error", error = redact.text(tostring(result.error)) }) end
    return ""
  end
  local bot, refusal = agent_for(session, node, thread)
  if not bot then
    emit({ type = "error", error = refusal })
    return ""
  end
  local ok, reply = pcall(bot.run, bot, prompt or "", images)
  if not ok then emit({ type = "error", error = redact.text(tostring(reply)) }) end
  return ""
end

-- ---- accounts ------------------------------------------------------------
local function tool_names(role)
  local names = {}
  for _, schema in ipairs(toolslib.all(role)) do names[#names + 1] = schema["function"].name end
  return names
end

function wa_me(session)
  local user = users.current(session)
  -- What this caller may actually do here, which on a guest node is the guest tier even though
  -- the session resolves to the master user.
  local role = effective_role(user)
  return json.encode({
    user = users.public(user),
    role = role,
    tools = tool_names(role),
  })
end

function wa_login(id, session)
  local new_session, user = users.login(id or "")
  if not new_session then return json.encode({ error = "unknown_user" }) end
  return json.encode({ session = new_session, user = users.public(user) })
end

function wa_logout(session)
  users.logout(session or "")
  local user = users.current(nil)
  return json.encode({ ok = true, user = users.public(user) })
end

-- ---- UI shell + spells (master only) -------------------------------------
local function require_master(session)
  local user = users.current(session)
  -- The effective role, not the session's: on a guest node this is `guest`, so these routes
  -- refuse instead of handing a shell to whoever asked.
  if not users.is_master(effective_role(user)) then return nil, user end
  return user
end

function wa_jobs(body, session)
  if not require_master(session) then return json.encode({error="forbidden"}) end
  local ok, args = pcall(json.decode, body or "{}")
  if not ok or type(args) ~= "table" then return json.encode({error="invalid_job_request"}) end
  local action = args.action or "list"
  if action ~= "list" and action ~= "history" and action ~= "enable" and action ~= "disable" then
    return json.encode({error="invalid_job_action"})
  end
  return host.jobs(action, json.encode(args))
end

function wa_operation(body, session)
  local user = require_master(session)
  if not user then return json.encode({error="forbidden"}) end
  local ok, args = pcall(json.decode, body or "{}")
  if not ok or type(args) ~= "table" then return json.encode({error="invalid_operation_request"}) end
  -- Starting arbitrary work is a tool capability, not an engine read/control endpoint.
  if args.action == "start" then return json.encode({error="start_requires_tool"}) end
  if args.action == "await" then return json.encode({error="await_requires_tool; use bounded wait on the control route"}) end
  args.owner = user.id
  return host.operation(args.action or "list", json.encode(args))
end

function wa_shell(command, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  if not command or command == "" then return json.encode({ error = "command_required" }) end
  return json.encode(toolslib.dispatch(memory, "shell", { command = command }, user.role))
end

-- Every skill this node can see, and what is true of each: where it came from, whether its
-- description is in the model's context, and whether its body can actually be loaded on demand.
-- Reading it changes nothing - nothing here is in context, and no skill is loaded by looking.
function wa_skills(session)
  local user = users.current(session)
  return json.encode(skillslib.report(effective_role(user)))
end

function wa_spells(session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  return json.encode(toolslib.dispatch(memory, "spell_list", {}, user.role))
end

function wa_spell_run(payload, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  -- Body is either a bare spell name or {"name":..., "params":{...}}.
  local name, params = payload, nil
  if type(payload) == "string" and payload:sub(1, 1) == "{" then
    local ok, decoded = pcall(json.decode, payload)
    if ok and type(decoded) == "table" then
      name, params = decoded.name, decoded.params
    end
  end
  return json.encode(toolslib.dispatch(memory, "spell_run", { name = name, params = params }, user.role))
end

-- Export a spell as a portable plan for the sentinel, which is the only process that can run a plan
-- about this node: the turn asking for the export dies with the node it changes.
function wa_spell_export(payload, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  local ok, request = pcall(json.decode, payload)
  if not ok or type(request) ~= "table" then return json.encode({ error = "bad_request" }) end
  return json.encode(toolslib.dispatch(memory, "spell_export", {
    name = request.name, params = request.params, binary = request.binary, path = request.path,
  }, user.role))
end

-- ---- update ---------------------------------------------------------------
-- `/update` in the composer: install the newest build of this node's own tree.
--
-- The node cannot replace itself - the stop is the last command a run executes - so this does not
-- install anything. It reports what it runs, what its tree holds, and writes one *request* for the
-- sentinel, which performs it when the node is idle. `lua/core/update.lua` holds the decision and
-- the wording; a refusal here is an answer, not a failure to answer.
function wa_update(payload, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  local request = {}
  local ok, decoded = pcall(json.decode, payload or "{}")
  if ok and type(decoded) == "table" then request = decoded end
  local report = updater.run({ reason = request.reason })
  return json.encode(report)
end

-- ---- nodes ---------------------------------------------------------------
function wa_nodes(session)
  local user = users.current(session)
  local role = users.normalize(user.role)
  local link = (host.client_status and json.decode(host.client_status())) or { connected = false }
  local list = nodeslib.list()
  -- The local client (the desktop running the window) sits next to the host.
  -- Its state is reported as three separate facts because it has three separate
  -- remedies: `online` is whether the window is polling, `bridge.health` is
  -- whether the bridge answers its own probe, `busy` is what it is doing now.
  -- Collapsing them cost one run: a wedged bridge read as "start wa ui", which
  -- was both wrong and a way to end up with two windows on one bridge.
  table.insert(list, math.min(2, #list + 1), {
    id = "client", node_id = "client", name = "client", kind = "client", role = role,
    online = link.connected and true or false,
    last_seen_secs = link.last_seen_secs,
    bridge = link.bridge,
    busy = link.busy,
    browser = (link.client or {}).chrome,
    local_node = true,
    capabilities = { "screenshot", "frame", "click", "move", "type", "key", "shell", "cdp" },
  })
  return json.encode({
    role = role,
    binding = role == "master" and "master:master" or "master:guest",
    node_id = (nodeslib.identity() or {}).node_id,
    nodes = list,
  })
end

-- Accept a signed capability call from a peer (see nodes.lua for the caller).
-- Signature-only check for one action. Split out so the chat receiver can probe the legacy action
-- without touching the rendezvous, the replay record, or the role checks.
local function signature_matches(public_key, action, from, ts, body, signature)
  local parts = { action, from, tostring(ts) }
  if type(body) == "string" then parts[#parts + 1] = host.sha256(body) end
  return host.verify(public_key or "", table.concat(parts, "|"), signature or "")
end

-- A peer must be a rendezvous-known master with a valid, fresh signature.
local function verify_peer(from, public_key, ts, signature, action, body)
  if not from or from == "" then return nil, "bad_request" end
  local stamp = math.floor(tonumber(ts) or 0)
  -- The signed message includes the hash of the body, so a valid signature covers *what* was
  -- asked for and not only that something was. The signature itself arrives in the headers; the
  -- body is hashed exactly as received.
  if not signature_matches(public_key, action, from, stamp, body, signature) then return nil, "bad_signature" end
  if math.abs(host.now() - stamp) > 120 then return nil, "stale_request" end
  -- Fresh from the rendezvous, not from the local cache: a peer that has been removed there
  -- must stop being welcome here at once, and if the rendezvous cannot be reached the call is
  -- refused rather than allowed on the strength of a list nobody currently vouches for. This is
  -- the answer to "a guest can fake a master call": it would have to hold the master's private
  -- key *and* still be enrolled for that node id.
  local caller = nodeslib.verify_caller(from, public_key, { fresh = true })
  if not caller then return nil, "unknown_caller" end
  if users.normalize(caller.role) ~= "master" then return nil, "forbidden_role" end
  -- Recorded only after every check has passed, so a forged request cannot burn the id of a
  -- real one. Two minutes is the freshness window; the record is kept a little longer than
  -- that so a request cannot be replayed at the edge of its own validity.
  local id = table.concat({ from, action, tostring(stamp), tostring(signature) }, "|")
  if nodeslib.seen_before(id) then return nil, "replayed_request" end
  return caller
end

-- `/node/chat` is signed under the `chat-v2` domain. The version is in the signed message, so a new
-- request cannot execute on an old receiver (which only knows `chat`): the old verifier reconstructs
-- `chat|...`, the signature is `chat-v2|...`, and it refuses `bad_signature`. The reverse is refused
-- here with `legacy_peer_protocol`. Both directions fail closed; nothing falls back to running the
-- body as text.
local function verify_peer_chat(from, public_key, ts, signature, body)
  if not from or from == "" then return nil, "bad_request" end
  local stamp = math.floor(tonumber(ts) or 0)
  if not signature_matches(public_key, "chat-v2", from, stamp, body, signature) then
    if signature_matches(public_key, "chat", from, stamp, body, signature) then
      return nil, "legacy_peer_protocol"
    end
    return nil, "bad_signature"
  end
  if math.abs(host.now() - stamp) > 120 then return nil, "stale_request" end
  local caller = nodeslib.verify_caller(from, public_key, { fresh = true })
  if not caller then return nil, "unknown_caller" end
  if users.normalize(caller.role) ~= "master" then return nil, "forbidden_role" end
  local id = table.concat({ from, "chat-v2", tostring(stamp), tostring(signature) }, "|")
  if nodeslib.seen_before(id) then return nil, "replayed_request" end
  return caller
end

-- The `/node/chat` body is an envelope that names the intended target node inside the signed bytes.
-- The signature already covers the body, so `to_node_id` is authenticated; checking it against this
-- node's own id is what stops a relay (or a network attacker) from redirecting a valid chat to
-- another node or endpoint. A legacy plain-text body cannot be bound this way, so it is refused
-- with a visible migration error rather than run unbound.
local function parse_chat_envelope(body)
  local raw = body or ""
  if raw:sub(1, 1) ~= "{" then return nil, "legacy_peer_protocol" end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" then return nil, "legacy_peer_protocol" end
  local target = decoded.to_node_id
  if type(target) ~= "string" or target == "" then return nil, "peer_target_unbound" end
  local self_id = (nodeslib.identity() or {}).node_id or ""
  if target ~= self_id then return nil, "wrong_target" end
  return { text = tostring(decoded.text or "") }
end

-- Verify a peer's signature ONCE, at admission, and return the verified author so the run can use
-- it without verifying again. A second verification of the same signed request is refused as a
-- replay (`verify_peer` records the request id), so the run half must not re-check.
--
-- The target check runs here, before admission, so a redirected chat never creates a conversation,
-- never reaches a worker, and never reaches the model.
function wa_verify_peer(from, public_key, ts, signature, body)
  local caller, problem = verify_peer_chat(from, public_key, ts, signature, body or "")
  if not caller then return json.encode({ error = problem or "bad_signature" }) end
  local envelope, envelope_problem = parse_chat_envelope(body)
  if not envelope then return json.encode({ error = envelope_problem }) end
  return json.encode({ ok = true, node_id = caller.node_id, role = caller.role, name = caller.name or "" })
end

-- A turn requested by a peer runs as the caller, not as this node.
--
-- The master who asked is the author of the work; this node is only where it happens. A guest
-- node therefore files a master's call under the master's name - which is what proxying a
-- master's wish means - instead of inventing a user called "node" and taking the credit for
-- work it did not originate. `verify_peer` has already refused a caller whose node is not a
-- master, so this path cannot be used by one guest to command another.
local function node_agent(caller)
  local author = nodeslib.author_of(caller)
  if not author then return nil, "forbidden_role" end
  -- Deliberately not cached: `memory.ensure_session` reuses the open session for this
  -- (author, node) pair, so a fresh agent per call still lands in the same thread.
  return agentlib.new(nil, emit, "master", author, nodeslib.node_name())
end

-- Capabilities a peer may invoke, in addition to the normal tools. `caller` is the peer that
-- asked: its master is the author of whatever this does.
local function node_capability(capability, args, caller)
  args = args or {}
  local author = nodeslib.author_of(caller)
  if not author then return { error = "forbidden_role" } end
  if capability == "set_role" then
    if not enrollment.managed() then return { error = "not_managed" } end
    return enrollment.set_role(args.role)
  elseif capability == "status" then
    if enrollment.managed() then return enrollment.status() end
    return json.decode(wa_model("", ""))
  elseif capability == "set_provider" then
    provider.set_provider(args.id or "")
    return json.decode(wa_model("", ""))
  elseif capability == "set_model" then
    provider.set_model(args.name or "")
    return json.decode(wa_model("", ""))
  elseif capability == "chat" then
    local bot, agent_problem = node_agent(caller)
    if not bot then return { error = agent_problem } end
    local ok, reply = pcall(bot.run, bot, args.text or "")
    if not ok then return { error = tostring(reply) } end
    return { reply = reply }
  end
  -- The caller's role, not a hard-coded one: `verify_peer` proved it is a master, and passing
  -- the proof through means a future caller that is not a master cannot inherit these tools by
  -- accident - it would have to be granted, not merely un-refused.
  return toolslib.dispatch(memory, capability, args, users.normalize(caller.role), {
    user_id = author,
    node_id = nodeslib.node_name(),
  })
end

function wa_node_call(payload, from, public_key, ts, signature)
  local ok, request = pcall(json.decode, payload)
  if not ok or type(request) ~= "table" then return json.encode({ error = "bad_request" }) end
  local capability = request.capability or ""
  if capability == "" then return json.encode({ error = "bad_request" }) end
  if capability == "remote" then return json.encode({ error = "remote_cannot_recurse" }) end
  local caller, problem = verify_peer(from, public_key, ts, signature, "call", payload)
  if problem then return json.encode({ error = problem }) end
  if enrollment.managed() then
    if not enrollment.target(request) then return json.encode({ error = "wrong_target" }) end
    local allowed = { status=true, set_role=true, read=true, write=true, edit=true,
      ls=true, grep=true, bash=true, shell=true, client=true }
    if not allowed[capability] then return json.encode({ error = "capability_not_granted" }) end
    enrollment.audit(caller, capability, "started")
    local ran, result = pcall(node_capability, capability, request.args, caller)
    enrollment.audit(caller, capability, ran and not result.error and "completed" or "failed")
    if not ran then return json.encode({ error = tostring(result) }) end
    return json.encode(result)
  end
  return json.encode(node_capability(capability, request.args, caller))
end

-- Streaming turn requested by a peer (/node/chat): events go to that stream.
function wa_node_chat(from, public_key, ts, signature, body)
  if enrollment.managed() then
    emit({ type = "error", error = "managed_guest_uses_operator_model" })
    return ""
  end
  local caller, problem = verify_peer_chat(from, public_key, ts, signature, body or "")
  if problem then
    emit({ type = "error", error = problem })
    return ""
  end
  local envelope, envelope_problem = parse_chat_envelope(body)
  if not envelope then
    emit({ type = "error", error = envelope_problem })
    return ""
  end
  local bot, agent_problem = node_agent(caller)
  if not bot then
    emit({ type = "error", error = agent_problem })
    return ""
  end
  local ok, reply = pcall(bot.run, bot, envelope.text)
  if not ok then emit({ type = "error", error = tostring(reply) }) end
  return ""
end

-- The run half of a peer chat whose signature was verified at admission. It deliberately does not
-- re-verify: the signed request was already recorded as seen, and verifying again would be refused
-- as a replay. The caller is reconstructed from the verified fields, never from the raw body; the
-- target is re-checked from the signed envelope so the run cannot be handed a redirected body.
function wa_node_chat_verified(from, role, name, body)
  if enrollment.managed() then
    emit({ type = "error", error = "managed_guest_uses_operator_model" })
    return ""
  end
  local envelope, envelope_problem = parse_chat_envelope(body)
  if not envelope then
    emit({ type = "error", error = envelope_problem })
    return ""
  end
  local bot, agent_problem = node_agent({ node_id = from, role = role, name = name })
  if not bot then
    emit({ type = "error", error = agent_problem })
    return ""
  end
  local ok, reply = pcall(bot.run, bot, envelope.text)
  if not ok then emit({ type = "error", error = tostring(reply) }) end
  return ""
end

-- A control view names its desktop explicitly. Unknown names fail closed: a stale
-- remote selector must never turn a click into an action on the operator's desktop.
local function control_client(args, role, node)
  if node and node ~= "" and node ~= "local" and node ~= "client" then
    local target = nodeslib.find(node)
    if not target then return { error = "unknown_node:" .. tostring(node) } end
    if not target.local_node then return nodeslib.remote_call(node, "client", args) end
  end
  return toolslib.dispatch(memory, "client", args, role)
end

-- Generic client action from the UI (control view: click/type/key).
function wa_client(payload, session, node)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  local ok, args = pcall(json.decode, payload)
  if not ok or type(args) ~= "table" then return json.encode({ error = "bad_args" }) end
  return json.encode(control_client(args, user.role, node))
end

-- One downscaled screen frame from the client, for the control view.
function wa_frame(request, session, node)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  local args = { action = "frame", max_width = 800, full = false }
  if type(request) == "string" and request:sub(1, 1) == "{" then
    local ok, decoded = pcall(json.decode, request)
    if ok and type(decoded) == "table" then
      args.max_width = tonumber(decoded.max_width) or args.max_width
      args.full = decoded.full and true or false
    end
  else
    args.max_width = tonumber(request) or args.max_width
  end
  return json.encode(control_client(args, user.role, node))
end

-- The exact envelope sent to the model, at full depth. Tiers are NOT included:
-- they duplicate every schema (~9 KB) and `GET /tools` already serves the
-- grouped view for the UI.
function wa_envelope(session)
  local user = users.current(session)
  local role = users.normalize(user.role)
  local settings = provider.settings()
  local tools = toolslib.all(role)
  local names = {}
  for _, tool in ipairs(tools) do names[#names + 1] = tool["function"].name end
  return json.encode({
    role = role,
    request = {
      model = settings.model,
      provider = settings.provider,
      base_url = settings.base_url,
      tools = tools,
    },
    tool_count = #tools,
    tool_names = names,
  })
end

-- The tool surface (envelope) the current role sees, grouped by tier.
function wa_tools(session)
  local user = users.current(session)
  local role = users.normalize(user.role)
  return json.encode({
    role = role,
    tiers = toolslib.tiers(role),
    client_actions = {
      { name = "screenshot", args = {}, note = "save a full-res BMP on the client" },
      { name = "frame", args = { max_width = "integer" }, note = "downscaled view for the control panel" },
      { name = "move", args = { x = "integer", y = "integer" } },
      { name = "click", args = { x = "integer", y = "integer", button = "left|right" } },
      { name = "type", args = { text = "string" } },
      { name = "key", args = { key = "enter|tab|esc|up|down|left|right|..." } },
      { name = "shell", args = { command = "string", shell = "cmd|powershell", cwd = "string" } },
      { name = "cdp", args = { target = "list|open|close|activate|navigate|evaluate|launch", script = "string", id = "string", url = "string", port = "integer", profile = "string" } },
    },
  })
end

-- ---- sessions (for the engine view) -------------------------------------
-- The state of each thread travels with it: a session that was interrupted
-- mid-answer must be distinguishable from a settled one in the list, or the view
-- shows two identical rows for "answered" and "the process died here".
function wa_sessions(session)
  local user = users.current(session)
  return json.encode({ sessions = memory.list_sessions(user.id, 50, { states = true }) })
end

function wa_session(session_id, session)
  local user = users.current(session)
  local record = memory.session(session_id or "")
  if not record then return json.encode({ error = "unknown_session" }) end
  if record.user_id ~= user.id and not users.is_master(user.role) then
    return json.encode({ error = "forbidden" })
  end
  return json.encode({
    session = record,
    state = memory.session_state(session_id),
    messages = memory.session_messages(session_id, { limit = 500 }),
  })
end

-- The efficiency report for the window: the same deterministic, model-free view the
-- `/efficiency_report` command prints. The window has no Lua, so it asks here. The agent is
-- built only so the prefix artifact can be rebuilt from the transcript; no model call is made.
function wa_efficiency(session_id, session)
  local user = users.current(session)
  -- A named session that does not exist is refused; only an absent name falls back to the
  -- latest thread. `unknown or latest` would answer a typo with another session's report.
  local record
  if session_id and session_id ~= "" then
    record = memory.session(session_id)
  else
    record = memory.latest_session(user.id, "")
  end
  if not record then return json.encode({ error = "unknown_session" }) end
  if record.user_id ~= user.id and not users.is_master(user.role) then
    return json.encode({ error = "forbidden" })
  end
  local efficiency = dofile("lua/core/efficiency.lua")
  local agent = agentlib.new(record.id, nil, users.normalize(user.role), user.id, "")
  local ok, text = pcall(efficiency.report, { session_id = record.id, agent = agent, hours = 48 })
  if not ok then return json.encode({ error = "report_failed", detail = redact.text(tostring(text)) }) end
  return json.encode({ session_id = record.id, text = text })
end

-- A message's file changes: "can this still be undone?" and "do it".
--
-- The check and the action are the same route on purpose. Asking whether a patch can be
-- undone and then undoing it are two reads of the same facts, and splitting them into two
-- endpoints is how a UI ends up offering a button that the handler then refuses - the
-- reader clicks, nothing happens, and no one can say why. Here the answer and the effect
-- come from one code path, so what the toggle shows is what the handler will do.
--
-- `changeset.undo`/`redo` already refuse in words ("changed_since_turn:<path>"), and that
-- reason is passed through rather than translated: the reader needs to know *which file*
-- moved on, and inventing a friendlier sentence here would drop the only useful part.
function wa_diff(payload, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  local ok, request = pcall(json.decode, payload)
  if not ok or type(request) ~= "table" then return json.encode({ error = "bad_request" }) end
  local message = memory.message(request.message_id or "")
  if not message then return json.encode({ error = "unknown_turn" }) end
  if not message.changes then return json.encode({ error = "no_changes" }) end

  local entry = { files = {}, added = message.changes.added or 0, removed = message.changes.removed or 0 }
  for _, file in ipairs(message.changes.files or {}) do
    entry.files[#entry.files + 1] = {
      path = file.path, before = file.before, after = file.after,
      added = file.added or 0, removed = file.removed or 0,
      created = file.created == true, recorded = file.recorded ~= false,
    }
  end
  -- Turns recorded before repeats were merged hold one entry per write, and the second one's `before` is
  -- text the message itself wrote. Undo uses `before`, so without this an old message's undo would restore an
  -- intermediate state and call it success. The ledger keeps its rows; the entry is merged as it is read.
  entry = changeset.normalize(entry)

  local action = request.action or "check"
  if action == "check" then
    -- The check is the undo's own guard, run without writing: it loads both texts and
    -- compares the file to what the message left, which is exactly what undo does first.
    local can, why = changeset.check(entry)
    return json.encode({ message_id = message.id, can_undo = can == true, reason = why or "" })
  end
  if action == "preview" then
    -- The changed lines of one file, for the hover balloon. Loading the text is the whole
    -- cost of this action, so it is asked for per file rather than for the whole message -
    -- a topic with seven files should not pull seven files' text to open one balloon.
    local wanted = request.path
    if not wanted or wanted == "" then return json.encode({ error = "path_required" }) end
    for _, file in ipairs(entry.files) do
      if file.path == wanted then
        local preview, why = changeset.preview_file(file)
        if not preview then
          return json.encode({ message_id = message.id, path = file.path, error = why or "no_preview" })
        end
        return json.encode({
          message_id = message.id, path = file.path,
          lines = preview.lines, truncated = preview.truncated,
          added = preview.added, removed = preview.removed,
        })
      end
    end
    return json.encode({ error = "unknown_path" })
  end
  if action == "undo" then
    local done, why = changeset.undo(entry)
    if not done then return json.encode({ message_id = message.id, ok = false, reason = why }) end
    return json.encode({ message_id = message.id, ok = true })
  end
  if action == "redo" then
    local done, why = changeset.redo(entry)
    if not done then return json.encode({ message_id = message.id, ok = false, reason = why }) end
    return json.encode({ message_id = message.id, ok = true })
  end
  if action == "patch" then
    -- What one changed file actually did, built from its two blobs. The transcript only carries
    -- addresses, so this is the request that turns an address back into something a reader can read -
    -- and it is asked for when a file is clicked, not when the message ends.
    local file, why = changeset.patch(entry, request.path or "")
    if not file then return json.encode({ error = why or "patch_failed" }) end
    file.message_id = message.id
    return json.encode(file)
  end
  return json.encode({ error = "unknown_action:" .. tostring(action) })
end

function wa_session_mode(payload, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  local ok, request = pcall(json.decode, payload)
  if not ok or type(request) ~= "table" then return json.encode({ error = "bad_request" }) end
  local id = request.session_id
  if not id or id == "" then return json.encode({ error = "session_id_required" }) end
  return json.encode({ session_id = id, mode = memory.set_session_mode(id, request.mode) })
end

-- Point a session's tools at their own checkout. The same capability the `session_worktree` tool
-- exposes, reached without a model, so the engine - and a test - can set it directly. Master only:
-- it changes where a guest's tools point.
function wa_session_worktree(payload, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  local ok, request = pcall(json.decode, payload)
  if not ok or type(request) ~= "table" then return json.encode({ error = "bad_request" }) end
  local id = request.session_id
  if not id or id == "" then return json.encode({ error = "session_id_required" }) end
  -- No `path` is a read; a string sets it ("" clears it). The directory must exist, or a typo would
  -- silently point every tool at a missing tree.
  if request.path == nil then return json.encode({ session_id = id, worktree = memory.session_worktree(id) }) end
  local path = tostring(request.path)
  if path ~= "" then
    -- `host.list_dir` reports failure as `{error=...}`, not nil, so the JSON must be read.
    local list_ok, raw = pcall(host.list_dir, path)
    local listing = list_ok and json.decode(raw) or nil
    if type(listing) ~= "table" or listing.error then
      return json.encode({ error = "worktree_not_a_directory", path = path })
    end
  end
  return json.encode({ session_id = id, worktree = memory.set_session_worktree(id, path) })
end

function wa_session_fixture(session_id, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  local fixture = memory.session_fixture(session_id or "")
  if not fixture then return json.encode({ error = "unknown_session" }) end
  return json.encode(fixture)
end

function wa_users()
  local list = {}
  for _, user in ipairs(users.list()) do list[#list + 1] = users.public(user) end
  return json.encode({ users = list })
end

-- ---- model + provider ----------------------------------------------------
-- ---- replication: diff sync between nodes --------------------------------
function wa_sync_head()
  return json.encode({
    node_id = (nodeslib.identity() or {}).node_id or "",
    head = memory.journal_head(),
  })
end

-- Accept a batch from a peer: idempotent, and never echo an entry's own origin.
function wa_sync_apply(payload, from, public_key, ts, signature)
  if enrollment.managed() then return json.encode({ error = "managed_sync_disabled" }) end
  local _, problem = verify_peer(from, public_key, ts, signature, "sync")
  if problem then return json.encode({ error = problem }) end
  local ok, request = pcall(json.decode, payload)
  if not ok or type(request) ~= "table" or type(request.entries) ~= "table" then
    return json.encode({ error = "bad_request" })
  end
  local self_id = (nodeslib.identity() or {}).node_id or ""
  local applied = 0
  for _, entry in ipairs(request.entries) do
    if entry.origin ~= self_id and memory.apply_entry(entry) then
      applied = applied + 1
    end
  end
  return json.encode({ ok = true, applied = applied, head = memory.journal_head() })
end

-- Push everything after each peer's cursor. Called on a timer by the host.
function wa_sync_tick()
  local configured = host.getenv("WASM_AGENT_SYNC_TO") or ""
  if configured == "" then return json.encode({ ok = true, peers = 0, pushed = 0 }) end
  local peers, pushed, failed, last_error = 0, 0, 0, nil
  for peer in configured:gmatch("[^,]+") do
    peer = peer:gsub("^%s+", ""):gsub("%s+$", "")
    if peer ~= "" then
      peers = peers + 1
      local cursor = memory.cursor(peer)
      local entries = memory.journal_since(cursor, 200)
      if #entries > 0 then
        -- A name/id routes through the fabric (direct, else relay); a URL is used directly.
        local target = nodeslib.find(peer)
        if not target and peer:match("^https?://") then
          target = { node_id = peer, name = peer, endpoints = { peer } }
        end
        local headers = target and nodeslib.signed_headers("sync") or nil
        if headers then
          local response = nodeslib.request(target, "/sync/push",
            json.encode({ entries = entries }), headers)
          local applied = false
          if response and tonumber(response.status) == 200 then
            -- A 200 carrying an error body is a REJECTION: do not advance the
            -- cursor, or the batch would be lost silently.
            local ok, decoded = pcall(json.decode, response.body)
            if ok and type(decoded) == "table" and decoded.error == nil then
              applied = true
            else
              last_error = ok and decoded.error or "bad_response"
            end
          else
            last_error = response and (response.error or response.status) or "no_response"
          end
          if applied then
            memory.set_cursor(peer, entries[#entries].id)
            pushed = pushed + #entries
          else
            failed = failed + 1
          end
        end
      end
    end
  end
  return json.encode({ ok = failed == 0, peers = peers, pushed = pushed, failed = failed, error = last_error })
end

function wa_sync_status()
  return json.encode({
    node_id = (nodeslib.identity() or {}).node_id or "",
    head = memory.journal_head(),
    pushing_to = host.getenv("WASM_AGENT_SYNC_TO") or "",
    peers = memory.sync_peers(),
  })
end

function wa_model(node, session, chat_session)
  if remote_target(node) then
    local result = nodeslib.remote_call(node, "status", {})
    if result and not result.error then return json.encode(result) end
    return json.encode({ error = (result and result.error) or "remote_error", node = node })
  end
  local settings = provider.settings()
  local user=users.current(session)
  local record=chat_session and chat_session~="" and memory.session(chat_session) or memory.latest_session(user.id,node or "")
  local observation={available=false,scope="unavailable on this node"}
  if require_master(session) and record then observation=telemetry.snapshot(record.id) end
  local budget=provider.budget(settings.model)
  local providers = {}
  for _, item in ipairs(provider.providers()) do
    providers[#providers + 1] = {
      id = item.id,
      label = item.label,
      base_url = item.base_url,
      default_model = item.default_model,
      configured = item.base_url ~= "" and item.api_key ~= "",
      models = provider.list_models(item.id),
    }
  end
  return json.encode({
    provider = settings.provider,
    model = settings.model,
    base_url = settings.base_url,
    configured = provider.configured(),
    providers = providers,
    usage = agentlib.usage(),
    observability=observation,
    reasoning=provider.reasoning(settings.model),
    output_limit=tonumber(host.getenv("WASM_AGENT_LLM_MAX_OUTPUT")) or provider.capabilities(settings.model).max_output,
    compact_reserve=budget.reserve,
    compact_keep=budget.keep,
    compact_trigger=budget.trigger,
    limits = provider.limits(),
    -- The window for the model that is actually selected, from the same place compaction
    -- reads it. It used to read WASM_AGENT_LLM_CONTEXT directly, so the balloon and
    -- compaction could disagree - and the balloon showed a number no model had.
    context_limit = provider.budget(settings.model).context,
    context_source = provider.budget(settings.model).source,
    -- Who this node is, from the same place /nodes reads it. The window fetches this at
    -- startup, so the node control in the account balloon has a name before the engine's
    -- nodes topic has ever been opened.
    node_name = nodeslib.node_name(),
    -- A guest reports no worktree: it has none of its own. The role travels with the name so
    -- the window can say which kind of node it is talking to without asking twice.
    node_worktree = nodeslib.is_master() and nodeslib.worktree() or "",
    node_role = nodeslib.role(),
    -- Where the window came from, and whether the catalogue was reached at all. Without
    -- this, "why is my window wrong" needs a log; with it, the answer is one field.
    context_catalogue = windowlib.catalogue_status(),
    stats = memory.stats(),
    database = host.getenv("WASM_AGENT_DB") or "",
  })
end

-- Switch provider/model at runtime; returns the refreshed settings payload.
function wa_set_provider(id, node, session)
  if not require_master(session) then return json.encode({error="forbidden"}) end
  if remote_target(node) then
    local result = nodeslib.remote_call(node, "set_provider", { id = id or "" })
    if result and not result.error then return json.encode(result) end
    return json.encode({ error = (result and result.error) or "remote_error" })
  end
  provider.set_provider(id or "")
  if agent then agent.model = provider.settings().model end
  return wa_model("", session)
end

-- Rename this node. The name is announced on the event stream as well as returned, because
-- every open window shows it: a rename that only the caller can see is not a rename.
function wa_set_node_name(body, session)
  local decoded = {}
  pcall(function() decoded = json.decode(body) end)
  local wanted = (type(decoded) == "table" and decoded.name) or body
  local name, problem = nodeslib.set_name(wanted)
  if not name then return json.encode({ error = problem }) end
  local identity = nodeslib.identity() or {}
  emit({ type = "node", node_id = identity.node_id or "", name = name,
         worktree = nodeslib.worktree() })
  return wa_nodes(session)
end

function wa_set_model(name, node, session)
  if not require_master(session) then return json.encode({error="forbidden"}) end
  if remote_target(node) then
    local result = nodeslib.remote_call(node, "set_model", { name = name or "" })
    if result and not result.error then return json.encode(result) end
    return json.encode({ error = (result and result.error) or "remote_error" })
  end
  provider.set_model(name or "")
  if agent then agent.model = provider.settings().model end
  return wa_model("", session)
end

function wa_set_reasoning(level,node,session)
  if not require_master(session) then return json.encode({error="forbidden"}) end
  if remote_target(node) then return json.encode({error="reasoning_selection_requires_local_node"}) end
  local ok,problem=provider.set_reasoning(level)
  if not ok then return json.encode({error=problem}) end
  return wa_model("",session)
end

-- Master-only, paginated diagnostic export. No prompts, API keys or tool arguments.
-- '*' selects this node's last 48 hours, including abandoned/failed sessions.
function wa_observability_events(id,cursor,since,session,node)
  if not require_master(session) then return json.encode({error="forbidden"}) end
  if remote_target(node) then return json.encode({error="export_requires_local_node"}) end
  if id~="*" and not memory.session(id or "") then return json.encode({error="unknown_session"}) end
  local result=telemetry.events(id,cursor,500,tonumber(since) or host.now()-172800)
  result.runtime=telemetry.runtime()
  result.node_name=nodeslib.node_name()
  return json.encode(result)
end
