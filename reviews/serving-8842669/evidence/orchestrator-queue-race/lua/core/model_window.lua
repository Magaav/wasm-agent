-- Per-model context windows, and where they come from.
--
-- The bug this replaces: the window was a single global (`WASM_AGENT_LLM_CONTEXT`), so
-- every model was told the same number regardless of which model was answering. Set to
-- 128000 for a model whose window is 1000000, compaction fired at ~96000 tokens instead
-- of ~967000 - the agent summarised away most of its own working memory, ten times too
-- early, and did it invisibly, because "compacted" is not an error.
--
-- pi does not have this problem because the window is a property of the *model*, looked up
-- by name. So the fix is not a bigger number, it is the right shape.
--
-- Where the number comes from, and why it is a chain rather than one source:
--
--   The provider's own `/models` endpoint does NOT publish windows. Verified against this
--   deployment: 37 models listed, each only {id, object, created, owned_by}, and not one
--   `context` field anywhere in the payload. So "just ask the API" does not work, and a
--   per-model table is not laziness - there is nowhere else to look for a model the
--   catalogue has not seen.
--
--   `models.dev/api.json` does publish them (`limit.context`, `limit.output`), and it is
--   where pi's numbers come from: its entry for kimi-k2.6 is 262144, exactly what this
--   repo's test.sh hardcoded. It is the real source, fetched once and cached, because it
--   is 4.7MB and must not be fetched per turn.
--
--   It is not complete either. deepseek-v4.1-flash - the model actually in use here -
--   is in pi's store; at the time of writing the catalogue did not list it, and it does
--   now, so a chain that assumed the catalogue was total would have been wrong in the
--   direction that matters least and still wrong. Ordering store-first is about cost, not
--   about coverage: the store is a local file, the catalogue is 4.7MB over the network.
--
-- Resolution order, most specific first:
--   1. `WASM_AGENT_MODEL_LIMITS` JSON, per model - the operator's explicit override.
--   2. pi's local model store (~/.pi/agent/models-store.json), which is local and cheap.
--   3. the fetched catalogue cache (~/.wasm-agent/cache/models-dev.json).
--   4. the small table below, so a cold cache offline still knows common models.
--   5. `WASM_AGENT_LLM_CONTEXT` - the old global, kept so nothing breaks.
--   6. 0, meaning "unknown", and callers must treat unknown as unknown.
--
-- Every answer carries its `source`, so a limit can be checked rather than trusted.

local json = dofile("lua/vendor/json.lua")
-- `host` is a global injected by the wa host, not a Lua module: require("host") resolves
-- in the embedded build but not on the disk-loaded path, which is exactly where a test
-- would catch it. Referred to lazily through host.getenv below so a stub can replace it.
local host = host
local paths = dofile("lua/core/paths.lua")

local M = {}

-- Offline fallback for the common models, so a cold cache with no network still gets these
-- right instead of falling back to the global. Values below are the ones the catalogue and
-- pi's store agree on; anything doubtful is left out, because unknown is visible and a
-- guess is not.
M.WINDOWS = {
  ["deepseek-v4.1-flash"] = { context = 1000000, output = 384000 },
  ["deepseek-v4-flash"]   = { context = 1000000, output = 384000 },
  ["deepseek-v4-pro"]     = { context = 1000000, output = 384000 },
}

-- pi's policy numbers, unchanged: reserve the reply, keep the recent work verbatim.
M.RESERVE = 16384
M.KEEP = 20000
-- A large window also needs a proportional reserve. The catalogue's window is a *claim*, not a
-- measurement: this deployment publishes 1,000,000 for deepseek-v4.1-flash and rejects a request
-- at roughly 950,000. A fixed 16k reserve puts the compaction trigger (983,616) above the
-- provider's real ceiling, so compaction never fires and the request is rejected instead. Ten
-- percent keeps the trigger below the wall while staying far above the recent work; a small
-- window is unchanged, because 16k already exceeds ten percent of it.
M.RESERVE_FRACTION = 0.10

-- The catalogue changes on the order of weeks, not runs. A day is generous and keeps the
-- 4.7MB fetch off the hot path; `nodes.lua` uses 15s for the rendezvous, which is a
-- different thing (liveness) and not a model here.
local CATALOGUE_TTL = 86400
local catalogue, catalogue_at = nil, 0

local function read_file(path)
  local ok, text = pcall(host.read_file, path)
  if ok and type(text) == "string" and text ~= "" then return text end
  return nil
end

-- The catalogue cache. Read from disk when it is there, and **fetched only when a caller asks
-- for it**: see `allow_fetch` below. Never fatal - a node with no network keeps whatever it had.
local function fetch_catalogue(opts)
  local allow_fetch = type(opts) == "table" and opts.allow_fetch == true
  local now = host.now and host.now() or 0
  if catalogue and (now - catalogue_at) < CATALOGUE_TTL then return catalogue end

  local cache_path = paths.cache() .. "/models-dev.json"
  if not catalogue then
    local cached = read_file(cache_path)
    if cached then
      local ok, parsed = pcall(json.decode, cached)
      if ok and type(parsed) == "table" then
        catalogue, catalogue_at = parsed, now
      end
    end
  end

  local url = host.getenv("WASM_AGENT_MODELS_CATALOGUE")
  if url == nil or url == "" then url = "https://models.dev/api.json" end
  if url == "off" then return catalogue end

  -- A request path must not download 4.7MB. `budget` runs inside /models, the account balloon
  -- and compaction, so a cold cache used to turn the first request after a fresh install into
  -- that download, on the one thread that owns the interpreter: the request blocked, everything
  -- behind it queued, and the node looked wedged while /health kept answering. The fetch happens
  -- where it is asked for instead - `refresh()`, and the UI's own refresh - and until one has
  -- succeeded the window comes from the shipped table, whose answer says `shipped` rather than
  -- pretending the catalogue was consulted.
  if not allow_fetch then return catalogue end

  if not catalogue or (now - catalogue_at) >= CATALOGUE_TTL then
    pcall(function()
      local headers = json.encode({ ["Accept"] = "application/json",
                                    ["User-Agent"] = "wasm-agent/0.1 model-window" })
      local response = json.decode(host.http("GET", url, headers, ""))
      if response and tonumber(response.status) == 200 and type(response.body) == "string" then
        local ok, parsed = pcall(json.decode, response.body)
        if ok and type(parsed) == "table" and next(parsed) then
          catalogue, catalogue_at = parsed, now
          pcall(host.write_file, cache_path, response.body)
        end
      end
    end)
  end
  return catalogue
end

-- Look a model up in the catalogue. The provider's own id is tried first, then the two
-- names it is published under, because the endpoint's id and the catalogue's provider key
-- are not guaranteed to be the same string.
local function from_catalogue(model)
  if not model or model == "" then return nil end
  local cat = fetch_catalogue()
  if type(cat) ~= "table" then return nil end
  local keys = {}
  local configured = host.getenv("WASM_AGENT_LLM_CATALOGUE_PROVIDER")
  if configured and configured ~= "" then keys[#keys + 1] = configured end
  for _, name in ipairs({ "opencode", "opencode-go", "opencode-zen" }) do keys[#keys + 1] = name end
  for _, provider in ipairs(keys) do
    local entry = cat[provider]
    local m = type(entry) == "table" and entry.models and entry.models[model] or nil
    local limit = type(m) == "table" and m.limit or nil
    if type(limit) == "table" and tonumber(limit.context) then
      return { context = tonumber(limit.context), output = tonumber(limit.output) }
    end
  end
  return nil
end

-- pi's local store. Cheaper than the network and it is where unreleased models live - the
-- model this bug was found on is here and nowhere else.
local function from_pi_store(model)
  if not model or model == "" then return nil end
  -- A test can point this somewhere else, and when it does that is the *only* store
  -- consulted: appending the real one after it meant a test that set this to an empty
  -- object still got pi's answers, so the hook could not do what it claimed.
  local override = host.getenv("WASM_AGENT_PI_MODELS_STORE")
  local candidates = {}
  if override and override ~= "" then
    candidates[1] = override
  else
    local home = host.getenv("HOME") or ""
    if home ~= "" then
      candidates[1] = home .. "/.pi/agent/models-store.json"
    end
  end
  for _, path in ipairs(candidates) do
    local text = read_file(path)
    if text then
      local ok, parsed = pcall(json.decode, text)
      if ok and type(parsed) == "table" then
        for _, provider in pairs(parsed) do
          local models = type(provider) == "table" and provider.models or nil
          if type(models) == "table" then
            for _, entry in pairs(models) do
              if type(entry) == "table" and entry.id == model and tonumber(entry.contextWindow) then
                return { context = tonumber(entry.contextWindow), output = tonumber(entry.maxTokens) }
              end
            end
          end
        end
      end
    end
  end
  return nil
end

function M.for_model(model)
  local context, output, source

  -- 1. the operator's explicit override
  local raw = host.getenv("WASM_AGENT_MODEL_LIMITS")
  if raw and raw ~= "" and model and model ~= "" then
    local ok, parsed = pcall(json.decode, raw)
    local entry = ok and type(parsed) == "table" and parsed[model] or nil
    if type(entry) == "table" and tonumber(entry.context) then
      context, output, source = tonumber(entry.context), tonumber(entry.output), "env-WASM_AGENT_MODEL_LIMITS"
    end
  end

  -- 2. pi's store: local, and the only place an unreleased model appears
  if not context then
    local found = from_pi_store(model)
    if found and found.context then
      context, output, source = found.context, found.output, "pi-model-store"
    end
  end

  -- 3. the fetched catalogue
  if not context then
    local found = from_catalogue(model)
    if found and found.context then
      context, output, source = found.context, found.output, "models-dev-catalogue"
    end
  end

  -- 4. the shipped table, for a cold cache offline
  if not context then
    local known = M.WINDOWS[model or ""]
    if known then context, output, source = known.context, known.output, "known-model" end
  end

  -- 5. the old global, only when nothing above knew the model
  if not context then
    context = tonumber(host.getenv("WASM_AGENT_LLM_CONTEXT"))
    source = context and "env-WASM_AGENT_LLM_CONTEXT" or "unknown"
  end

  return {
    context = tonumber(context) or 0,
    output = tonumber(output) or 0,
    source = source or "unknown",
  }
end

-- The reserve and keep for a window, clamped so a small window cannot produce a negative
-- trigger point. Same shape as the existing policy, now expressed per window.
function M.policy(context)
  local reserve = math.min(math.max(M.RESERVE, math.floor(context * M.RESERVE_FRACTION)), math.max(1000, math.floor(context / 4)))
  local keep = math.min(M.KEEP, math.max(1000, math.floor(context / 2)))
  return reserve, keep
end

-- Force a refetch, for the UI's refresh button and for tests. Returns the model count the
-- catalogue was found to carry, or nil when nothing could be fetched - so a caller can
-- tell "refreshed and empty" from "could not refresh".
function M.refresh()
  catalogue, catalogue_at = nil, 0
  local cat = fetch_catalogue({ allow_fetch = true })
  if type(cat) ~= "table" then return nil end
  local n = 0
  for _, provider in pairs(cat) do
    if type(provider) == "table" and type(provider.models) == "table" then
      n = n + #(function() local t = {} for _ in pairs(provider.models) do t[#t + 1] = 1 end return t end)()
    end
  end
  return n
end

-- How many models the catalogue knows, and whether it was reached at all. Diagnostics for
-- the provider payload, so "why is my window wrong" is answerable without reading a log.
function M.catalogue_status()
  local cat = fetch_catalogue()
  if type(cat) ~= "table" then return { loaded = false } end
  local providers, models = 0, 0
  for _, provider in pairs(cat) do
    providers = providers + 1
    if type(provider) == "table" and type(provider.models) == "table" then
      for _ in pairs(provider.models) do models = models + 1 end
    end
  end
  return { loaded = true, providers = providers, models = models }
end

return M
