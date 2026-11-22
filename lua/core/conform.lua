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
  -- A profile that measured NO action at all decides NOTHING (review r1, item 5). `tool_rate >= block_rate`
  -- read 0 >= 0 as tool_call, so an all-fail profile opened the one door this node has - for a model that
  -- was never seen to act. Unknown is not yes: no action measured means no door, and the node refuses the
  -- model by name instead.
  if tool_rate <= 0 and block_rate <= 0 then
    return { transport = nil, source = "no_action_measured",
      tool_rate = tool_rate, block_rate = block_rate }
  end
  local transport = tool_rate > 0 and tool_rate >= block_rate and M.TOOL_CALL or M.BLOCK
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

-- The harness a task is measured IN. A suite that sent a bare prompt would measure a bare model, and
-- every answer would be about the model's training rather than about this node. So each task gets the
-- same system prompt and the same declared tools the node builds: the Codemact guidance for the
-- transport in use, and the tool list from the policy. `prepare` is injectable so a test can drive the
-- runner with no provider and no engine.
-- The harness a task is measured IN, and why it is not the node's own operating mode.
--
-- ONE path (operator 21/11, review r1 item 6): the node has one door, so the harness offers one. What is
-- measured is whether the model ACTS through it and how often - `uses_run_tool` is the rate the door
-- reads, and `acts_in_answer` still records a fenced block a model writes anyway (that is a measurement
-- of the wrong door, and a profile that prefers it does not open the node's). Offering two transports
-- would measure a choice the node does not have.
function M.harness(memory, role, ctx)
  local tools = dofile("lua/core/tools.lua")
  local raw_code = dofile("lua/core/raw_code.lua")
  local list = {}
  for _, item in ipairs(tools.catalog(role)) do
    local name = item["function"] and item["function"].name or ""
    if name ~= "integrate" and name ~= "route_task" then list[#list + 1] = item end
  end
  local parts = {
    "You are wasm-agent, an engineering agent on this node. Work in code.",
    "Act by calling the run tool with `code`: it runs as one script where every tool is "
      .. "tools.<name>(args), and its result comes back to you. A message with no tool call is your answer.",
    "A message with no action is your answer. Bytes that must travel exactly (a file body, a patch) "
      .. "go in the run call's `raw` object, never escaped inside the code.",
  }
  return { system = table.concat(parts, "\n\n"), tools = list }
end

function M.run(model, complete, say, prepare)
  say = say or function() end
  local profile = { model = model, transport = nil, tasks = {}, rates = {}, at = os.time and os.time() or nil }
  local passed = 0
  for _, task in ipairs(tasks_lib.TASKS) do
    local retried_once = false
    local harness = prepare and prepare(task) or { system = nil, tools = nil }
    local messages = {}
    if harness.system then messages[#messages + 1] = { role = "system", content = harness.system } end
    messages[#messages + 1] = { role = "user", content = task.prompt }
    local session_id = "conform-" .. tostring(model) .. "-" .. tostring(task.id)
    local ok, record = pcall(complete, model, messages, harness.tools, false, { session_id = session_id })
    -- One re-ask on a reasoning-only reply, exactly the recovery the node's own loop gives
    -- (lua/core/finish_contract.lua): a reply that is only thinking is not an answer, and the harness
    -- names that once. Measuring a bare single call would measure something the node never exposes.
    if ok and type(record) == "table" then
      local provider = dofile("lua/core/provider.lua")
      if provider.is_empty_reply(record) then
        local retry_messages = {}
        for _, message in ipairs(messages) do retry_messages[#retry_messages + 1] = message end
        retry_messages[#retry_messages + 1] = { role = "user", content =
          "[Harness notice] That reply carried no answer. Answer in the answer field, in one sentence." }
        local retry_ok, retried = pcall(complete, model, retry_messages, harness.tools, false,
          { session_id = session_id .. "-retry" })
        if retry_ok and type(retried) == "table" and not provider.is_empty_reply(retried) then
          record = retried
          retried_once = true
        end
      end
    end
    local result = { id = task.id, passed = false, why = nil, retried = retried_once or nil }
    if not ok then
      result.why = "the call failed: " .. tostring(record)
    elseif type(record) ~= "table" then
      result.why = "no normalized answer"
    else
      local checked, why = task.check(record, raw_code)
      result.passed = checked == true
      if result.passed then
        result.why = nil
      else
        result.why = tostring(why or "the check did not pass")
      end
    end
    if not result.passed and type(record) == "table" then
      -- What the record actually held, so a failure is a measurement and not a mystery.
      result.detail = string.format("answer=%d reasoning=%d calls=%d finish=%s",
        #tostring(record.answer_text or ""), #tostring(record.reasoning or ""),
        #(record.tool_calls or {}), tostring(record.finish_reason))
    end
    if result.passed then passed = passed + 1 end
    profile.tasks[#profile.tasks + 1] = result
    profile.rates[task.id] = result.passed and 1 or 0
    say(string.format("%-24s %s%s", task.id, result.passed and "pass" or ("FAIL: " .. tostring(result.why)),
      result.detail and (" [" .. result.detail .. "]") or ""))
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
