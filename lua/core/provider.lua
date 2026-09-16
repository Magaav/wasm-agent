-- OpenAI-compatible providers, over host.http / host.http_stream.
--
-- A *provider* is an endpoint (base URL + key). A *model* belongs to a provider.
-- Selection is persisted per provider under ~/.wasm-agent/.
local json = dofile("lua/vendor/json.lua")
local M = {}

local function env(name) return os.getenv(name) end
local function trim(value) return (value or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function state_path(name)
  return (os.getenv("HOME") or ".") .. "/.wasm-agent/" .. name
end

local function read_state(name)
  if not (host and host.read_file) then return nil end
  local value = trim(host.read_file(state_path(name)))
  if value == "" then return nil end
  return value
end

local function write_state(name, value)
  if host and host.write_file then host.write_file(state_path(name), value) end
end

-- Provider profiles. Add one here and it appears in the UI automatically.
function M.providers()
  return {
    {
      id = "opencode-go",
      label = "opencode-go",
      base_url = env("WASM_AGENT_LLM_BASE_URL") or env("WASM_AGENT_OPENAI_BASE_URL")
        or "https://opencode.ai/zen/go/v1",
      api_key = env("WASM_AGENT_LLM_API_KEY") or env("OPENCODE_GO_API_KEY")
        or env("OPENAI_API_KEY") or "",
      default_model = "deepseek-v4.1-flash",
    },
    {
      id = "gpt",
      label = "gpt",
      base_url = env("OPENAI_BASE_URL") or "https://api.openai.com/v1",
      api_key = env("OPENAI_API_KEY") or "",
      default_model = "gpt-4.1",
    },
  }
end

function M.active()
  local id = M.provider_override or read_state("provider") or env("WASM_AGENT_PROVIDER")
  local list = M.providers()
  for _, provider in ipairs(list) do
    if provider.id == id then return provider end
  end
  return list[1]
end

function M.settings()
  local provider = M.active()
  local model = (M.overrides and M.overrides[provider.id]) or read_state("model." .. provider.id)
  if not model and provider.id == "opencode-go" then model = env("WASM_AGENT_LLM_MODEL") end
  model = model or provider.default_model
  return {
    provider = provider.id,
    label = provider.label,
    base_url = provider.base_url,
    api_key = provider.api_key,
    model = model,
    default_model = provider.default_model,
  }
end

function M.configured()
  local settings = M.settings()
  return settings.base_url ~= "" and settings.api_key ~= "" and settings.model ~= ""
end

function M.set_provider(id)
  id = trim(id)
  for _, provider in ipairs(M.providers()) do
    if provider.id == id then
      M.provider_override = id
      write_state("provider", id)
      return true
    end
  end
  return false
end

function M.set_model(name)
  name = trim(name)
  if name == "" then return false end
  local provider = M.active()
  M.overrides = M.overrides or {}
  M.overrides[provider.id] = name
  write_state("model." .. provider.id, name)
  return true
end

local function headers_for(provider)
  return {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. provider.api_key,
    ["Accept"] = "application/json",
    -- The provider edge rejects a default urllib/ureq-style agent string.
    ["User-Agent"] = "wasm-agent/0.1 provider-proxy",
    ["x-opencode-session"] = "wasm-agent",
  }
end

-- Model catalogue for a provider (defaults to the active one). Cached, then
-- falls back to the provider's default model so the dropdown is never empty.
function M.list_models(id)
  local provider = nil
  if id then
    for _, candidate in ipairs(M.providers()) do
      if candidate.id == id then provider = candidate end
    end
  end
  provider = provider or M.active()
  M._cache = M._cache or {}
  local now = (host and host.now and host.now()) or 0
  local entry = M._cache[provider.id]
  if entry and (now - entry.at) < 300 then return entry.models end

  local models = {}
  if provider.api_key ~= "" then
    pcall(function()
      local url = provider.base_url:gsub("/+$", "") .. "/models"
      local response = json.decode(host.http("GET", url, json.encode(headers_for(provider)), ""))
      if response and tonumber(response.status) == 200 then
        local ok, payload = pcall(json.decode, response.body)
        if ok and type(payload) == "table" and type(payload.data) == "table" then
          for _, item in ipairs(payload.data) do
            if type(item) == "table" and item.id then models[#models + 1] = item.id end
          end
        end
      end
    end)
  end
  if #models == 0 then models[1] = provider.default_model end

  M._cache[provider.id] = { at = now, models = models }
  return models
end

-- Rolling usage limits from the provider (`rolling` = 5h, `weekly` = 7d,
-- `monthly` = 30d), each `{status, percent, resetsAt}`. Cached briefly.
function M.limits()
  local provider = M.active()
  if provider.api_key == "" then return {} end
  local now = (host and host.now and host.now()) or 0
  if M._limits and (now - (M._limits_at or 0)) < 30 then return M._limits end
  local limits = {}
  pcall(function()
    local url = provider.base_url:gsub("/+$", "") .. "/usage"
    local response = json.decode(host.http("GET", url, json.encode(headers_for(provider)), ""))
    if response and tonumber(response.status) == 200 then
      local ok, payload = pcall(json.decode, response.body)
      if ok and type(payload) == "table" and type(payload.usage) == "table" then
        limits = payload.usage
      end
    end
  end)
  M._limits = limits
  M._limits_at = now
  return limits
end

-- `stream` forwards content deltas to the UI and still returns the whole
-- message (content + tool_calls + usage) so the tool loop can continue.
function M.complete(messages, tools, stream)
  local settings = M.settings()
  local provider = M.active()
  local body = { model = settings.model, messages = messages }
  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = "auto"
  end
  local url = provider.base_url:gsub("/+$", "") .. "/chat/completions"
  local headers = headers_for(provider)

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
