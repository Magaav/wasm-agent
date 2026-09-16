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

-- Rebuild the agent when the signed-in user (or their role) changes.
local function agent_for(session)
  local user = users.current(session)
  if not agent or agent.user ~= user.id or agent.role ~= user.role then
    if agent then agent:close() end
    agent = agentlib.new(nil, emit, user.role, user.id)
  end
  return agent
end

function wa_reply(text, session)
  local bot = agent_for(session)
  local ok, reply = pcall(bot.turn, bot, text or "")
  if not ok then return json.encode({ error = tostring(reply) }) end
  return json.encode({ reply = reply })
end

-- Streaming turn: events are pushed to the SSE client as the agent runs.
function wa_reply_stream(text, session)
  local bot = agent_for(session)
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
function wa_node_call(payload)
  local ok, request = pcall(json.decode, payload)
  if not ok or type(request) ~= "table" then return json.encode({ error = "bad_request" }) end
  local from = request.from_node_id or ""
  local capability = request.capability or ""
  local ts = math.floor(tonumber(request.ts) or 0)
  if from == "" or capability == "" then return json.encode({ error = "bad_request" }) end
  local message = table.concat({ "call", from, tostring(ts), capability }, "|")
  if not host.verify(request.public_key or "", message, request.signature or "") then
    return json.encode({ error = "bad_signature" })
  end
  if math.abs(host.now() - ts) > 120 then return json.encode({ error = "stale_request" }) end
  local caller = nodeslib.verify_caller(from, request.public_key)
  if not caller then return json.encode({ error = "unknown_caller" }) end
  if users.normalize(caller.role) ~= "master" then return json.encode({ error = "forbidden_role" }) end
  if capability == "remote" then return json.encode({ error = "remote_cannot_recurse" }) end
  return json.encode(toolslib.dispatch(memory, capability, request.args or {}, "master"))
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
function wa_frame(max_width, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  return json.encode(toolslib.dispatch(memory, "client", {
    action = "frame", max_width = tonumber(max_width) or 720,
  }, user.role))
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

function wa_users()
  local list = {}
  for _, user in ipairs(users.list()) do list[#list + 1] = users.public(user) end
  return json.encode({ users = list })
end

-- ---- model + provider ----------------------------------------------------
function wa_model()
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
function wa_set_provider(id)
  provider.set_provider(id or "")
  if agent then agent.model = provider.settings().model end
  return wa_model()
end

function wa_set_model(name)
  provider.set_model(name or "")
  if agent then agent.model = provider.settings().model end
  return wa_model()
end
