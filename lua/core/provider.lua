-- OpenAI-compatible providers, over host.http / host.http_stream.
--
-- A *provider* is an endpoint (base URL + key). A *model* belongs to a provider.
-- Selection is persisted per provider under ~/.wasm-agent/.
local json = dofile("lua/vendor/json.lua")
-- Provider errors can quote the request back at us, key included; redact at the
-- point the message is built so it is masked before it is logged or stored.
local redact = dofile("lua/core/redact.lua")
-- Per-model context windows. The window belongs to the model, not to the process.
local windowlib = dofile("lua/core/model_window.lua")
local M = {}

local function env(name) return host.getenv(name) end
local function trim(value) return (value or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local state = dofile("lua/core/state.lua")

local function state_path(name)
  return state.path(name)
end

local function read_state(name)
  if not (host and host.read_file) then return nil end
  return state.read(name)
end

local function write_state(name, value)
  state.write(name, value)
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

-- Prompt-cache routing. Providers cache the *prefix* of a request (system +
-- tools + history) and reuse it when the prefix is byte-identical. A routing key
-- pins a conversation to the same cache shard so it is not scattered.
local function clamp_cache_key(value)
  local text = tostring(value or ""):gsub("[^%w_-]", "")
  if text == "" then return nil end
  return text:sub(1, 64)
end

-- `auto` (default) sends the key only to providers known to honour it;
-- `on` forces it; `off` disables it. `opts.cache == false` marks a one-off
-- request (summarisation): it gets no key, so it neither reads nor pollutes the
-- conversation's cache - the same reason pi disables cache writes there.
function M.cache_params(opts)
  opts = opts or {}
  if opts.cache == false then return {} end
  local mode = host.getenv("WASM_AGENT_PROMPT_CACHE_KEY") or "auto"
  if mode == "off" then return {} end
  local session_id = opts.session_id
  if not session_id or session_id == "" then return {} end
  local settings = M.settings()
  local is_openai = settings.base_url:find("api%.openai%.com") ~= nil
  if mode ~= "on" and not is_openai then return {} end
  local params = { prompt_cache_key = clamp_cache_key(host.sha256(session_id)) }
  local retention = host.getenv("WASM_AGENT_PROMPT_CACHE_RETENTION")
  if retention and retention ~= "" then params.prompt_cache_retention = retention end
  return params
end

-- Per-model rates in USD per million tokens, from WASM_AGENT_MODEL_RATES:
--   {"deepseek-v4.1-flash":{"input":0.28,"output":0.42,"cacheRead":0.028,"cacheWrite":0.28}}
-- No rates are invented here: unset means we report tokens and no cost.
-- Context budget for a model: the window, and how much of it to reserve for
-- the reply. Per model, because switching models must not silently keep the
-- previous window - that shows up as provider failures instead of compaction.
-- `M.limits` above is unrelated: those are the account's rate limits for the UI.
--
-- The window is looked up by model (lua/core/model_window.lua) rather than read from one
-- global, because the global cannot be right for more than one model: with a single
-- WASM_AGENT_LLM_CONTEXT=128000 the agent compacted a 1000000-token model at ~96000
-- tokens, ten times too early, and "compacted" is not an error so nothing said so.
-- WASM_AGENT_MODEL_LIMITS still overrides everything, and the old global is kept as the
-- last-resort fallback so no existing deployment changes behaviour by surprise.
function M.budget(model)
  local window = windowlib.for_model(model)
  local budget = {
    context = window.context,
    source = window.source,
    output = window.output,
  }
  local reserve = tonumber(host.getenv("WASM_AGENT_COMPACT_RESERVE"))
  local keep = tonumber(host.getenv("WASM_AGENT_COMPACT_KEEP"))
  if reserve and keep then
    budget.reserve, budget.keep = reserve, keep
  else
    local r, k = windowlib.policy(budget.context)
    budget.reserve = reserve or r
    budget.keep = keep or k
  end
  -- A per-model override may still narrow the window (a proxy, a cheaper tier).
  local raw = host.getenv("WASM_AGENT_MODEL_LIMITS")
  if raw and raw ~= "" and model and model ~= "" then
    local ok, parsed = pcall(json.decode, raw)
    local entry = ok and type(parsed) == "table" and parsed[model] or nil
    if type(entry) == "table" then
      if tonumber(entry.context) then
        budget.context = tonumber(entry.context)
        budget.source = "env-WASM_AGENT_MODEL_LIMITS"
        local r, k = windowlib.policy(budget.context)
        budget.reserve = tonumber(entry.reserve) or r
        budget.keep = tonumber(entry.keep) or k
      end
      budget.reserve = tonumber(entry.reserve) or budget.reserve
      budget.keep = tonumber(entry.keep) or budget.keep
    end
  end
  return budget
end
function M.rates(model)
  local raw = host.getenv("WASM_AGENT_MODEL_RATES")
  if not raw or raw == "" then return nil end
  local ok, table_ = pcall(json.decode, raw)
  if not ok or type(table_) ~= "table" then return nil end
  return table_[model or M.settings().model]
end

-- `stream` forwards content deltas to the UI and still returns the whole
-- message (content + tool_calls + usage) so the tool loop can continue.
function M.complete(messages, tools, stream, opts)
  return M.complete_with(M.settings().model, messages, tools, stream, opts)
end

-- Same, with an explicit model: used by compaction (a cheaper summariser when
-- WASM_AGENT_LLM_SUMMARY_MODEL is set, otherwise the main model).
function M.complete_with(model, messages, tools, stream, opts)
  local settings = M.settings()
  local provider = M.active()
  local body = { model = model or settings.model, messages = messages }
  -- pi always sends an output cap, and its own comment says why: reasoning and the
  -- answer share max_tokens, so an uncapped reasoning phase can consume the whole
  -- response and leave no answer and no tool call. We send one only when asked,
  -- because a provider that rejects the field would break every turn - but an
  -- empty answer is caught either way, which is what empty_reply_reason is for.
  local max_output = tonumber(host.getenv("WASM_AGENT_LLM_MAX_OUTPUT") or "")
  if max_output and max_output > 0 then
    local field = host.getenv("WASM_AGENT_LLM_MAX_OUTPUT_FIELD")
    body[field and field ~= "" and field or "max_tokens"] = max_output
  end
  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = "auto"
  end
  for key, value in pairs(M.cache_params(opts)) do body[key] = value end
  local url = provider.base_url:gsub("/+$", "") .. "/chat/completions"
  local headers = headers_for(provider)

  if stream then
    body.stream = true
    body.stream_options = { include_usage = true }
    local result = json.decode(host.http_stream("POST", url, json.encode(headers), json.encode(body)))
    if result.error then error(redact.text("provider_error: " .. tostring(result.error))) end
    if result.status ~= 200 then
      error(redact.text("provider_http_" .. tostring(result.status) .. ": " .. tostring(result.body):sub(1, 240)))
    end
    return {
      content = result.content or "",
      reasoning = result.reasoning or "",
      finish_reason = result.finish_reason,
      tool_calls = result.tool_calls or {},
      usage = result.usage,
      model = body.model,
    }
  end

  local response = json.decode(host.http("POST", url, json.encode(headers), json.encode(body)))
  if response.error then error(redact.text("provider_error: " .. tostring(response.error))) end
  if response.status ~= 200 then
    error(redact.text("provider_http_" .. tostring(response.status) .. ": " .. tostring(response.body):sub(1, 240)))
  end
  local payload = json.decode(response.body)
  local message = payload.choices[1].message
  return {
    content = message.content or "",
    reasoning = M.reasoning_of(message),
    finish_reason = payload.choices[1].finish_reason,
    tool_calls = message.tool_calls or {},
    usage = payload.usage,
    model = payload.model or body.model,
  }
end

-- The three spellings an OpenAI-compatible endpoint uses for a reasoning model's
-- thinking. pi reads all three and takes the first non-empty one for the same
-- reason: it is one piece of information under different names.
local REASONING_FIELDS = { "reasoning_content", "reasoning", "reasoning_text" }

function M.reasoning_of(message)
  if type(message) ~= "table" then return "" end
  for _, field in ipairs(REASONING_FIELDS) do
    local value = message[field]
    if type(value) == "string" and value ~= "" then return value end
  end
  return ""
end

-- What a reader would see. A reply that is only reasoning, or only whitespace, is
-- not an answer - and some endpoints put the thinking inside content as a <think>
-- block, so those are removed here the way the UI removes them.
function M.visible_text(text)
  local out = tostring(text or "")
  local last = nil
  local from = 1
  while true do
    local _, closing = string.find(out, "</think>", from, true)
    if not closing then break end
    last = closing
    from = closing + 1
  end
  if last then out = out:sub(last + 1) end
  local opening = string.find(out, "<think", 1, true)
  if opening then out = out:sub(1, opening - 1) end
  out = out:gsub("</?think[^>]*>", "")
  return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Why an empty assistant message is not an answer, in words a reader can act on.
function M.empty_reply_reason(result)
  local reasoning = tostring(result and result.reasoning or "")
  local finish = result and result.finish_reason
  local where = (finish and finish ~= "") and ("finish_reason=" .. tostring(finish))
    or "the provider sent no finish_reason"
  if #reasoning > 0 then
    return string.format(
      "the model spent its output on reasoning (%d chars) and returned no answer (%s); " ..
      "reasoning is not an answer, so either it ran out of budget before writing one or " ..
      "this endpoint only streams thinking - WASM_AGENT_LLM_MAX_OUTPUT sets the cap we " ..
      "send, and pi clamps its thinking budget for exactly this reason",
      #reasoning, where)
  end
  return string.format(
    "the provider returned an empty message with no tool call and no text (%s)", where)
end

return M
