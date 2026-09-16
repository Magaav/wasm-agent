-- Server entry for `wa serve`: one persistent agent behind the web UI.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")

memory.setup()
local agent

local function emit(event)
  host.stream(json.encode(event))
end

function wa_reply(text)
  if not agent then agent = agentlib.new() end
  local ok, reply = pcall(agent.turn, agent, text or "")
  if not ok then return json.encode({ error = tostring(reply) }) end
  return json.encode({ reply = reply })
end

-- Streaming turn: events are pushed to the SSE client as the agent runs.
function wa_reply_stream(text)
  if not agent then agent = agentlib.new(nil, emit) end
  local ok, reply = pcall(agent.turn, agent, text or "")
  if not ok then emit({ type = "error", error = tostring(reply) }) end
  return ""
end

function wa_model()
  local settings = provider.settings()
  return json.encode({
    model = settings.model,
    base_url = settings.base_url,
    configured = provider.configured(),
    database = os.getenv("WASM_AGENT_DB") or "",
    models = provider.list_models(),
    usage = agentlib.usage(),
    context_limit = tonumber(os.getenv("WASM_AGENT_LLM_CONTEXT")) or 0,
    stats = memory.stats(),
  })
end

-- Switch models at runtime; returns the refreshed settings payload.
function wa_set_model(name)
  provider.set_model(name or "")
  if agent then agent.model = provider.settings().model end
  return wa_model()
end
