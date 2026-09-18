-- The context-window assertions, in a script the handoff gate can run without cargo.
--
-- scripts/test.sh already asserts these, but it needs a Rust toolchain, so on a Windows
-- node the gate SKIPs it - and a skip is not a check. This file is the same assertions on
-- the disk-loaded Lua path, so the gate can verify the window logic on any node.
--
-- The window belongs to the model, not to the process. WASM_AGENT_LLM_CONTEXT is set to
-- 128000 here on purpose: that is the value the operator has, and it is 7.8x smaller than
-- deepseek-v4.1-flash's real window of 1000000. The model's own number must win, or
-- compaction fires at ~96000 tokens instead of ~983000 and summarises away most of the
-- agent's working memory without ever reporting a problem.
local provider = dofile("lua/core/provider.lua")
local windowlib = dofile("lua/core/model_window.lua")

local function check(condition, label)
  if condition then
    print("ok   " .. label)
  else
    print("FAIL " .. label)
    failures = (failures or 0) + 1
  end
end
failures = 0

-- Unknown model: the old global is the last-resort fallback, and says so.
local fallback = provider.budget("some-unknown-model")
check(fallback.context == 128000, "an unknown model falls back to the env window")
check(fallback.source == "env-WASM_AGENT_LLM_CONTEXT", "an unknown model names the env as its source")

-- The operator's per-model override beats the shipped table.
local per_model = provider.budget("kimi-k2.6")
check(per_model.context == 262144, "a WASM_AGENT_MODEL_LIMITS entry wins")
check(per_model.reserve == 32768, "a per-model reserve wins")

-- The point of the change: a known model keeps its own window despite the global.
local deep = provider.budget("deepseek-v4.1-flash")
check(deep.context == 1000000, "a known model keeps its own window")
check(deep.source == "known-model", "a known model attributes its window to the model table")
check(deep.output == 384000, "and its output cap comes from the same entry")

-- And the trigger scales with it, which is what the wrong global broke.
check(deep.context - deep.reserve > 900000, "a 1M window does not compact at 96k")
local big_r = windowlib.policy(1000000)
local small_r = windowlib.policy(20000)
check(big_r < 20000, "the reserve stays bounded on a huge window")
check(small_r < 20000, "and shrinks on a tiny one rather than going negative")

-- limits (the account's rate limits) and budget (one model's window) are different things.
check(provider.limits and provider.limits ~= provider.budget, "limits and budget are distinct")

print("---")
if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
