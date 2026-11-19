-- The conformance runner (docs/AGENT-SEAT.md, principle 7): run the tasks live, record the rates.
--
-- One model call per task, through the SAME provider seam the loop uses, so what is measured is what
-- the node will actually get. The profile it writes is read by `M.decide` below, which is what the
-- node consults to choose a CodeAct transport and its guidance.
local json = dofile("lua/vendor/json.lua")
local profile_lib = dofile("lua/core/model_profile.lua")
local tasks_lib = dofile("lua/core/conform_tasks.lua")
local raw_code = dofile("lua/core/raw_code.lua")

local M = {}

-- Which transport a measured profile implies, and the one-line reason. A model that acted through a
-- native call is offered the tool-call transport; one that acted through a fence is offered the block;
-- a model with no measured action keeps the conservative default.
function M.decide(profile)
  if type(profile) ~= "table" or type(profile.tasks) ~= "table" then
    return { transport = nil, source = "no_profile" }
  end
  local tool_rate = tonumber(profile.rates and profile.rates.uses_run_tool or 0) or 0
  local block_rate = tonumber(profile.rates and profile.rates.acts_in_answer or 0) or 0
  local transport = tool_rate >= block_rate and M.TOOL_CALL or M.BLOCK
  return { transport = transport, source = "profile",
    tool_rate = tool_rate, block_rate = block_rate }
end
M.TOOL_CALL = profile_lib.TOOL_CALL
M.BLOCK = profile_lib.BLOCK

-- The conservative default when there is no profile: a model that can call tools is offered the run
-- tool (a native call needs no fence closed), and one that cannot is offered the block. Named here so
-- the notice and the choice cannot drift apart.
function M.default_transport(supports_tools)
  if supports_tools then return M.TOOL_CALL, "no_profile" end
  return M.BLOCK, "no_profile_no_tools"
end

-- The one-line notice a node shows when it is acting on the default rather than on a measurement.
function M.notice(model, transport)
  return string.format("conform: no profile for %s, using the conservative %s transport; run `wa conform %s` to measure it",
    tostring(model), tostring(transport), tostring(model))
end

-- Run every task once against `model`, and answer the profile. `complete` is the provider seam
-- (M.complete in lua/core/provider.lua); `say` receives one line per task as it finishes.
function M.run(model, complete, say)
  say = say or function() end
  local profile = { model = model, transport = nil, tasks = {}, rates = {}, at = os.time and os.time() or nil }
  local passed = 0
  for _, task in ipairs(tasks_lib.TASKS) do
    local messages = { { role = "user", content = task.prompt } }
    local ok, record = pcall(complete, model, messages, nil, false, {})
    local result = { id = task.id, passed = false, why = nil }
    if not ok then
      result.why = "the call failed: " .. tostring(record)
    elseif type(record) ~= "table" then
      result.why = "no normalized answer"
    else
      local checked, why = task.check(record, raw_code)
      result.passed = checked == true
      result.why = result.passed and nil or tostring(why or "the check did not pass")
    end
    if result.passed then passed = passed + 1 end
    profile.tasks[#profile.tasks + 1] = result
    profile.rates[task.id] = result.passed and 1 or 0
    say(string.format("%-24s %s", task.id, result.passed and "pass" or ("FAIL: " .. tostring(result.why))))
  end
  profile.passed = passed
  profile.total = #tasks_lib.TASKS
  profile.rate = profile.total > 0 and (passed / profile.total) or 0
  local decision = M.decide(profile)
  profile.transport = decision.transport
  return profile
end

function M.store(model, profile)
  return profile_lib.write(model, profile)
end

return M
