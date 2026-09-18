-- Server entry for `wa serve`: one agent per user behind the web UI.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local windowlib = dofile("lua/core/model_window.lua")
local agentlib = dofile("lua/core/agent.lua")
local users = dofile("lua/core/users.lua")
local toolslib = dofile("lua/core/tools.lua")
local nodeslib = dofile("lua/core/nodes.lua")
-- Errors travel to a browser, a log and a test harness; mask secrets as they
-- leave the server rather than trusting every future call site.
local redact = dofile("lua/core/redact.lua")

memory.setup()
local agent

local function emit(event)
  host.stream(json.encode(event))
end

-- Rebuild the agent when the signed-in user, their role, or the target node
-- changes. The session is a resumable thread keyed by (user, node).
local function agent_for(session, node)
  local user = users.current(session)
  node = node or ""
  if not agent or agent.user ~= user.id or agent.role ~= user.role or agent.node ~= node then
    if agent then agent:close() end
    agent = agentlib.new(nil, emit, user.role, user.id, node)
  end
  return agent
end

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
local function parse_turn_body(body)
  local raw = body or ""
  if raw:sub(1, 1) ~= "{" then return raw, {} end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" or decoded.images == nil then
    return raw, {}
  end
  local images = {}
  for _, entry in ipairs(decoded.images or {}) do
    local reference, problem = memory.store_image(entry)
    if not reference then return nil, nil, problem end
    images[#images + 1] = reference
  end
  return tostring(decoded.text or ""), images
end

function wa_reply(text, session, node)
  local prompt, images, problem = parse_turn_body(text)
  if problem then return json.encode({ error = redact.text(problem) }) end
  if remote_target(node) then
    local result = nodeslib.remote_call(node, "chat", { text = prompt or "" })
    if result and result.error then return json.encode({ error = redact.text(tostring(result.error)) }) end
    return json.encode({ reply = result and result.reply or "" })
  end
  local bot = agent_for(session, node)
  local ok, reply = pcall(bot.turn, bot, prompt or "", images)
  if not ok then return json.encode({ error = redact.text(tostring(reply)) }) end
  return json.encode({ reply = reply })
end

-- Streaming turn: events are pushed to the SSE client as the agent runs.
-- When a peer is selected, its stream is relayed here unchanged.
function wa_reply_stream(text, session, node)
  local prompt, images, problem = parse_turn_body(text)
  if problem then
    emit({ type = "error", error = redact.text(problem) })
    return ""
  end
  if remote_target(node) then
    local result = nodeslib.remote_chat(node, prompt or "")
    if result and result.error then emit({ type = "error", error = redact.text(tostring(result.error)) }) end
    return ""
  end
  local bot = agent_for(session, node)
  local ok, reply = pcall(bot.turn, bot, prompt or "", images)
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
  return json.encode({
    user = users.public(user),
    role = user.role,
    tools = tool_names(user.role),
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
  if not users.is_master(user.role) then return nil, user end
  return user
end

function wa_shell(command, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  if not command or command == "" then return json.encode({ error = "command_required" }) end
  return json.encode(toolslib.dispatch(memory, "shell", { command = command }, user.role))
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

-- ---- nodes ---------------------------------------------------------------
function wa_nodes(session)
  local user = users.current(session)
  local role = users.normalize(user.role)
  local link = (host.client_status and json.decode(host.client_status())) or { connected = false }
  local list = nodeslib.list()
  -- The local client (the desktop running the window) sits next to the host.
  table.insert(list, math.min(2, #list + 1), {
    id = "client", node_id = "client", name = "client", kind = "client", role = role,
    online = link.connected and true or false,
    last_seen_secs = link.last_seen_secs,
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
-- A peer must be a rendezvous-known master with a valid, fresh signature.
local function verify_peer(from, public_key, ts, signature, action)
  if not from or from == "" then return nil, "bad_request" end
  local message = table.concat({ action, from, tostring(math.floor(tonumber(ts) or 0)) }, "|")
  if not host.verify(public_key or "", message, signature or "") then return nil, "bad_signature" end
  if math.abs(host.now() - (tonumber(ts) or 0)) > 120 then return nil, "stale_request" end
  local caller = nodeslib.verify_caller(from, public_key)
  if not caller then return nil, "unknown_caller" end
  if users.normalize(caller.role) ~= "master" then return nil, "forbidden_role" end
  return caller
end

-- A turn requested by a peer runs as master.
local node_agent_instance
local function node_agent()
  if not node_agent_instance then
    node_agent_instance = agentlib.new(nil, emit, "master", "node")
  end
  return node_agent_instance
end

-- Capabilities a peer may invoke, in addition to the normal tools.
local function node_capability(capability, args)
  args = args or {}
  if capability == "status" then
    return json.decode(wa_model("", ""))
  elseif capability == "set_provider" then
    provider.set_provider(args.id or "")
    return json.decode(wa_model("", ""))
  elseif capability == "set_model" then
    provider.set_model(args.name or "")
    return json.decode(wa_model("", ""))
  elseif capability == "chat" then
    local bot = node_agent()
    local ok, reply = pcall(bot.turn, bot, args.text or "")
    if not ok then return { error = tostring(reply) } end
    return { reply = reply }
  end
  return toolslib.dispatch(memory, capability, args, "master")
end

function wa_node_call(payload)
  local ok, request = pcall(json.decode, payload)
  if not ok or type(request) ~= "table" then return json.encode({ error = "bad_request" }) end
  local capability = request.capability or ""
  if capability == "" then return json.encode({ error = "bad_request" }) end
  if capability == "remote" then return json.encode({ error = "remote_cannot_recurse" }) end
  local _, problem = verify_peer(request.from_node_id, request.public_key, request.ts, request.signature, "call")
  if problem then return json.encode({ error = problem }) end
  return json.encode(node_capability(capability, request.args))
end

-- Streaming turn requested by a peer (/node/chat): events go to that stream.
function wa_node_chat(from, public_key, ts, signature, text)
  local _, problem = verify_peer(from, public_key, ts, signature, "chat")
  if problem then
    emit({ type = "error", error = problem })
    return ""
  end
  local bot = node_agent()
  local ok, reply = pcall(bot.turn, bot, text or "")
  if not ok then emit({ type = "error", error = tostring(reply) }) end
  return ""
end

-- Generic client action from the UI (control view: click/type/key).
function wa_client(payload, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  local ok, args = pcall(json.decode, payload)
  if not ok or type(args) ~= "table" then return json.encode({ error = "bad_args" }) end
  return json.encode(toolslib.dispatch(memory, "client", args, user.role))
end

-- One downscaled screen frame from the client, for the control view.
function wa_frame(request, session)
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
  return json.encode(toolslib.dispatch(memory, "client", args, user.role))
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
    turns = memory.session_turns(session_id, { limit = 500 }),
  })
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

function wa_model(node, session)
  if remote_target(node) then
    local result = nodeslib.remote_call(node, "status", {})
    if result and not result.error then return json.encode(result) end
    return json.encode({ error = (result and result.error) or "remote_error", node = node })
  end
  local settings = provider.settings()
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
    node_worktree = nodeslib.worktree(),
    -- Where the window came from, and whether the catalogue was reached at all. Without
    -- this, "why is my window wrong" needs a log; with it, the answer is one field.
    context_catalogue = windowlib.catalogue_status(),
    stats = memory.stats(),
    database = host.getenv("WASM_AGENT_DB") or "",
  })
end

-- Switch provider/model at runtime; returns the refreshed settings payload.
function wa_set_provider(id, node, session)
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
  if remote_target(node) then
    local result = nodeslib.remote_call(node, "set_model", { name = name or "" })
    if result and not result.error then return json.encode(result) end
    return json.encode({ error = (result and result.error) or "remote_error" })
  end
  provider.set_model(name or "")
  if agent then agent.model = provider.settings().model end
  return wa_model("", session)
end
