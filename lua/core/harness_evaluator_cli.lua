-- Harness evaluator, the operator's door (`wa eval ...`).
--
-- One verb per job, dispatched from the one place `wa` dispatches commands (lua/core/init.lua), so the
-- engine exists in the binary an operator runs - not only as a module a test can dofile. Every failure is
-- a word and a non-zero exit, never a silent success: a capture that froze nothing, a replay that could
-- not start and a report that found no runs all say so.
--
-- Nothing here prints the content of a task: a summary prints ids, categories, counts and paths inside
-- the state directory. That rule is what makes `wa eval` safe to run over real work.
local json = dofile("lua/vendor/json.lua")
local core = dofile("lua/core/harness_evaluator.lua")
local replay = dofile("lua/core/harness_evaluator_replay.lua")

local M = {}

local USAGE = [==[
wa eval - freeze real tasks and replay them against a candidate binary

  wa eval capture <session-id> [--turn N] [--id ID] [--category NAME]
                              [--check human|cmd:<shell>|file:<path>[=<text>]]
                              [--dir <workspace>] [--note TEXT]
  wa eval list
  wa eval run <task-id>|--all --bin <wa> [--model] [--timeout SECONDS] [--keep-scratch]
  wa eval report [--all] [--compare <run-a> <run-b>]
  wa eval verdict <run-id> pass|fail "<note>"
  wa eval reviewer <run-id> [--findings N] [--accepted N] [--misses N] [--cost TEXT]

A frozen task and every run live under <config>/evaluator (never in a repository, never printed whole).
`run` is isolated: a mktemp scratch home with a marker, connectors and effects blocked and recorded as
"would have done", connector reads answered from the recording. `--model` is the one thing a replay cannot
invent - without it the child has no provider and the run says so instead of reaching this node's account.
]==]

local function flag(args, name)
  for index = 2, #args do
    if args[index] == name then return args[index + 1], index end
  end
  return nil
end

local function has(args, name)
  for index = 2, #args do if args[index] == name then return true end end
  return false
end

-- The words that are not an option and not an option's value, in order: the positional arguments.
local function positionals(args, value_flags)
  local out = {}
  local index = 2
  while index <= #args do
    local token = args[index]
    if value_flags[token] then
      index = index + 2
    elseif token:sub(1, 2) == "--" then
      index = index + 1
    else
      out[#out + 1] = token
      index = index + 1
    end
  end
  return out
end

local function refused(message)
  print("wa eval: " .. message)
  return 2
end

local function capture(args)
  local valued = { ["--turn"] = true, ["--id"] = true, ["--category"] = true, ["--check"] = true, ["--dir"] = true, ["--note"] = true }
  local words = positionals(args, valued)
  local session_id = words[1]
  if not session_id then return refused("capture needs a session id (wa sessions lists them)") end
  local record, problem = core.capture(session_id, {
    turn = flag(args, "--turn"),
    id = flag(args, "--id"),
    category = flag(args, "--category"),
    check = flag(args, "--check"),
    dir = flag(args, "--dir"),
    note = flag(args, "--note"),
  })
  if not record then return refused(problem or "the capture failed") end
  print(json.encode({
    ok = true,
    task = record.id,
    category = record.category,
    check = record.check.kind,
    source_session = record.source.session_id,
    turn = record.source.turn,
    workspace = (record.workspace or {}).kind,
    prompt_bytes = #tostring(record.prompt or ""),
    outcomes = {
      rounds = record.outcome.rounds,
      tool_calls = record.outcome.tool_calls,
      tool_errors = record.outcome.tool_errors,
      effects_attempted = record.outcome.effects_attempted,
      connector_recordings = #(record.connectors.recordings or {}),
      wall_ms = record.outcome.wall_ms,
    },
    state_dir = core.state_dir(),
  }))
  return 0
end

local function list()
  local rows = core.tasks()
  if #rows == 0 then
    print("(no frozen tasks: `wa eval capture <session-id>` freezes one)")
    return 0
  end
  for _, row in ipairs(rows) do
    print(string.format("%-24s %-16s %-10s %s", tostring(row.id), tostring(row.category),
      tostring(type(row.check) == "table" and row.check.kind or row.check), tostring(row.note or "")))
  end
  return 0
end

local function run(args)
  local valued = { ["--bin"] = true, ["--timeout"] = true }
  local words = positionals(args, valued)
  local wanted = words[1]
  local bin = flag(args, "--bin")
  if not bin then return refused("run needs --bin <absolute path to the wa binary that should answer>") end
  local tasks = {}
  if wanted == "--all" or has(args, "--all") then
    tasks = core.tasks()
    if #tasks == 0 then return refused("there is no frozen task to replay") end
  elseif wanted then
    local record = core.task(wanted)
    if not record then return refused("no such frozen task: " .. wanted) end
    tasks = { record }
  else
    return refused("run needs a task id or --all")
  end
  local options = { bin = bin, model = has(args, "--model"), timeout = flag(args, "--timeout"), keep_scratch = has(args, "--keep-scratch") }
  local failed = 0
  for _, row in ipairs(tasks) do
    local task = type(row.prompt) == "string" and row or core.task(row.id)
    if not task then
      failed = failed + 1
      print("wa eval: " .. tostring(row.id) .. ": the frozen record could not be read")
    else
      local record, problem = replay.run(task, options)
      if not record then
        failed = failed + 1
        print("wa eval: " .. tostring(task.id) .. ": " .. tostring(problem))
      else
        local m = record.metrics or {}
        print(string.format("%s %s %s rounds=%s in=%s out=%s cache=%s tools=%s errors=%s refusals=%s effects=%s wall=%sms%s",
          tostring(record.id), tostring(record.task_id), tostring(record.outcome and record.outcome.state),
          tostring(m.rounds), tostring(m.tokens_in), tostring(m.tokens_out),
          m.cache_hit and string.format("%.0f%%", m.cache_hit * 100) or "-",
          tostring(m.tool_calls), tostring(m.tool_errors), tostring(m.refusals), tostring(m.effects_attempted),
          tostring(record.wall_ms), record.error and (" error=" .. tostring(record.error)) or ""))
        if record.outcome and record.outcome.state == "error" then failed = failed + 1 end
      end
    end
  end
  return failed > 0 and 1 or 0
end

local function report(args)
  local compare_a, compare_b = flag(args, "--compare")
  if compare_a then
    local text, problem = core.compare(compare_a, compare_b or "")
    if not text then return refused(problem or "the comparison failed") end
    print(text)
    return 0
  end
  for _, line in ipairs(core.report({ all = has(args, "--all") })) do print(line) end
  return 0
end

local function verdict(args)
  local valued = {}
  for index = 2, #args do
    if args[index] == "--note" then valued["--note"] = true end
  end
  local words = positionals(args, valued)
  local run_id, state = words[1], words[2]
  if not run_id or (state ~= "pass" and state ~= "fail") then
    return refused("verdict needs a run id and `pass` or `fail`")
  end
  local note = flag(args, "--note") or table.concat(words, " ", 3)
  local record, problem = core.verdict(run_id, state, note)
  if not record then return refused(problem or "the verdict was refused") end
  print(string.format("%s %s", tostring(record.id), tostring(record.verdict.state)))
  return 0
end

local function reviewer(args)
  local valued = { ["--findings"] = true, ["--accepted"] = true, ["--misses"] = true, ["--cost"] = true }
  local words = positionals(args, valued)
  local run_id = words[1]
  if not run_id then return refused("reviewer needs a run id") end
  local record, problem = core.reviewer_record(run_id, {
    findings = flag(args, "--findings"),
    accepted = flag(args, "--accepted"),
    misses = flag(args, "--misses"),
    cost = flag(args, "--cost"),
  })
  if not record then return refused(problem or "the record was refused") end
  print(json.encode({ ok = true, run = record.id, reviewer = record.reviewer }))
  return 0
end

function M.run(args)
  local verb = args[2]
  if verb == nil or verb == "help" or verb == "--help" or verb == "-h" then
    print(USAGE)
    return 0
  end
  -- The verb's own words, with the verb at index 1: one shape for every verb, so `positionals` never
  -- has to know which word it is dispatching.
  local rest = { verb }
  for index = 3, #args do rest[#rest + 1] = args[index] end
  if verb == "capture" then return capture(rest) end
  if verb == "list" then return list() end
  if verb == "run" then return run(rest) end
  if verb == "report" then return report(rest) end
  if verb == "verdict" then return verdict(rest) end
  if verb == "reviewer" then return reviewer(rest) end
  return refused("unknown verb " .. tostring(verb) .. " (wa eval help)")
end

return M
