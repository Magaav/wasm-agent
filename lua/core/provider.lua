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
local telemetry = dofile("lua/core/telemetry.lua")
local prefix_audit = dofile("lua/core/prefix_audit.lua")
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

-- Provider profiles. Add one here and it appears in the UI automatically - and
-- record its host in ATTRIBUTION below, or scripts/test.sh refuses the profile
-- rather than letting it reach the provider with the wrong headers.
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
  if M._pinned then return M._pinned.provider end
  local id = M.provider_override or read_state("provider") or env("WASM_AGENT_PROVIDER")
  local list = M.providers()
  for _, provider in ipairs(list) do
    if provider.id == id then return provider end
  end
  return list[1]
end

function M.settings()
  if M._pinned then return M._pinned.settings end
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

-- Attribution: what a provider's edge is told about who is calling, and which
-- conversation this is. Matched on the *host* of the base URL rather than on the
-- profile's id, because WASM_AGENT_LLM_BASE_URL can point any profile at another
-- service, and the headers a service needs belong to the service and not to the
-- label we happened to give it.
--
-- `session` names the header that must carry the conversation id, and it is not
-- decoration. OpenCode Go documents it as a requirement - "Send a stable session
-- ID in x-opencode-session for each conversation so we can optimize routing and
-- prompt caching" - and lists clients that omit it under "Known Problematic
-- Clients". A constant satisfies "a header is present" while defeating the whole
-- point, which is what this file did: it sent the literal "wasm-agent" for every
-- conversation on the node, so every conversation shared one cache shard.
--
-- Every host a shipped profile can reach must appear here, including the ones
-- that need nothing beyond the credentials, because the entry *is* the decision.
-- M.attribution_gaps() reports the profiles that have none, and scripts/test.sh
-- asserts that list is empty - a new provider is refused until someone decides.
local ATTRIBUTION = {
  {
    host = "opencode.ai",
    session = "x-opencode-session",
    -- pi, a validated client, also sends x-opencode-client: pi. The docs do not
    -- ask for it and nothing here can show the edge reads it, so this does not
    -- invent it.
  },
  {
    -- OpenAI routes a conversation with the `prompt_cache_key` body field, which
    -- cache_params already sends per conversation, and has no session header.
    -- Declared so the absence is a decision a reader can see, not an oversight.
    host = "api.openai.com",
  },
}

-- The authority of a base URL, lowercased: "https://opencode.ai/zen/go/v1" gives
-- "opencode.ai". Not a URL parser - just enough to match a rule.
local function base_host(url)
  local authority = tostring(url or ""):match("^%a[%w+.-]*://([^/?#]*)")
  if not authority or authority == "" then return nil end
  authority = authority:gsub("^.*@", ""):gsub(":%d+$", "")
  if authority == "" then return nil end
  return authority:lower()
end

-- The declared rule for a provider's host, or nil when nobody has decided what
-- that host needs. A nil rule means credentials and the user agent, and never a
-- guessed session header: routing a conversation by the wrong id is worse than
-- not routing it at all, because it is invisible.
function M.attribution_rule(provider)
  local host = base_host(provider and provider.base_url)
  if not host then return nil end
  for _, rule in ipairs(ATTRIBUTION) do
    if rule.host == host then return rule end
  end
  return nil
end

-- Shipped providers whose host has no rule. scripts/test.sh asserts this is
-- empty; the names it prints are what the next person adds to ATTRIBUTION.
function M.attribution_gaps()
  local gaps = {}
  for _, provider in ipairs(M.providers()) do
    if not M.attribution_rule(provider) then
      gaps[#gaps + 1] = tostring(provider.id) .. " -> " ..
        tostring(base_host(provider.base_url) or provider.base_url)
    end
  end
  return gaps
end

-- Headers for one request. `session_id` is the conversation this request belongs
-- to; a request that is not part of a conversation (the model catalogue, the
-- account's limits) passes nil and gets no session header. `cache = false` does
-- not suppress it: that flag keeps a one-off prompt out of the cache *key*, while
-- this header is what keeps the conversation on one shard at all. The applied
-- rule is returned too, so the request can record which routing it used.
local function headers_for(provider, session_id)
  local headers = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. provider.api_key,
    ["Accept"] = "application/json",
    -- The provider edge rejects a default urllib/ureq-style agent string.
    ["User-Agent"] = "wasm-agent/0.1 provider-proxy",
  }
  local rule = M.attribution_rule(provider)
  if rule and rule.session and session_id and session_id ~= "" then
    headers[rule.session] = tostring(session_id)
  end
  return headers, rule
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
      -- Listing models is not part of a conversation, so no session id is sent.
      local headers = headers_for(provider)
      local response = json.decode(host.http("GET", url, json.encode(headers), ""))
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
    local headers = headers_for(provider)
    local response = json.decode(host.http("GET", url, json.encode(headers), ""))
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
-- request (summarisation): it gets no conversation routing key. This does NOT
-- disable a provider's automatic prefix caching.
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
  if budget.context>0 then
    budget.reserve=math.min(budget.reserve,math.max(1000,math.floor(budget.context/4)))
    budget.keep=math.min(budget.keep,math.max(1000,math.floor(budget.context/2)))
    local soft=tonumber(host.getenv('WASM_AGENT_CONTEXT_BUDGET'))
    budget.trigger=math.max(0,math.min(budget.context-budget.reserve,soft and soft>0 and soft or math.huge))
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

-- Follow Pi's per-model compatibility contract; an unknown model stays unknown.
-- Only public model metadata is read from Pi's local store, never credentials.
function M.capabilities(model)
  local provider_id = M.active().id
  local file = host.getenv("WASM_AGENT_PI_MODELS_STORE")
    or (dofile("lua/core/paths.lua").home() .. "/.pi/agent/models-store.json")
  local text = host.read_file(file)
  if text then
    local ok, store = pcall(json.decode, text)
    local profile = ok and type(store)=="table" and store[provider_id]
    if type(profile)=="table" then
      for _, entry in pairs(profile.models or {}) do
        if entry.id==model then
          return {reasoning=entry.reasoning==true, compat=entry.compat or {},
            levels=entry.thinkingLevelMap, max_output=entry.maxTokens,
            source="pi-model-store"}
        end
      end
    end
  end
  if provider_id=="opencode-go" and windowlib.WINDOWS[model] then
    return {reasoning=true,compat={thinkingFormat="deepseek",maxTokensField="max_tokens",
      requiresReasoningContentOnAssistantMessages=true},
      levels={low="low",high="high",max="max"},max_output=windowlib.WINDOWS[model].output,
      source="pi-compatible-deepseek"}
  end
  return {reasoning=false,compat={},source="unknown"}
end

local function reasoning_key(model)
  return "reasoning." .. host.sha256(M.active().id .. ":" .. model)
end

function M.reasoning(model)
  model = model or M.settings().model
  if M._pinned and M._pinned.settings.model==model then return M._pinned.reasoning end
  local cap = M.capabilities(model)
  local levels = {}
  if cap.reasoning then
    if cap.levels then
      for _, name in ipairs({"off","minimal","low","medium","high","xhigh","max"}) do
        if type(cap.levels[name])=="string" then levels[#levels+1]=name end
      end
    elseif cap.compat.thinkingFormat=="deepseek" then levels={"low","high"}
    elseif cap.compat.supportsReasoningEffort==true then levels={"low","medium","high"} end
  end
  local selected = read_state(reasoning_key(model)) or env("WASM_AGENT_REASONING")
  local valid=false
  for _, level in ipairs(levels) do if level==selected then valid=true end end
  if not valid then
    selected="provider"
    for _, level in ipairs(levels) do if level=="high" then selected=level end end
  end
  -- The store's flag is a claim about the provider, and a conservative one: this provider
  -- accepts an assistant message that carries no reasoning_content at all (measured: both
  -- shapes answered 200), so replaying every prior thought on every request is a choice,
  -- not a requirement. An operator can turn it off; the model still sees its own answers
  -- and its own tool calls.
  --
  -- The choice must stay all-or-nothing, and that is a cache rule, not a taste. A thought
  -- is sent in full during its own turn; a policy that later replaces it with an empty
  -- field changes a message that was already sent, so the provider's longest-common-prefix
  -- ends there and every message after it is recomputed at the full input rate. Measured
  -- with the provider's own prefix_audit: full replay and consistent omission are
  -- `append_only` across turns, while emptying a sent thought is `rewritten`. Input bills
  -- at ~50x the cache-read rate, and the recomputed suffix contains the dropped reasoning,
  -- so a partial replay costs far more than the cached read it saves. Do not add a
  -- "window", "keep the last N thoughts", or any other partial replay: it is a net loss
  -- and it breaks the prefix the cache depends on. The real lever is to produce less
  -- reasoning (`WASM_AGENT_REASONING`), which stays append-only.
  local replay = cap.compat.requiresReasoningContentOnAssistantMessages == true
  local override = env("WASM_AGENT_REASONING_REPLAY")
  if override == "0" or override == "false" then replay = false end
  if override == "1" or override == "true" then replay = true end
  return {supported=#levels>0,levels=levels,selected=selected,source=cap.source,
    configured=read_state(reasoning_key(model)) or env("WASM_AGENT_REASONING"),
    replay=replay}
end

function M.set_reasoning(level)
  local model=M.settings().model
  for _, allowed in ipairs(M.reasoning(model).levels) do
    if level==allowed then write_state(reasoning_key(model),level); return true end
  end
  return nil,"unsupported_reasoning_level"
end

-- Selection changes apply at the next user turn, not halfway through a tool
-- exchange on another worker. Credentials remain only in memory, never telemetry.
function M.pin()
  local profile,settings=M.active(),M.settings()
  local reasoning=M.reasoning(settings.model)
  M._pinned={provider=profile,settings=settings,reasoning=reasoning}
end
function M.unpin() M._pinned=nil end

function M.request_options(model, messages, opts)
  opts=opts or {}
  local cap=M.capabilities(model)
  local reasoning=M.reasoning(model)
  local fields={}
  if reasoning.supported then
    local effort=(cap.levels or {})[reasoning.selected] or reasoning.selected
    if cap.compat.thinkingFormat=="deepseek" then
      fields.thinking={type="enabled"}
      if cap.compat.supportsReasoningEffort~=false then fields.reasoning_effort=effort end
    elseif cap.compat.supportsReasoningEffort==true then fields.reasoning_effort=effort end
  end
  local maximum=tonumber(opts.max_output or env("WASM_AGENT_LLM_MAX_OUTPUT")) or tonumber(cap.max_output)
  local budget=M.budget(model)
  if maximum and maximum>0 then
    local estimate=opts.context_tokens or telemetry.estimate_messages(messages)
    if budget.context>0 then maximum=math.min(maximum,math.max(1,budget.context-estimate-4096)) end
    if budget.output>0 then maximum=math.min(maximum,budget.output) end
    local field=env("WASM_AGENT_LLM_MAX_OUTPUT_FIELD") or cap.compat.maxTokensField or "max_tokens"
    if field~="max_tokens" and field~="max_completion_tokens" then error("invalid_output_cap_field") end
    fields[field]=math.floor(maximum)
  end
  return fields,{reasoning=reasoning,output_limit=maximum,compatibility_source=cap.source}
end

-- Spellings providers use for "the request was too large". A list rather than one regex
-- because there is no shared vocabulary; this is the half of the signal that is legible.
local OVERFLOW_TEXT = {
  "prompt is too long", "request_too_large", "input is too long for requested model",
  "exceeds the context window", "maximum context length", "input token count",
  "maximum prompt length", "reduce the length of the messages",
  "context length exceeded", "context_length_exceeded", "too many tokens",
  "token limit exceeded", "exceeds the maximum allowed input length",
  "exceeds the available context size", "context window exceeds limit",
  "exceeded model token limit", "prompt too long", "range of input length should be",
}

-- Does this provider error mean "the request was too large"?
--
-- The status is the reliable half; the body often is not. This deployment answers a
-- too-large request with a bare `{"model":"deepseek-v4.1-flash"}` and no words at all,
-- so a body-pattern list alone would never fire - and the thread would re-send the same
-- oversized request on every later turn, never answering. The fallback is size: a 400 or
-- 413 on a request that already fills most of the window is an overflow whatever it says.
-- `context_tokens` is the caller's own count and `limit` the window it believes it has;
-- the 3/4 threshold keeps a small malformed request from being mistaken for a large one.
function M.is_overflow_error(problem, context_tokens, limit)
  local text = tostring(problem or ""):lower()
  -- A throttling error that happens to mention tokens is not an overflow.
  if text:find("rate limit", 1, true) or text:find("too many requests", 1, true)
      or text:find("throttl", 1, true) then
    return false
  end
  for _, pattern in ipairs(OVERFLOW_TEXT) do
    if text:find(pattern, 1, true) then return true end
  end
  local status = text:match("provider_http_(%d+)")
  if (status == "400" or status == "413") and (limit or 0) > 0
      and (context_tokens or 0) >= limit * 0.75 then
    return true
  end
  return false
end

-- `stream` forwards content deltas to the UI and still returns the whole
-- message (content + tool_calls + usage) so the tool loop can continue.
function M.complete(messages, tools, stream, opts)
  return M.complete_with(M.settings().model, messages, tools, stream, opts)
end

-- Same, with an explicit model: used by compaction (a cheaper summariser when
-- WASM_AGENT_LLM_SUMMARY_MODEL is set, otherwise the main model).
function M.complete_with(model, messages, tools, stream, opts)
  opts=opts or {}
  local settings = M.settings()
  local provider = M.active()
  local body = { model = model or settings.model, messages = messages }
  -- Pi's output cap and reasoning fields follow the model compatibility contract.
  local fields, effective = M.request_options(body.model,messages,opts)
  for key,value in pairs(fields) do body[key]=value end
  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = "auto"
  end
  for key, value in pairs(M.cache_params(opts)) do body[key] = value end
  if stream then body.stream=true; body.stream_options={include_usage=true} end
  local url = provider.base_url:gsub("/+$", "") .. "/chat/completions"
  local headers, attribution = headers_for(provider, opts.session_id)
  local serialized=json.encode(body)
  local audit_started=telemetry.clock()
  local prefix_comparison=prefix_audit.observe(opts.session_id,opts.kind,body,{
    endpoint=url,session=attribution and attribution.session and headers[attribution.session] or nil})
  local request_meta={model=body.model,provider=provider.id,round=opts.round,
    prefix_audit=prefix_comparison,prefix_audit_ms=math.max(0,telemetry.clock()-audit_started),
    -- Which routing this request used. Recorded because a cache miss and the
    -- routing that produced it have to be readable together: without this the
    -- ledger shows the miss and not the instruction that caused it.
    attribution={host=base_host(provider.base_url) or "",rule=(attribution and attribution.host) or "",
      session_header=(attribution and attribution.session) or "",session_id_present=(opts.session_id or "")~=""},
    settings=effective,request_hash=host.sha256(serialized),request_bytes=#serialized,
    messages=#messages,tools=tools and #tools or 0,
    system_hash=host.sha256(json.encode(messages[1] or {})),
    schema_hash=host.sha256(json.encode(tools or {})),
    prompt_shape=telemetry.prompt_shape(messages,tools),
    system_tokens_estimate=math.ceil(#json.encode(messages[1] or {})/4),
    schema_tokens_estimate=math.ceil(#json.encode(tools or {})/4),
    context_tokens_estimate=opts.context_tokens or telemetry.estimate_messages(messages)+math.ceil(#json.encode(tools or {})/4),
    estimation="text bytes/4 + 1200 per image estimate; provider usage is authoritative",
    runtime=telemetry.runtime(),context=opts.context}
  local span=telemetry.start(opts,opts.kind or "model_call",request_meta)
  local ok,result=pcall(function()
  if stream then
    local result = json.decode(host.http_stream("POST", url, json.encode(headers), serialized))
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
      request_id = result.request_id,
      ttft_ms=result.ttft_ms,
      stream_complete=result.stream_complete,
      -- Stream-termination telemetry, so an incomplete stream can say *how* it ended rather than only that it
      -- did. Computed in the stream reader and forwarded here; without this they are thrown away, which is the
      -- failure mode this project keeps repeating - an instrument placed where nothing reads it.
      termination = result.termination,
      saw_done_sentinel = result.saw_done_sentinel,
      saw_finish_reason = result.saw_finish_reason,
      saw_usage = result.saw_usage,
      malformed_events = result.malformed_events,
      chunks = result.chunks,
      last_delta_kind = result.last_delta_kind,
      max_gap_ms = result.max_gap_ms,
      last_delta_to_end_ms = result.last_delta_to_end_ms,
      ended_silent = result.ended_silent,
    }
  end

  local response = json.decode(host.http("POST", url, json.encode(headers), serialized))
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
    request_id = payload.id,
  }
  end)
  if not ok then
    telemetry.finish(span,{ok=false,error=result,model=body.model,provider=provider.id,
      normalized=telemetry.normalize(nil)})
    error(result)
  end
  local visible=M.visible_text(result.content)
  local has_tools=#(result.tool_calls or {})>0
  local meaningful=has_tools or visible~=""
  local complete=result.finish_reason~="length" and result.stream_complete~=false and meaningful
  local observation=telemetry.finish(span,{ok=complete,model=result.model,
    provider=provider.id,request_id=result.request_id,finish_reason=result.finish_reason,
    usage=result.usage,normalized=telemetry.normalize(result.usage,M.rates(result.model)),
    ttft_ms=result.ttft_ms,stream_complete=result.stream_complete,
    reasoning_bytes=#(result.reasoning or ""),answer_bytes=#(result.content or ""),
    error=not complete and (result.stream_complete==false and "incomplete_stream" or result.finish_reason=="length" and "output_limit_reached" or "empty_reply") or nil})
  result.observation=observation
  result.request_meta=request_meta
  result.span_id=span.id
  return result
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
