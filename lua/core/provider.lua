-- OpenAI-compatible chat provider, over host.http.
local json = dofile("lua/vendor/json.lua")
local M = {}

function M.settings()
  return {
    base_url = os.getenv("WASM_AGENT_LLM_BASE_URL") or os.getenv("WASM_AGENT_OPENAI_BASE_URL")
      or "https://opencode.ai/zen/go/v1",
    api_key = os.getenv("WASM_AGENT_LLM_API_KEY") or os.getenv("OPENCODE_GO_API_KEY")
      or os.getenv("OPENAI_API_KEY") or "",
    model = os.getenv("WASM_AGENT_LLM_MODEL") or os.getenv("WASM_AGENT_DIRECT_HEAD_MODEL")
      or os.getenv("WASM_AGENT_OPENAI_MODEL") or "",
  }
end

function M.configured()
  local settings = M.settings()
  return settings.base_url ~= "" and settings.api_key ~= "" and settings.model ~= ""
end

function M.complete(messages, tools)
  local settings = M.settings()
  local body = { model = settings.model, messages = messages }
  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = "auto"
  end
  local url = settings.base_url:gsub("/+$", "") .. "/chat/completions"
  local headers = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. settings.api_key,
    ["Accept"] = "application/json",
    -- The provider edge rejects a default urllib/ureq-style agent string.
    ["User-Agent"] = "wasm-agent/0.1 provider-proxy",
    ["x-opencode-session"] = "wasm-agent",
  }
  local response = json.decode(host.http("POST", url, json.encode(headers), json.encode(body)))
  if response.error then error("provider_error: " .. tostring(response.error)) end
  if response.status ~= 200 then
    error("provider_http_" .. tostring(response.status) .. ": " .. tostring(response.body):sub(1, 240))
  end
  local payload = json.decode(response.body)
  local message = payload.choices[1].message
  return { content = message.content or "", tool_calls = message.tool_calls or {} }
end

return M
