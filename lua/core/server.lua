-- Server entry for `wa serve`: one agent per user behind the web UI.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")
local users = dofile("lua/core/users.lua")
local toolslib = dofile("lua/core/tools.lua")

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

function wa_spell_run(name, session)
  local user = require_master(session)
  if not user then return json.encode({ error = "forbidden" }) end
  return json.encode(toolslib.dispatch(memory, "spell_run", { name = name }, user.role))
end

-- ---- nodes ---------------------------------------------------------------
function wa_nodes(session)
  local user = users.current(session)
  local role = users.normalize(user.role)
  local link = (host.client_status and json.decode(host.client_status())) or { connected = false }
  local nodes = {
    {
      id = "host", name = "host", kind = "host", role = role, online = true,
      capabilities = { "bash", "read", "write", "edit", "ls", "grep", "spells" },
    },
    {
      id = "client", name = "client", kind = "client", role = role,
      online = link.connected and true or false,
      last_seen_secs = link.last_seen_secs,
      capabilities = { "screenshot", "frame", "click", "move", "type", "key", "shell", "cdp" },
    },
  }
  return json.encode({
    role = role,
    binding = role == "master" and "master:master" or "master:guest",
    nodes = nodes,
  })
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
