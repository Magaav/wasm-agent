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
  ["long-lived"] = "Start a long-running background process, as a plain child process of your shell " ..
    "(not a scheduled task, not a service, not a detached daemon). It must append one line to " ..
    "<FILE> every 2 seconds and it must still be running when you finish - it has to outlive this " ..
    "task. Prove it started by showing the file's contents once. Do not wait for it to end.",
  ["navigation"] = "Find where host.exec_timeout is read in this repository, and name the " ..
    "Lua file and the function that consumes it, with the line number. Do not modify anything.",
}

local base_prompt = TASKS[task_id]
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
  local adopted = {}
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
      if decoded_ok and type(decoded) == "table" then
        -- A promoted `bash` returns a receipt instead of a result; remember it so the
        -- adoption can be checked after the child that started it has finished.
        if decoded.promoted == true and decoded.operation_id then
          adopted[#adopted + 1] = tostring(decoded.operation_id)
        end
        if decoded.ok == false or decoded.error ~= nil then
          errors[#errors + 1] = tostring(decoded.error or content):sub(1, 200)
        end
      end
    end
  end

  -- Adoption is only real if the process is still running after the child that started
  -- it has finished. The node is still alive here - it exits when this script ends, and
  -- KILL_ON_JOB_CLOSE takes the job with it - so this is the only honest moment to look.
  local adoption = {}
  if #adopted > 0 then
    -- The evidence of a live process is the file it was told to write, not the
    -- operation's stdout: a backgrounded loop appends to its own log, so the shell's
    -- stdout can stay empty while the process is healthy.
    local function size_of(path)
      local text = host.read_file and host.read_file(path)
      return text and #text or -1
    end
    local before = {}
    for _, op in ipairs(adopted) do
      local view = json.decode(host.operation("status", json.encode({ id = op })) or "{}")
      before[op] = { bytes = tonumber(view.output_bytes) or 0, file = size_of(entry.file) }
    end
    host.sleep(3000)
    for _, op in ipairs(adopted) do
      local view = json.decode(host.operation("status", json.encode({ id = op })) or "{}")
      local after = { bytes = tonumber(view.output_bytes) or 0, file = size_of(entry.file) }
      adoption[#adoption + 1] = {
        operation_id = op, state = view.state, settled = view.settled, promoted = view.promoted,
        stdout_bytes_before = before[op].bytes, stdout_bytes_after = after.bytes,
        file_bytes_before = before[op].file, file_bytes_after = after.file,
        still_running = view.settled ~= true,
        file_grew = before[op].file >= 0 and after.file > before[op].file,
      }
    end
  end

  print("LEDGER " .. json.encode({
    arm = arm, task = task_id, run = entry.index, profile = profile,
    child = receipt.subagent_id, session = receipt.session_id, file = entry.file,
    state = final.state, settled = final.settled,
    failure = final.error,
    first_tool = first_tool,
    tools = tools, errors = errors,
    adoption = adoption,
    reasoning_chars = reasoning_chars,
    tokens_total = tokens_total,
    usage = usage,
    reply = tostring(result.reply or ""):sub(1, 800),
  }))
end

print("EXPERIMENT_DONE " .. arm .. " " .. task_id)
