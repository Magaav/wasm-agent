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
local subscription = dofile("lua/core/openai_sub.lua")
local vault = dofile("lua/core/vault.lua")

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
--
-- A profile also declares the `transport` it speaks and, where one exists, the `pi_provider` key
-- whose ids it is. That pair is compared against the `api` of a model in pi's store, and it is
-- the only thing that decides servability here; nothing re-lists a catalogue. See M.serves.
--
-- With `WASM_AGENT_VAULT_URL` set (docs/VAULT.md), opencode-go is reached through wa-vault: the base
-- URL is the vault's fixed route and the key is a placeholder the vault replaces, so this process -
-- and the agent's shell, which runs as this process's user - never holds it. The vault wins over the
-- key and base-URL variables on purpose: a node that is vaulted and *also* has the key in its
-- environment has not kept the key from the agent, and the env key is simply not used.
function M.providers()
  local vaulted_go = vault.base("opencode-go")
  return {
    {
      id = "opencode-go",
      label = "opencode-go",
      base_url = vaulted_go or env("WASM_AGENT_LLM_BASE_URL") or env("WASM_AGENT_OPENAI_BASE_URL")
        or "https://opencode.ai/zen/go/v1",
      api_key = vaulted_go and vault.PLACEHOLDER or env("WASM_AGENT_LLM_API_KEY")
        or env("OPENCODE_GO_API_KEY") or env("OPENAI_API_KEY") or "",
      -- The service behind the vault route, for M.attribution_rule.
      upstream_host = vaulted_go and vault.ROUTES["opencode-go"].upstream_host or nil,
      default_model = "deepseek-v4.1-flash",
      -- This client posts /chat/completions to this route. The edge serves some of its ids
      -- over other apis - gpt-6-luna is `openai-responses`, minimax-m3 is
      -- `anthropic-messages` - and those are refused below rather than sent.
      transport = "openai-completions",
      -- The key pi's store publishes this route's ids under. Absent on `gpt` below: nothing here
      -- enumerates api.openai.com, so an id only another route lists stays unknown there.
      pi_provider = "opencode-go",
    },
    {
      id = "gpt",
      label = "gpt",
      base_url = env("OPENAI_BASE_URL") or "https://api.openai.com/v1",
      api_key = env("OPENAI_API_KEY") or "",
      default_model = "gpt-4.1",
      transport = "openai-completions",
    },
    {
      id = "openai-sub", label = "OpenAI subscription",
      base_url = "https://chatgpt.com/backend-api",
      api_key = "", auth = "subscription", configured = subscription.configured(),
      default_model = "gpt-6-luna",
      -- Pi's bridge speaks the codex responses transport; this route has no catalogue here.
      -- `subscription.models` is a three-id *picker* list, not this route's catalogue, and
      -- refusing everything it omits blocked five ids the route serves (gpt-5.5, gpt-5.6-luna,
      -- gpt-5.6-sol, gpt-5.6-terra, gpt-5.3-codex-spark). Never derive a refusal from it again.
      transport = "openai-codex-responses",
      pi_provider = "openai-codex",
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

-- The model a route remembers, and whether it came from the environment.
--
-- `model.<provider>` and the in-memory override belong to the route they were chosen on, and
-- there is one node-wide provider switch, so a value left behind by the route you left is the
-- ordinary case rather than a broken file. `WASM_AGENT_LLM_MODEL` is separated out because it
-- is an operator pin, not a remembered selection: a pin that cannot run must stay a loud
-- pre-request refusal (M.unservable), never something quietly replaced.
local function remembered_model(provider)
  local remembered = (M.overrides and M.overrides[provider.id]) or read_state("model." .. provider.id)
  if remembered then return remembered, false end
  if provider.id == "opencode-go" then
    local pinned = env("WASM_AGENT_LLM_MODEL")
    if pinned then return pinned, true end
  end
  return nil, false
end

function M.settings()
  if M._pinned then return M._pinned.settings end
  local provider = M.active()
  local model, from_env = remembered_model(provider)
  -- A model the active route cannot serve is reported and not used. Presenting it would make
  -- every reader - the picker, the reasoning levels, the next request - describe the route the
  -- selection came from, which is how "switched to opencode-go" still showed a subscription
  -- model and reasoning. The route falls back to its own default, and `model_error` names the
  -- value that was refused so the operator can see and repair it.
  local model_error
  if model and not from_env and M.serves(model, provider) == false then
    model_error = M.unservable(model, provider)
    model = nil
  end
  model = model or provider.default_model
  return {
    provider = provider.id,
    label = provider.label,
    base_url = provider.base_url,
    api_key = provider.api_key,
    model = model,
    model_error = model_error,
    default_model = provider.default_model,
  }
end

function M.configured()
  if M.active().id == "openai-sub" then return subscription.configured() end
  local settings = M.settings()
  return settings.base_url ~= "" and settings.api_key ~= "" and settings.model ~= ""
end

function M.set_provider(id, revision)
  local result = state.mutate(function()
  id = trim(id)
  for _, provider in ipairs(M.providers()) do
    if provider.id == id then
      write_state("provider", id)
      -- The selection cache is process memory, not part of the route: dropping it here is what
      -- makes a switch read the new route's own persisted value, and what lets a repair of the
      -- state file become visible to an interpreter that had cached the old one.
      M.provider_override = nil
      M.overrides = nil
      return {ok=true}
    end
  end
  return {ok=false,error="unknown_provider"}
  end, revision)
  return result.ok, result.error
end

function M.set_model(name, revision)
  local result = state.mutate(function()
  name = trim(name)
  if name == "" then return {ok=false,error="empty_model"} end
  local provider = M.active()
  -- Reject a known protocol mismatch before persisting it. Unknown catalogue
  -- entries remain allowed, exactly as on the request path.
  local problem = M.unservable(name, provider)
  if problem then return {ok=false,error=problem} end
  write_state("model." .. provider.id, name)
  M.overrides = nil
  return {ok=true}
  end, revision)
  return result.ok, result.error
end

-- What a route can serve, decided by protocol.
--
-- The deciding fact is the PROTOCOL, not ownership. `gpt-6-luna` is catalogued for opencode-go
-- *and* openai-codex, and on the opencode-go route its `api` is `openai-responses` while this
-- client posts /chat/completions - which is precisely what the edge answered in 0.67s,
-- `Model does not support this protocol`. The first version of this check instead asked which
-- route "owns" an id, which is false on its face, and it read that ownership from
-- `subscription.models` - a three-id picker list this file does not own - so it refused five ids
-- the subscription route serves. A catalogue re-listed here is the defect; there is none below.
--
-- The catalogue is read where it actually lives: pi's local model store
-- (~/.pi/agent/models-store.json, the file M.capabilities already reads and the one the
-- subscription bridge resolves ids against - `models.getModel('openai-codex', id)`). Every entry
-- carries the `api` that id is served over. This client speaks exactly one transport per route:
-- the route's `transport` below.
--
-- A model the store does not mention is *unsaid*, not refused: the predicate answers nil and the
-- preflight lets it through. That floor matters as much as the refusal - an absent or silent
-- store must never block a run, which is how the hardcoded version shipped a regression. The one
-- thing this cannot see is a store stale in the other direction: if the edge starts serving an id
-- over a protocol it previously did not, pi's store is what has to be updated - which is the
-- point of reading it here instead of re-listing it.

-- pi's local model store, keyed by pi's own provider id. Read, never written. Kept briefly: the
-- picker asks the servability question once per offered id, and every answer reads this file, so
-- an uncached store would be tens of file reads per refresh. A missing or unreadable store is
-- never cached, so a transient failure cannot stick, and a refresh is picked up within the window.
local store_cache
local function pi_store()
  local file = env("WASM_AGENT_PI_MODELS_STORE")
    or (dofile("lua/core/paths.lua").home() .. "/.pi/agent/models-store.json")
  local now = (host and host.now and host.now()) or 0
  if store_cache and store_cache.file == file and (now - store_cache.at) < 5 then
    return store_cache.store
  end
  local text = host.read_file(file)
  if not text then return nil end
  local ok, store = pcall(json.decode, text)
  if not ok or type(store) ~= "table" then return nil end
  store_cache = { file = file, at = now, store = store }
  return store
end

-- Every `{provider, api}` the store publishes for `model`. Empty when the store is absent,
-- unreadable, or silent about the id - the three cases that must stay unknown rather than
-- become a refusal.
local function catalogue_protocols(model)
  local store = pi_store()
  if not store then return {} end
  local found = {}
  for key, profile in pairs(store) do
    for _, entry in pairs(type(profile) == "table" and profile.models or {}) do
      if type(entry) == "table" and entry.id == model and type(entry.api) == "string" then
        found[#found + 1] = { provider = tostring(key), api = entry.api }
      end
    end
  end
  return found
end

-- What this client actually sends over each transport, for the refusal to name.
local TRANSPORT_WIRE = {
  ["openai-completions"] = "POST /chat/completions",
  -- The subscription route's transport is wasm-agent's own Responses wire
  -- (lua/core/subscription_wire.lua) unless WASM_AGENT_SUBSCRIPTION_TRANSPORT=pi, in which case it
  -- is still Pi's adapter. The refusal names the wire, because which client speaks a protocol is
  -- part of the reason a model was refused.
  ["openai-codex-responses"] = "the subscription Responses wire (codex/responses)",
}

-- Can `provider` (default: the active route) serve `model`? `true` = this route's own catalogue
-- publishes the id over the transport this route speaks; `false` = it is published (by this route
-- or another, over another protocol) and nothing publishes it over a protocol this client speaks
-- here; `nil` = not decided - the store is absent, silent, or the id is only another route's,
-- which is not a refusal. It never substitutes another model or another provider.
function M.serves(model, provider)
  provider = provider or M.active()
  model = trim(model or "")
  if model == "" then return nil end
  local protocols = catalogue_protocols(model)
  if #protocols == 0 then return nil end
  local own_published, reachable_elsewhere = false, false
  for _, entry in ipairs(protocols) do
    local own = provider.pi_provider ~= nil and entry.provider == provider.pi_provider
    if own then
      if entry.api == provider.transport then return true end
      own_published = true
    elseif entry.api == provider.transport then
      -- Another route serves the id over a protocol this one speaks, and this route's own
      -- catalogue says nothing. That is unknown here, not a claim in either direction.
      reachable_elsewhere = true
    end
  end
  if own_published or not reachable_elsewhere then return false end
  return nil
end

-- The refusal to raise for `model` on `provider`, or nil when the request may be prepared. The
-- text is stable - a fixed prefix, then `provider=<id>` and `model=<id>` - because it is what a
-- refused run or child reports, and a reader has to be able to match it. It states the real
-- reason: which protocol the id is served over, and which one this route speaks.
-- Serving observations live in SQLite, not selection files or prompts. This small
-- availability component is contained here so existing embedded hosts include it.
local function serving_sql(verb, statement, params)
  local value = host[verb](statement, json.encode(params or {}))
  if type(value)=='string' then value=json.decode(value) end
  if not value or value.error then error('provider_availability_store') end
  return value
end
local function serving_binding(provider)
  -- Profile is an operator-declared non-secret account label; keys never enter
  -- this binding. Rotation cannot evade a recorded block. Unlabelled accounts
  -- conservatively share the configured route's default profile.
  -- Account/profile is the authority, not an endpoint spelling. Equivalent
  -- hosts, default ports, path normalization and trailing slashes cannot reset
  -- account exhaustion. Changing endpoints is not verified account recovery.
  return host.sha256(json.encode({state.dir(), provider.id,
    env('WASM_AGENT_PROVIDER_ACCOUNT_PROFILE') or 'default'}))
end
local function serving_setup()
  serving_sql('sql_exec', 'CREATE TABLE IF NOT EXISTS provider_serving(binding TEXT PRIMARY KEY,state TEXT NOT NULL,reason TEXT NOT NULL,model TEXT NOT NULL)')
  local columns=serving_sql('sql_query','PRAGMA table_info(provider_serving)')
  for _,column in ipairs(columns) do if column.name=='generation' then return end end
  -- Additive migration keeps valid predecessor observations and their bindings.
  local ok,problem=pcall(serving_sql,'sql_exec','ALTER TABLE provider_serving ADD COLUMN generation INTEGER NOT NULL DEFAULT 0')
  if not ok then
    for _,column in ipairs(serving_sql('sql_query','PRAGMA table_info(provider_serving)')) do
      if column.name=='generation' then return end
    end
    error(problem)
  end
end
local function valid_serving(row)
  if type(row.generation)~='number' or row.generation<0 or row.generation%1~=0 or type(row.model)~='string' then return false end
  return (row.state=='blocked' and row.reason=='provider_monthly_quota' and row.model~='') or
    (row.state=='observed_serving' and row.reason=='authenticated_success' and row.model~='') or
    (row.state=='unknown' and (row.reason=='request_pending' or row.reason=='verified_recovery') and row.model=='')
end
function M.serving(model, provider)
  provider=provider or M.active()
  if not host.sql_query then return {state='unknown'} end
  serving_setup()
  local row=serving_sql('sql_query','SELECT state,reason,model,generation FROM provider_serving WHERE binding=?',{serving_binding(provider)})[1]
  if row and not valid_serving(row) then return {state='blocked',reason='provider_eligibility_corrupt'} end
  return row or {state='unknown'}
end
local function serving_request(provider, model)
  if not host.sql_query then return nil end
  serving_setup()
  local binding=serving_binding(provider)
  serving_sql('sql_exec',"INSERT OR IGNORE INTO provider_serving(binding,state,reason,model,generation) VALUES(?,'unknown','request_pending','',0)",{binding})
  local observed=M.serving(model,provider)
  if observed.state=='blocked' then error(observed.reason) end
  return {binding=binding,provider=provider.id,model=model,endpoint=provider.base_url:gsub('/+$',''),
    generation=observed.generation,state=observed.state,reason=observed.reason,observed_model=observed.model}
end
-- Only call at the real authenticated HTTP result seam; never with transcript
-- prose, tool output, catalogue responses or a stringified exception.
local function record_serving_http(provider, model, response, request)
  if not host.sql_query or provider.api_key=='' or response.error then return end
  if provider.id~='opencode-go' or tonumber(response.status)~=429 then return end
  local ok,payload=pcall(json.decode,response.body or '')
  local problem=ok and type(payload)=='table' and payload.error
  if type(problem)~='table' or problem.type~='GoUsageLimitError' or
      type(problem.metadata)~='table' or problem.metadata.limitName~='monthly' then return end
  serving_setup()
  serving_sql('sql_exec',"INSERT INTO provider_serving(binding,state,reason,model,generation) VALUES(?,'blocked','provider_monthly_quota',?,1) ON CONFLICT(binding) DO UPDATE SET state=excluded.state,reason=excluded.reason,model=excluded.model,generation=provider_serving.generation+1",
    {request.binding,model})
end
-- Internal operator recovery seam, not a model tool. The caller must verify
-- recovery independently and supply the exact binding returned by this function.
function M.serving_binding() return serving_binding(M.active()) end
-- Control-only identity discovery, separate from the eligibility observation.
function M.serving_identity(model, requested_provider)
  local active=M.active()
  if requested_provider and requested_provider~=active.id then return nil,'provider_route_unavailable' end
  local identity=json.decode(host.node_identity())
  local observation=M.serving(model,active)
  return {node_id=identity.node_id,model=model or M.settings().model,provider=active.id,
    account_profile=env('WASM_AGENT_PROVIDER_ACCOUNT_PROFILE') or 'default',
    binding=serving_binding(active),generation=observation.generation or 0}
end
function M.serving_status(requested)
  if type(requested)~='table' then return {state='unknown',reason='serving_identity_required'} end
  local current,problem=M.serving_identity(requested.model,requested.provider)
  if not current then return {state='unknown',reason=problem} end
  for _,key in ipairs({'node_id','model','provider','account_profile','binding','generation'}) do
    if current[key]~=requested[key] then return {state='unknown',reason='serving_identity_changed'} end
  end
  local value=M.serving(requested.model)
  if (value.generation or 0)~=current.generation then return {state='unknown',reason='serving_identity_changed'} end
  -- The row's model describes the last observation; quota is account-wide.
  value.observed_model=value.model
  for key,field in pairs(current) do value[key]=field end
  return value
end
function M.recover_serving(binding, evidence, operator_verified)
  if operator_verified~=true or binding~=M.serving_binding() or type(evidence)~='string' or evidence=='' then
    return {error='provider_recovery_not_verified'}
  end
  serving_setup()
  serving_sql('sql_exec',"INSERT INTO provider_serving(binding,state,reason,model,generation) VALUES(?,'unknown','verified_recovery','',1) ON CONFLICT(binding) DO UPDATE SET state='unknown',reason='verified_recovery',model='',generation=CASE WHEN typeof(provider_serving.generation)='integer' AND provider_serving.generation>=0 THEN provider_serving.generation+1 ELSE 1 END",{binding})
  return {ok=true,state='unknown'}
end
local function record_serving_success(provider, model, request, result)
  if not request or result.serving_response_model~=model or
      (result.finish_reason~='stop' and result.finish_reason~='tool_calls' and result.finish_reason~='function_call') then return end
  local active=M.active()
  if serving_binding(active)~=request.binding or active.id~=request.provider or
      active.base_url:gsub('/+$','')~=request.endpoint then return end
  -- A result owns only the snapshot preceding its request. A later block or
  -- recovery wins, including across processes and recovery/unknown ABA cycles.
  serving_sql('sql_exec',"UPDATE provider_serving SET state='observed_serving',reason='authenticated_success',model=?,generation=generation+1 WHERE binding=? AND generation=? AND state=? AND reason=? AND model=?",
    {model,request.binding,request.generation,request.state,request.reason,request.observed_model})
end
function M.unservable(model, provider)
  local availability=M.serving(model,provider)
  if availability.state=='blocked' then return availability.reason end
  provider = provider or M.active()
  model = trim(model or "")
  if model == "" or M.serves(model, provider) ~= false then return nil end
  local served_over, seen = {}, {}
  for _, entry in ipairs(catalogue_protocols(model)) do
    local where = (provider.pi_provider ~= nil and entry.provider == provider.pi_provider)
      and "this route" or ("route " .. entry.provider)
    local label = entry.api .. " (" .. where .. ")"
    if not seen[label] then seen[label] = true; served_over[#served_over + 1] = label end
  end
  -- Sorted, because the store is walked with `pairs` and a refusal a reader has to match must
  -- read the same way twice.
  table.sort(served_over)
  local transport = tostring(provider.transport)
  return "model_not_servable: provider=" .. provider.id .. " cannot serve model=" .. model ..
    "; the catalogue serves this id over " .. table.concat(served_over, ", ") ..
    " and this route speaks " .. transport .. " (" .. (TRANSPORT_WIRE[transport] or transport) .. ")" ..
    "; refused before the first provider request, nothing substituted"
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
  { host = "chatgpt.com" }, -- Pi's subscription adapter owns its account/session headers.
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
  -- A vaulted profile reaches its service through wa-vault, so the base URL names the vault; the
  -- service's headers are still the service's, and `upstream_host` says which service that is.
  local host = (provider and provider.upstream_host) or base_host(provider and provider.base_url)
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
  if provider.id == "openai-sub" then return subscription.models end
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
            if type(item) == "table" and type(item.id) == "string"
                and M.serves(item.id, provider) ~= false then
              models[#models + 1] = item.id
            end
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
  local configured = provider.id == "openai-sub" and subscription.configured() or provider.api_key ~= ""
  if not configured then return {}, "provider not configured" end
  local now = (host and host.now and host.now()) or 0
  local cache_key = provider.id .. "\n" .. provider.base_url
  if M._limits and M._limits_key == cache_key and (now - (M._limits_at or 0)) < 30 then
    return M._limits, M._limits_error
  end
  local limits = {}
  local ok, err = pcall(function()
    if provider.id == "openai-sub" then
      limits = subscription.limits()
    else
      local url = provider.base_url:gsub("/+$", "") .. "/usage"
      local headers = headers_for(provider)
      local response = json.decode(host.http("GET", url, json.encode(headers), ""))
      if response and tonumber(response.status) == 200 then
        local ok, payload = pcall(json.decode, response.body)
        if ok and type(payload) == "table" and type(payload.usage) == "table" then
          limits = payload.usage
        end
      end
    end
  end)
  M._limits = limits
  M._limits_error = nil
  if not ok then M._limits_error = redact.text(tostring(err)) end
  M._limits_key = cache_key
  M._limits_at = now
  return limits, M._limits_error
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
  if M.active().id=="openai-sub" then
    window={context=272000,output=128000,source="pi-openai-codex"}
  end
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
  if provider_id == "openai-sub" then
    -- The route's shipped declaration, and what the catalogue publishes for this id on top of
    -- it. Both, not the catalogue alone: Pi marks a level an id does not honour with `null` in
    -- the map, and this decoder drops a null (lua/vendor/json.lua: literal_map null=nil), so a
    -- `null` mapping is indistinguishable here from a level the map simply does not list - which
    -- Pi honours by passing it through. Deciding from the map alone would refuse levels this
    -- route accepts today (gpt-5.6-luna publishes only {minimal,xhigh,max} and honours the
    -- rest). The union cannot refuse a level either source names, and it can never come out
    -- empty - an empty set is what refuses *every* level a child can be given, and a child
    -- always carries one. The store is read, never written, and the same file the bridge
    -- resolves ids against and the preflight decides servability from.
    local levels={low="low",medium="medium",high="high",xhigh="xhigh",max="max"}
    if model~="gpt-6-astra" then levels.off="none" end
    local published = subscription.thinking_level_map(model)
    -- The windows come from the same catalogue, per id: an id the route serves at a different
    -- output ceiling must not be described by the route's largest one.
    local window = subscription.catalogue().window(model)
    local max_output = window and window.max_output or 128000
    if published then
      for level, value in pairs(published) do
        if type(value)=="string" then levels[level]=value end
      end
      return {reasoning=true, levels=levels, compat={}, max_output=max_output,
        source="openai-sub-catalogue"}
    end
    -- nil from the catalogue is "cannot answer", not "no levels": the shipped declaration stands,
    -- so a route that cannot describe an id still describes itself.
    return {reasoning=true, levels=levels, compat={}, max_output=max_output,
      source="openai-sub-route"}
  end
  local store = pi_store()
  local profile = store and store[provider_id]
  if type(profile)=="table" then
    for _, entry in pairs(profile.models or {}) do
      if entry.id==model then
        return {reasoning=entry.reasoning==true, compat=entry.compat or {},
          levels=entry.thinkingLevelMap, max_output=entry.maxTokens,
          source="pi-model-store"}
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

function M.set_reasoning(level, revision)
  local result = state.mutate(function()
  local model=M.settings().model
  for _, allowed in ipairs(M.reasoning(model).levels) do
    if level==allowed then write_state(reasoning_key(model),level); return {ok=true} end
  end
  return {ok=false,error="unsupported_reasoning_level"}
  end, revision)
  return result.ok, result.error
end

-- Selection changes apply at the next user turn, not halfway through a tool
-- exchange on another worker. Credentials remain only in memory, never telemetry.
function M.pin()
  state.with_snapshot(function()
  local profile,settings=M.active(),M.settings()
  local reasoning=M.reasoning(settings.model)
  M._pinned={provider=profile,settings=settings,reasoning=reasoning}
  M._pinned.revision=state.revision()
  end)
end
function M.unpin() M._pinned=nil end

function M.selection_revision() return M._pinned and M._pinned.revision or state.revision() end
function M.with_selection(fn) return state.with_snapshot(fn) end

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

-- A request that never received response headers cannot have returned a tool call for this process
-- to execute. That makes it the one provider timeout safe enough for a bounded replay. It is still
-- possible the upstream completed and billed the inference before its edge lost the response, so the
-- retry count is explicit and operator-disableable rather than a general retry policy.
function M.is_response_timeout(problem)
  return tostring(problem or ""):lower():find("provider_error: timeout: receive response", 1, true) ~= nil
end

function M.response_timeout_retries()
  local raw = env("WASM_AGENT_PROVIDER_RESPONSE_RETRIES")
  if raw == nil or trim(raw) == "" then return 1 end
  local count = tonumber(raw)
  if not count then return 1 end
  return math.max(0, math.min(3, math.floor(count)))
end

-- A failure the provider may not repeat if asked again a little later: rate limiting, an overloaded
-- or restarting upstream, a dropped connection, a stream cut before it finished. None of these returned
-- a tool call that ran, so replaying the same request is safe. A monthly-quota 429 is not retried here:
-- `record_serving_http` marks the route blocked and the next attempt is refused before it is sent.
local TRANSIENT_STATUS = { ["408"]=true, ["409"]=true, ["425"]=true, ["429"]=true, ["500"]=true,
  ["502"]=true, ["503"]=true, ["504"]=true, ["529"]=true }
local TRANSIENT_TEXT = { "connection reset", "connection refused", "broken pipe", "timed out", "timeout",
  "connection closed", "unexpected eof", "dns", "temporarily unavailable", "overloaded" }

function M.is_transient(problem)
  local text = tostring(problem or ""):lower()
  -- Lost response headers have their own, deliberately smaller budget (`response_timeout_retries`).
  if M.is_response_timeout(text) then return false end
  -- Errors arrive with Lua's `file:line:` prefixes, so the markers are found, not anchored.
  local status = text:match("provider_http_(%d+)") or text:match("subscription_http_(%d+)")
  if status then return TRANSIENT_STATUS[status] == true end
  if text:find("subscription_transport_", 1, true) then return true end
  if text:find("provider_error:", 1, true) then
    for _, pattern in ipairs(TRANSIENT_TEXT) do
      if text:find(pattern, 1, true) then return true end
    end
  end
  return false
end

-- How many times a transient failure is retried, with exponential backoff (2, 4, 8, 16 s, jittered).
function M.transient_retries()
  local count = tonumber(env("WASM_AGENT_PROVIDER_RETRIES") or "")
  if not count then return 4 end
  return math.max(0, math.min(8, math.floor(count)))
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
  -- Servability comes first, before `request_options`, the URL, the headers and the ledger
  -- span exist: a model this route cannot serve is refused here, so no bytes leave and no
  -- provider call is spent on a request that was already doomed. See M.unservable.
  local refusal = M.unservable(body.model, provider)
  if refusal then error(refusal) end
  local serving_request_binding=serving_request(provider,body.model)
  -- Pi's output cap and reasoning fields follow the model compatibility contract.
  local fields, effective = M.request_options(body.model,messages,opts)
  for key,value in pairs(fields) do body[key]=value end
  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = "auto"
  end
  for key, value in pairs(M.cache_params(opts)) do body[key] = value end
  if stream then body.stream=true; body.stream_options={include_usage=true} end
  local url = provider.base_url:gsub("/+$", "") ..
    (provider.id=="openai-sub" and "/codex/responses" or "/chat/completions")
  local headers, attribution = headers_for(provider, opts.session_id)
  local serialized=json.encode(body)
  local audit_started=telemetry.clock()
  local prefix_comparison=prefix_audit.observe(opts.session_id,opts.kind,body,{
    endpoint=url,session=attribution and attribution.session and headers[attribution.session] or nil})
  -- `round` names the decision step; `attempt` counts response-timeout replays.
  -- An overflow-recovery retry may keep that attempt number while changing the
  -- prepared request; the span/request hash, not (round, attempt), identifies it.
  local request_meta={model=body.model,provider=provider.id,round=opts.round,
    attempt=tonumber(opts.attempt) or 1,
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
  if provider.id=="openai-sub" then
    -- Which client assembled the wire request, recorded per request: a hash of the body means
    -- something different when the body is ours and when Pi built it from the same input.
    if subscription.transport()=="native" then
      request_meta.transport="native-codex-responses"
      request_meta.request_hash_source="lua/core/subscription_wire.lua builds the provider request"
    else
      request_meta.transport="pi-openai-codex-responses"
      request_meta.request_hash_source="bridge input; Pi assembles the provider wire request"
    end
  end
  local span=telemetry.start(opts,opts.kind or "model_call",request_meta)
  local ok,result=pcall(function()
  if provider.id=="openai-sub" then
    local bridge_opts={}
    for key,value in pairs(opts) do bridge_opts[key]=value end
    bridge_opts.max_output=effective.output_limit
    return subscription.complete(body.model,messages,tools,stream,bridge_opts,effective.reasoning)
  end
  if stream then
    local result = json.decode(host.http_stream("POST", url, json.encode(headers), serialized))
    record_serving_http(provider,body.model,result,serving_request_binding)
    if result.error then error(redact.text("provider_error: " .. tostring(result.error))) end
    if result.status ~= 200 then
      error(redact.text("provider_http_" .. tostring(result.status) .. ": " .. tostring(result.body):sub(1, 240)))
    end
    return {
      content = result.content or "",
      commentary = result.commentary or "",
      commentary_streamed = stream and result.commentary ~= "" and "delta" or false,
      final_phase = result.final_phase or "",
      reasoning = result.reasoning or "",
      finish_reason = result.finish_reason,
      tool_calls = result.tool_calls or {},
      usage = result.usage,
      model = body.model,
      serving_response_model = result.model,
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
  record_serving_http(provider,body.model,response,serving_request_binding)
  if response.error then error(redact.text("provider_error: " .. tostring(response.error))) end
  if response.status ~= 200 then
    error(redact.text("provider_http_" .. tostring(response.status) .. ": " .. tostring(response.body):sub(1, 240)))
  end
  local payload = json.decode(response.body)
  local message = payload.choices[1].message
  local phase = message.phase or ""
  return {
    content = phase == "commentary" and "" or message.content or "",
    commentary = phase == "commentary" and (message.content or "") or "",
    final_phase = phase == "final_answer" and phase or "",
    reasoning = M.reasoning_of(message),
    finish_reason = payload.choices[1].finish_reason,
    tool_calls = message.tool_calls or {},
    usage = payload.usage,
    model = payload.model or body.model,
    serving_response_model = payload.model,
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
  if complete and (provider.auth=='subscription' or provider.api_key~='') then
    record_serving_success(provider,body.model,serving_request_binding,result)
  end
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
