-- Server entry for `wa serve`: one agent per user behind the web UI.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")
local users = dofile("lua/core/users.lua")
local toolslib = dofile("lua/core/tools.lua")
local nodeslib = dofile("lua/core/nodes.lua")

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

function wa_reply(text, session, node)
  if remote_target(node) then
    local result = nodeslib.remote_call(node, "chat", { text = text or "" })
    if result and result.error then return json.encode({ error = tostring(result.error) }) end
    return json.encode({ reply = result and result.reply or "" })
  end
  local bot = agent_for(session, node)
  local ok, reply = pcall(bot.turn, bot, text or "")
  if not ok then return json.encode({ error = tostring(reply) }) end
  return json.encode({ reply = reply })
end

-- Streaming turn: events are pushed to the SSE client as the agent runs.
-- When a peer is selected, its stream is relayed here unchanged.
function wa_reply_stream(text, session, node)
  if remote_target(node) then
    local result = nodeslib.remote_chat(node, text or "")
    if result and result.error then emit({ type = "error", error = tostring(result.error) }) end
    return ""
  end
  local bot = agent_for(session, node)
  local ok, reply = pcall(bot.turn, bot, text or "")
  if not ok then emit({ type = "error", error = tostring(reply) }) end
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

-- The exact envelope object sent to the model, at full depth.
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
    tiers = toolslib.tiers(role),
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
function wa_sessions(session)
  local user = users.current(session)
  return json.encode({ sessions = memory.list_sessions(user.id, 50) })
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
    context_limit = tonumber(os.getenv("WASM_AGENT_LLM_CONTEXT")) or 0,
    stats = memory.stats(),
    database = os.getenv("WASM_AGENT_DB") or "",
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
