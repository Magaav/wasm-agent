-- The context-window assertions, runnable without cargo via WASM_AGENT_LUA_ROOT.
--
-- The window belongs to the model, not to the process. WASM_AGENT_LLM_CONTEXT is 128000
-- here on purpose: that is the value the operator has, and it is 7.8x smaller than the
-- window of the model in use. The model's own number must win, or compaction fires at
-- ~96000 tokens instead of ~967000 and summarises away most of the working memory
-- without ever reporting a problem.
local provider = dofile("lua/core/provider.lua")
local windowlib = dofile("lua/core/model_window.lua")
local json = dofile("lua/vendor/json.lua")

local failures = 0
local function check(condition, label)
  if condition then print("ok   " .. label)
  else print("FAIL " .. label); failures = failures + 1 end
end

-- Unknown model: the old global is the last-resort fallback, and says so.
local fallback = provider.budget("some-unknown-model")
check(fallback.context == 128000, "an unknown model falls back to the env window")
check(fallback.source == "env-WASM_AGENT_LLM_CONTEXT", "and names the env as its source")

-- The operator's per-model override beats every discovery stage.
local per_model = provider.budget("kimi-k2.6")
check(per_model.context == 262144, "a WASM_AGENT_MODEL_LIMITS entry wins")
check(per_model.source == "env-WASM_AGENT_MODEL_LIMITS", "and is attributed to the override")

-- The point of the chain: models the shipped table never knew resolve anyway. glm-5.3-flash
-- is not in model_window.lua's table and was never hardcoded anywhere - it can only come
-- from a discovery stage, so it fails if discovery is broken.
local discovered = provider.budget("glm-5.3-flash")
check(discovered.context > 128000, "a model absent from the shipped table is discovered, got " .. tostring(discovered.context))
check(discovered.source ~= "env-WASM_AGENT_LLM_CONTEXT",
  "and does not fall back to the global, source=" .. tostring(discovered.source))

-- A real window known to be larger than the global, from whichever stage answered.
local deep = provider.budget("deepseek-v4.1-flash")
check(deep.context == 1000000, "a known model keeps its own window, got " .. tostring(deep.context))
check(deep.source ~= "unknown", "and attributes it, source=" .. tostring(deep.source))
check(deep.context - deep.reserve > 900000, "a 1M window does not compact at 96k")

-- Catalogue diagnostics, so "why is my window wrong" is answerable from the payload.
local cat = windowlib.catalogue_status()
check(type(cat) == "table", "catalogue status is a table")
if cat.loaded then
  check(cat.models > 1000, "a loaded catalogue carries models, got " .. tostring(cat.models))
end
print("     catalogue: " .. json.encode(cat))

-- The reserve scales with the window rather than sitting at a fixed absolute.
local big_r, small_r = windowlib.policy(1000000), windowlib.policy(20000)
check(big_r < 20000, "the reserve stays bounded on a huge window")
check(small_r < 20000, "and shrinks on a tiny one rather than going negative")

check(provider.limits and provider.limits ~= provider.budget, "limits and budget are distinct")

print("---")
if failures > 0 then print(failures .. " FAILURE(S)"); os.exit(1) end
print("ALL PASS")
