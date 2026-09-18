-- Match provider.lua: json is vendored and loaded with dofile. `require("json")` only
-- resolves inside the embedded binary path, so a dofile-based host (the disk-loaded
-- iteration path) fails on it - which is how this file first broke.
local json = dofile("lua/vendor/json.lua")
-- `host` is a global injected by the wa host, not a Lua module: require("host") resolves
-- in the embedded build but not on the disk-loaded path, which is exactly where a test
-- would catch it. Referred to lazily through host.getenv below so a stub can replace it.
local host = host

-- Per-model context windows, and where they come from.
--
-- The bug this replaces: the window was a single global (`WASM_AGENT_LLM_CONTEXT`), so
-- every model was told the same number regardless of which model was answering. Set to
-- 128000 for a model whose window is 1000000, compaction fired at ~96000 tokens instead
-- of ~967000 - the agent summarised away most of its own working memory, ten times too
-- early, and did it invisibly, because "compacted" is not an error.
--
-- pi does not have this problem because the window is a property of the *model*: its
-- models-store records `contextWindow` and `maxTokens` per entry (1000000 and 384000 for
-- deepseek-v4.1-flash). So the fix is not a bigger number, it is the right shape: look
-- the window up by model, and only fall back to the env var for a model we do not know.
--
-- Resolution order, most specific first:
--   1. `WASM_AGENT_MODEL_LIMITS` JSON, per model - the operator's explicit override.
--   2. this table, for models we ship knowledge of.
--   3. `WASM_AGENT_LLM_CONTEXT` - the old global, kept so nothing breaks.
--   4. 0, meaning "unknown", and callers must treat unknown as unknown.

local M = {}

-- Known windows. The rule for adding an entry: it must be checkable against the provider
-- or the vendor's documentation. A guessed window is worse than an unknown one, because
-- unknown is visible and a guess is not.
M.WINDOWS = {
  ["deepseek-v4.1-flash"] = { context = 1000000, output = 384000 },
  ["deepseek-v4-flash"]   = { context = 1000000, output = 384000 },
  ["deepseek-v4-pro"]     = { context = 1000000, output = 384000 },
}

-- pi's policy numbers, unchanged: reserve the reply, keep the recent work verbatim.
M.RESERVE = 16384
M.KEEP = 20000

function M.for_model(model)
  local window
  if model and model ~= "" then window = M.WINDOWS[model] end

  local context = window and window.context or nil
  local output = window and window.output or nil

  -- The operator's override wins over the shipped table, because they may know something
  -- we do not (a proxy with a smaller window, a beta limit, a cheaper pricing tier).
  local raw = host.getenv("WASM_AGENT_MODEL_LIMITS")
  if raw and raw ~= "" and model and model ~= "" then
    local ok, parsed = pcall(json.decode, raw)
    local entry = ok and type(parsed) == "table" and parsed[model] or nil
    if type(entry) == "table" then
      context = tonumber(entry.context) or context
      output = tonumber(entry.output) or output
    end
  end

  -- The old global, only as a fallback, and only when nothing above knew the model.
  if not context then context = tonumber(host.getenv("WASM_AGENT_LLM_CONTEXT")) end

  return {
    context = tonumber(context) or 0,
    output = tonumber(output) or 0,
    -- Where the number came from, so `provider` and the balloon can show it. A limit with
    -- no provenance is a number the reader cannot check, which is the whole complaint.
    source = (M.WINDOWS[model or ""] and "known-model")
      or (context and "env-WASM_AGENT_LLM_CONTEXT")
      or "unknown",
  }
end

-- The reserve and keep for a window, clamped so a small window cannot produce a negative
-- trigger point. Same shape as the existing policy, now expressed per window.
function M.policy(context)
  local reserve = math.min(M.RESERVE, math.max(1000, math.floor(context / 4)))
  local keep = math.min(M.KEEP, math.max(1000, math.floor(context / 2)))
  return reserve, keep
end

return M
