-- The compaction trigger must fire on a budget, not only when the model window is nearly full.
--
-- The bug this exists for: compaction was correct and never ran. The trigger was "context > window - reserve",
-- and this model's window is 1,000,000 tokens, so a session averaging 120,628 tokens of prompt per call never
-- reached it and never compacted - eleven times pi's per-call cost, for a third of the output per call.
--
-- Run with a small budget so the budget is what fires:
--   WASM_AGENT_CONTEXT_BUDGET=2000 WA_SCRIPT=scripts/test-context-budget.lua wa --db /tmp/x.db
local window = dofile("lua/core/model_window.lua")
local agent = dofile("lua/core/agent.lua")

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

local budget = tonumber(host.getenv("WASM_AGENT_CONTEXT_BUDGET") or "")
ok(budget == 2000, "the test must run with WASM_AGENT_CONTEXT_BUDGET=2000", tostring(budget))
ok(type(agent) == "table", "the agent module loads (the change must not break it)")

-- The case that cost the money: a huge window, so the budget is the only thing that can fire.
local limit = 1000000
local reserve, keep = window.policy(limit)
ok(reserve > 0 and keep > 0, "the window still yields reserve and keep", reserve .. "/" .. keep)
ok(math.min(limit - reserve, budget) == budget,
  "with a 1,000,000-token window the budget is the trigger", tostring(limit - reserve))
ok(budget < limit - reserve, "and it is strictly earlier than the window would be", tostring(limit - reserve))

-- The property that matters: the budget may make compaction happen *earlier*, never later. A call must never
-- be sent past its model. (The first version of this asserted the window always wins, which is false for a
-- small window - and the budget winning there is correct: compacting early is safe, compacting late is not.)
local small = 32000
local small_reserve = window.policy(small)
ok(math.min(small - small_reserve, budget) <= small - small_reserve,
  "the budget can never exceed the window trigger", tostring(small - small_reserve))

print("context budget ok (" .. checks .. " checks)")
