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
