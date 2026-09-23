-- The lab rig: run N children under one arm, in parallel, and print a ledger.
--
-- This is deliberately not a test. Nothing here asserts a verdict, because the
-- question is not pass/fail - it is *what did the agent choose, and what did it
-- cost*. The driver (scripts/experiment-tool-choice.cjs) writes the arm's profile
-- files, points the node at a provider, runs this file through the real host, and
-- reads the JSON lines it prints.
--
-- Concurrency is the point. Every child is started before any is awaited, so the
-- arm's runs overlap on the subagent pool; awaiting inside the start loop would
-- serialize them and measure nothing but latency.
--
-- Parameters come from the environment, set by the driver:
--   WA_EXPERIMENT_ARM      a label, printed on every row
--   WA_EXPERIMENT_TASK     long-lived | navigation
--   WA_EXPERIMENT_N        how many children to run
--   WA_EXPERIMENT_PROFILE  the profile id to run under
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local subagents = dofile("lua/core/subagents.lua")

local arm = os.getenv("WA_EXPERIMENT_ARM") or "control"
local task_id = os.getenv("WA_EXPERIMENT_TASK") or "long-lived"
local runs = tonumber(os.getenv("WA_EXPERIMENT_N") or "3")
local profile = os.getenv("WA_EXPERIMENT_PROFILE") or "exp-control"
-- The child's shell is Git Bash, whose `/tmp` is not Node's `/tmp` on Windows. The
-- driver hands over one directory both sides can resolve, so the liveness check reads
-- the same file the child wrote.
local workdir = os.getenv("WA_EXPERIMENT_DIR") or "/tmp"

-- The two fixtures. Both have a checkable outcome, which is what keeps "it did
-- better" from being an opinion: F1 leaves observable evidence of a live process,
-- F2 names a file and a function that either exist in the tree or do not.
local TASKS = {
  ["long-lived"] = {
    prompt = "Start a process that appends one line to <FILE> every 2 seconds. " ..
      "It must still be running when you finish - it has to outlive this task. " ..
      "Prove it started by showing the file's contents once. Do not wait for it to end.",
    -- The outcome here is a live process, checked after the run; there is no text to match.
    expect = {},
  },
  ["navigation"] = {
    prompt = "Find where host.exec_timeout is read in this repository, and name the " ..
      "Lua file and the function that consumes it, with the line number. Do not modify anything.",
    -- Tokens per *correct* answer is the metric: a cheaper wrong answer is not an improvement.
    expect = { "lua/core/tools.lua", "exec_deadline_seconds" },
  },
  -- Replay's cost is proportional to the number of rounds: what is re-sent is the thinking
  -- of every round before this one. A five-round task cannot show it, so this fixture asks
  -- for twelve files - one read and one round each - and the answer must name all twelve.
  ["wide"] = {
    prompt = "For each of these files, report the name of the first function it defines. " ..
      "Read each one. Report one line per file as `path: name`.\n" ..
      "lua/core/agent.lua, lua/core/memory.lua, lua/core/provider.lua, lua/core/subagents.lua, " ..
      "lua/core/tools.lua, lua/core/tool_output.lua, lua/core/graph.lua, lua/core/skills.lua, " ..
      "lua/core/nodes.lua, lua/core/spells.lua, lua/core/platform.lua, lua/core/paths.lua",
    expect = { "lua/core/agent.lua", "lua/core/memory.lua", "lua/core/provider.lua",
      "lua/core/subagents.lua", "lua/core/tools.lua", "lua/core/tool_output.lua",
      "lua/core/graph.lua", "lua/core/skills.lua", "lua/core/nodes.lua",
      "lua/core/spells.lua", "lua/core/platform.lua", "lua/core/paths.lua" },
  },
}

local selected = TASKS[task_id]
local base_prompt = selected and selected.prompt
local expect = (selected and selected.expect) or {}
if not base_prompt then
  print("LEDGER " .. json.encode({ arm = arm, task = task_id, fatal = "unknown task" }))
  print("EXPERIMENT_DONE " .. arm .. " " .. task_id)
  return
end

local parent_id = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "experiment:" .. arm })

-- A fresh home has no graph.db, so the `graph` tool fails with "unable to open
-- database file" and the arm measures nothing but the fallback. Index once, in the
-- same node and home the children will use, before any child starts.
if os.getenv("WA_EXPERIMENT_INDEX") == "1" then
  local loaded, graph = pcall(dofile, "lua/core/graph.lua")
  if loaded and graph then
    local indexed, err = graph.index({})
    print("INDEX " .. json.encode({ ok = indexed ~= nil, error = err,
      nodes = indexed and indexed.nodes or nil, edges = indexed and indexed.edges or nil }))
  else
    print("INDEX " .. json.encode({ ok = false, error = tostring(graph) }))
  end
end
local ctx = { user_id = "master", role = "master", session_id = parent_id, run_id = "experiment-run", node_id = "" }

-- Start every child first. `start` is a durable receipt, not a result, so this
-- loop returns as soon as each child is admitted.
local started = {}
for index = 1, runs do
  local file = workdir .. "/wa-experiment-" .. arm .. "-" .. task_id .. "-" .. index .. ".log"
  local prompt = base_prompt:gsub("<FILE>", file)
  local receipt = subagents.control({
    action = "start", profile = profile, prompt = prompt,
    idempotency_key = arm .. "-" .. task_id .. "-" .. index,
  }, ctx)
  if receipt.error then
    print("LEDGER " .. json.encode({ arm = arm, task = task_id, run = index,
      profile = profile, error = receipt.error }))
  else
    started[#started + 1] = { index = index, receipt = receipt, file = file }
  end
end

-- One row per run. The tool calls are read back from the child's own transcript,
-- which is the only place the *decision* is recorded: the receipt says the child
-- ran, not what it reached for.
for _, entry in ipairs(started) do
  local receipt = entry.receipt
  local final = subagents.control({ action = "await", subagent_id = receipt.subagent_id, wait_ms = 900000 }, ctx)
  local result = final.result or {}
  local usage = result.usage or {}

  local tools, errors, reasoning_chars, first_tool, tokens_total = {}, {}, 0, "", 0
  local rows = memory.session_messages(receipt.session_id, { all = true })
  for _, row in ipairs(rows) do
    if row.role == "assistant" then
      reasoning_chars = reasoning_chars + #tostring(row.reasoning or "")
      -- The child's `usage_total.last` is not set on the reply path, so the durable
      -- per-turn `tokens` column is the honest source for what the run cost.
      tokens_total = tokens_total + (tonumber(row.tokens) or 0)
      for _, call in ipairs(row.tool_calls or {}) do
        local fn = call["function"] or call
        local name = tostring(fn.name or "")
        if first_tool == "" then first_tool = name end
        local args = fn.arguments
        if type(args) == "string" then
          local ok, decoded = pcall(json.decode, args)
          args = (ok and type(decoded) == "table") and decoded or {}
        end
        tools[#tools + 1] = { name = name, args = tostring(args.command or args.action or "") }
      end
    elseif row.role == "tool" then
      -- Only a tool result that *failed* counts. Matching the words in the payload
      -- counted a grep hit whose matched line happened to contain "deadline", which
      -- made a clean investigation look like a wall of refusals.
      local content = tostring(row.content or "")
      local decoded_ok, decoded = pcall(json.decode, content)
      if decoded_ok and type(decoded) == "table" and (decoded.ok == false or decoded.error ~= nil) then
        errors[#errors + 1] = tostring(decoded.error or content):sub(1, 200)
      end
    end
  end

  local reply = tostring(result.reply or "")
  -- Correct only if it names every expected fact. A cheap wrong answer is not an
  -- improvement, so the headline metric is tokens per correct answer.
  local missing = {}
  for _, needle in ipairs(expect) do
    if not reply:find(needle, 1, true) then missing[#missing + 1] = needle end
  end
  print("LEDGER " .. json.encode({
    arm = arm, task = task_id, run = entry.index, profile = profile,
    child = receipt.subagent_id, session = receipt.session_id, file = entry.file,
    state = final.state, settled = final.settled,
    failure = final.error,
    first_tool = first_tool,
    correct = #missing == 0,
    missing = missing,
    tools = tools, errors = errors,
    reasoning_chars = reasoning_chars,
    tokens_total = tokens_total,
    usage = usage,
    reply = reply:sub(1, 800),
  }))
end

print("EXPERIMENT_DONE " .. arm .. " " .. task_id)
