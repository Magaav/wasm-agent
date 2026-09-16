-- OpenAI-compatible chat provider, over host.http / host.http_stream.
local json = dofile("lua/vendor/json.lua")
local M = {}

local function env(name) return os.getenv(name) end

local function model_path()
  return (os.getenv("HOME") or ".") .. "/.wasm-agent/model"
end

local function persisted_model()
  if not (host and host.read_file) then return nil end
  local text = host.read_file(model_path())
  if not text or text == "" then return nil end
  local name = text:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil end
  return name
end

function M.settings()
  return {
    base_url = env("WASM_AGENT_LLM_BASE_URL") or env("WASM_AGENT_OPENAI_BASE_URL")
      or "https://opencode.ai/zen/go/v1",
    api_key = env("WASM_AGENT_LLM_API_KEY") or env("OPENCODE_GO_API_KEY")
      or env("OPENAI_API_KEY") or "",
    model = M.override or persisted_model() or env("WASM_AGENT_LLM_MODEL")
      or env("WASM_AGENT_DIRECT_HEAD_MODEL") or env("WASM_AGENT_OPENAI_MODEL") or "",
  }
end

function M.configured()
  local settings = M.settings()
  return settings.base_url ~= "" and settings.api_key ~= "" and settings.model ~= ""
end

local function headers_for(settings)
  return {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. settings.api_key,
    ["Accept"] = "application/json",
    -- The provider edge rejects a default urllib/ureq-style agent string.
    ["User-Agent"] = "wasm-agent/0.1 provider-proxy",
    ["x-opencode-session"] = "wasm-agent",
  }
end

-- Switch the active model. Kept in memory and persisted so it survives restarts.
function M.set_model(name)
  name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return false end
  M.override = name
  M._models = nil
  if host and host.write_file then host.write_file(model_path(), name) end
  return true
end

-- Ask the provider for its model catalogue; fall back to the active model.
-- Cached for five minutes so the UI can poll it cheaply.
function M.list_models()
  local now = (host and host.now and host.now()) or 0
  if M._models and (now - (M._models_at or 0)) < 300 then return M._models end
  local settings = M.settings()
  local models = {}
  pcall(function()
    local url = settings.base_url:gsub("/+$", "") .. "/models"
    local response = json.decode(host.http("GET", url, json.encode(headers_for(settings)), ""))
    if response and tonumber(response.status) == 200 then
      local ok, payload = pcall(json.decode, response.body)
      if ok and type(payload) == "table" and type(payload.data) == "table" then
        for _, item in ipairs(payload.data) do
          if type(item) == "table" and item.id then models[#models + 1] = item.id end
        end
      end
    end
  end)
  if #models == 0 and settings.model ~= "" then models[1] = settings.model end
  M._models = models
  M._models_at = now
  return models
end

-- `stream` forwards content deltas to the UI and still returns the whole
-- message (content + tool_calls + usage) so the tool loop can continue.
function M.complete(messages, tools, stream)
  local settings = M.settings()
  local body = { model = settings.model, messages = messages }
  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = "auto"
  end
  local url = settings.base_url:gsub("/+$", "") .. "/chat/completions"
  local headers = headers_for(settings)

  if stream then
    body.stream = true
    body.stream_options = { include_usage = true }
    local result = json.decode(host.http_stream("POST", url, json.encode(headers), json.encode(body)))
    if result.error then error("provider_error: " .. tostring(result.error)) end
    if result.status ~= 200 then
      error("provider_http_" .. tostring(result.status) .. ": " .. tostring(result.body):sub(1, 240))
    end
    return {
      content = result.content or "",
      tool_calls = result.tool_calls or {},
      usage = result.usage,
      model = settings.model,
    }
  end

  local response = json.decode(host.http("POST", url, json.encode(headers), json.encode(body)))
  if response.error then error("provider_error: " .. tostring(response.error)) end
  if response.status ~= 200 then
    error("provider_http_" .. tostring(response.status) .. ": " .. tostring(response.body):sub(1, 240))
  end
  local payload = json.decode(response.body)
  local message = payload.choices[1].message
  return {
    content = message.content or "",
    tool_calls = message.tool_calls or {},
    usage = payload.usage,
    model = payload.model or settings.model,
  }
end

return M
