-- Harness evaluator, replay: run a frozen task against a candidate binary where nothing real is
-- reachable, and measure what happened.
--
-- The isolation is structural, and each part of it is one thing:
--
--   * a `mktemp -d` scratch root with a marker file, refused if it resolves inside this node's home;
--   * the child gets `env -i` and an ALLOWLIST - its own HOME, its own ledger, no node env, no vault
--     (unless the operator asked for the model route), no rendezvous, no relay;
--   * effects never leave: a replay hook blocks every connector and effect tool (one hook entry per
--     anchored name pattern - the hook engine's matcher is a Lua pattern and has no alternation), the
--     sink script records each attempt as "would have done", and PATH shims refuse `git push`, `ssh`,
--     `scp`, `rsync` and `gh` so a bash call cannot do what the tool it is not allowed to do;
--   * connector reads answer from the RECORDING captured with the task (the hook's blocked result
--     carries the recorded answer as additional context), never from a live account;
--   * metrics are read back from the replay's own ledger through a dump script the engine writes and
--     runs with the candidate binary, so no `sqlite3` is needed and the numbers come from the same
--     `messages`/`harness_events` rows a capture reads.
--
-- A task that cannot be materialized, a binary that cannot start, or a run that used no model is
-- recorded as that, with the reason, and is not counted as a success.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local core = dofile("lua/core/harness_evaluator.lua")

local M = {}
local exec = core.exec
local shquote = core.shquote

local MARKER = ".wasm-agent-eval-scratch"

-- The dump script the engine writes into the scratch root and runs with the candidate binary
-- (`WA_SCRIPT`), so the replay's ledger can be read by a process that has that ledger open - without a
-- `sqlite3` on the machine and without the engine ever opening a second database.
local DUMP = [==[
local json = dofile("lua/vendor/json.lua")
local function rows(sql)
  local ok, raw = pcall(host.sql_query, sql, "[]")
  if not ok or type(raw) ~= "string" then return { error = tostring(raw) } end
  local ok2, value = pcall(json.decode, raw)
  if not ok2 or type(value) ~= "table" then return { error = "unreadable answer" } end
  return value
end
local out = {
  sessions = rows("SELECT id,mode,user_id,node_id,started_at,ended_at FROM sessions ORDER BY started_at"),
  messages = rows("SELECT session_id,seq,role,substr(content,1,8000) AS content,tool_calls,tool_call_id,tool_name,ok,tokens,ms,created_at FROM messages ORDER BY session_id,seq"),
  events = rows("SELECT session_id,kind,payload,at FROM harness_events ORDER BY seq"),
  runs = rows("SELECT id,session_id,status,outcome,started_at,ended_at FROM runs ORDER BY started_at"),
}
-- The answer travels as a FILE: `host.exec` bounds and can truncate a child's stdout, and a JSON that
-- is cut in the middle is a JSON that cannot be read back. The stdout form stays for a manual run.
local text = json.encode(out)
local path = host.getenv("WA_EVAL_DUMP_OUT")
if path and path ~= "" and host.write_file(path, text) then print("written " .. text:len()) else print(text) end
]==]

-- The hook command. It answers every tool call the replay hooks (connectors and effects): it records the
-- event, then prints a pre-rendered decision when the task has one (a recorded connector answer, or the
-- "would have done" note) and a default refusal otherwise. Pre-rendered files keep this script free of
-- JSON escaping, which is where a shell sink goes wrong.
local SINK = [==[
#!/bin/sh
# harness-evaluator replay sink: record the blocked call, say what was served, print the decision.
set -u
dir=${WA_EVAL_SINK_DIR:?}
dec=${WA_EVAL_DECISIONS:?}
event=$(cat)
f=$(mktemp "$dir/event-XXXXXX") || exit 0
printf '%s' "$event" > "$f"
tool=$(printf '%s' "$event" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
# One line per block: the name the decision was served for, so the engine can count connector answers
# served from the recording, effects refused, and refusals with no recording, from what actually happened.
served=""
if [ -n "$tool" ] && [ -f "$dec/$tool.json" ]; then
  served=$tool
  printf '%s\n' "$served" >> "$dir/served.log"
  cat "$dec/$tool.json"
  exit 0
fi
# A nested dispatch (`tool_call` calls another tool inside one tool call) is where an effect would
# otherwise slip past the outer name: the outermost event carries the inner name in its arguments, so
# the event text is matched against the decisions installed for the effect and connector tools.
for f2 in "$dec"/*.json; do
  [ -f "$f2" ] || continue
  base=$(basename "$f2" .json)
  case "$event" in
    *"\"name\":\"$base\""*) served=$base; printf '%s\n' "$served" >> "$dir/served.log"; cat "$f2"; exit 0 ;;
    *"\"name\": \"$base\""*) served=$base; printf '%s\n' "$served" >> "$dir/served.log"; cat "$f2"; exit 0 ;;
  esac
done
printf '%s\n' "-" >> "$dir/served.log"
printf '%s' '{"decision":"block","reason":"replay: this reaches outside the replay and the task has no recording for it"}'
]==]

local GUARD = [==[
#!/bin/sh
# harness-evaluator replay guard: a remote command a bash call could otherwise reach.
printf '%s %s\n' "${GUARD_NAME:-command}" "$*" >> "$WA_EVAL_SINK_DIR/commands.log"
echo "replay: ${GUARD_NAME:-command} $* was not run; the effect is recorded as would-have-done" >&2
exit 97
]==]

local GIT_GUARD = [==[
#!/bin/sh
# harness-evaluator replay guard for git: local git works, a remote operation does not.
sub=""
for a in "$@"; do
  case "$a" in
    -*) continue ;;
    *) sub=$a; break ;;
  esac
done
case "$sub" in
  push|fetch|pull|ls-remote|clone)
    printf 'git %s %s\n' "$sub" "$*" >> "$WA_EVAL_SINK_DIR/commands.log"
    echo "replay: git $sub was not run; the effect is recorded as would-have-done" >&2
    exit 97 ;;
esac
exec "__REAL_GIT__" "$@"
]==]

local function inside(child, parent)
  if not child or not parent or child == "" or parent == "" then return false end
  child = (child:gsub("\\", "/"):gsub("/+$", "")):lower()
  parent = (parent:gsub("\\", "/"):gsub("/+$", "")):lower()
  return child == parent or child:sub(1, #parent + 1) == parent .. "/"
end
M.inside = inside

local function write_text(path, text)
  if host.write_file(path, text) then return true end
  return false
end

local function write_exec(path, text)
  if not write_text(path, text) then return false end
  local chmod = exec("chmod 755 " .. shquote(path), "", 60)
  return chmod.status == 0
end

-- A run id that is also a directory name: `<task>-<n>` keeps two runs of one task side by side and
-- readable in a report, which an opaque uuid would not.
local function run_id_for(task_id, existing)
  local base = core.safe_id(task_id)
  for index = 1, 999 do
    local candidate = string.format("%s-%03d", base, index)
    if not existing[candidate] then return candidate end
  end
  return base .. "-" .. tostring(math.floor(host.now()))
end

-- The scratch root. `mktemp -d` with a marker: the path is never one this engine derived from the
-- environment (`$TMPDIR` is used only as mktemp's parent, by mktemp), and cleanup only removes a
-- directory that carries the marker.
local function make_scratch(label)
  local made = exec("mktemp -d \"${TMPDIR:-/tmp}/wa-eval-" .. core.safe_id(label):sub(1, 24) .. "-XXXXXX\"", "", 120)
  -- `%s+$`, not a `[\r\n]` class: a Lua *pattern* has no backslash escapes, so the class spelled with
  -- backslashes matched nothing and a trailing newline rode into every path this function built.
  local path = (made.stdout or ""):gsub("%s+$", "")
  if made.status ~= 0 or path == "" then
    return nil, "mktemp could not make a scratch directory: " .. tostring(made.stderr or made.error or "")
  end
  return path
end

local function materialize(task, scratch, record)
  local spec = task.workspace or {}
  local ws = scratch .. "/ws"
  if spec.kind == "git" then
    local repo = spec.repo
    if not repo or repo == "" then return nil, "the frozen task has no repository to materialize" end
    local clone = exec("git clone --no-hardlinks --shared --no-checkout " .. shquote(repo) .. " " .. shquote(ws), "", 600)
    if clone.status ~= 0 then
      return nil, "git clone of the task's repository failed: " .. tostring((clone.stderr or ""):gsub("%s+$", ""))
    end
    local commit = (spec.base_commit ~= "" and spec.base_commit) or spec.head_commit
    local checkout = exec("git checkout --force --detach " .. shquote(commit), ws, 600)
    if checkout.status ~= 0 then
      return nil, "the task's commit " .. tostring(commit) .. " is not in " .. repo
    end
    record.workspace = { kind = "git", commit = commit, repo = repo, patch_applied = false }
    if spec.patch and spec.patch ~= "" then
      local patch_path = scratch .. "/workspace.patch"
      if write_text(patch_path, spec.patch) then
        local applied = exec("git apply --whitespace=nowarn " .. shquote(patch_path), ws, 300)
        record.workspace.patch_applied = applied.status == 0
        if applied.status ~= 0 then
          record.workspace.patch_error = tostring((applied.stderr or ""):gsub("%s+$", "")):sub(1, 400)
        end
      end
    end
    return ws
  end
  if spec.kind == "dir" then
    local tarball = core.tasks_dir() .. "/" .. core.safe_id(task.id) .. "/workspace.tgz"
    local unpack = exec("mkdir -p " .. shquote(ws) .. " && tar xzf " .. shquote(tarball) .. " -C " .. shquote(ws) .. " --strip-components=1", "", 300)
    if unpack.status ~= 0 then
      return nil, "the task's directory snapshot could not be unpacked: " .. tostring((unpack.stderr or ""):gsub("%s+$", ""))
    end
    record.workspace = { kind = "dir" }
    return ws
  end
  return nil, "the frozen task has no workspace to materialize (" .. tostring(spec.kind) .. ")"
end

-- The decisions the sink prints, pre-rendered: for a connector read, the recorded answer (as the
-- blocked result's additional context, which is what the model sees); for an effect, the note that it
-- was not performed. `recorded_for` counts how many connector calls the task actually has a recording for.
local function install_decisions(task, decisions_dir, record)
  local counts = { connector = 0, effect = 0, default = 0 }
  local answered = {}
  for _, recording in ipairs((task.connectors or {}).recordings or {}) do
    local tool = tostring(recording.tool or "")
    if tool ~= "" and not answered[tool] then
      answered[tool] = true
      local text = tostring(recording.response or "")
      if not recording.ok then text = "[recorded failure] " .. text end
      core.write_json(decisions_dir .. "/" .. core.safe_id(tool) .. ".json", {
        decision = "block",
        reason = "replay: no live account is reachable; this is the answer recorded with the task",
        additionalContext = "replay · connector answered from the recording · " .. tool .. ":\n" .. text,
      })
      counts.connector = counts.connector + 1
    end
  end
  -- The effect note is installed for the names this task itself used; the sink's default refusal covers
  -- every other hooked tool - both are refusals, and both are recorded.
  local used = {}
  for _, name in ipairs((task.catalogue or {}).tools_used or {}) do used[name] = true end
  -- Every effect tool this node's catalogue knows, not only the ones the task used: a call nested inside
  -- `tool_call` is matched by the inner name read from the arguments, so its decision has to exist before
  -- the run rather than being invented afterwards.
  local catalogue_ok, catalogue = pcall(function() return dofile("lua/core/tools.lua").catalog("master") end)
  if catalogue_ok and type(catalogue) == "table" then
    for _, item in ipairs(catalogue) do
      local name = type(item) == "table" and (item.name or item[1]) or nil
      if type(name) == "string" and core.is_effect(name) and not core.is_connector(name) then used[name] = true end
    end
  end
  for name in pairs(used) do
    if core.is_effect(name) and not core.is_connector(name) then
      core.write_json(decisions_dir .. "/" .. core.safe_id(name) .. ".json", {
        decision = "block",
        reason = "replay: this is an effect and the replay performs none; recorded as would-have-done",
        additionalContext = "replay · " .. name .. " was NOT executed. The attempt is recorded in the sink as would-have-done; nothing left this machine.",
      })
      counts.effect = counts.effect + 1
    end
  end
  record.decisions = counts
end

local function install_hooks(scratch, sink_path)
  local hooks = { hooks = {} }
  local entries = {}
  for _, pattern in ipairs(core.REPLAY_HOOK_MATCHERS) do
    entries[#entries + 1] = { name = "eval-sink", matcher = pattern, command = sink_path, timeout_ms = 10000 }
  end
  hooks.hooks.PreToolUse = entries
  local path = scratch .. "/home/.wasm-agent/hooks.json"
  if not core.write_json(path, hooks) then return nil, "the replay hook file could not be written" end
  return path
end

local function install_guards(scratch, record)
  local bindir = scratch .. "/bin"
  local real_git = (exec("command -v git", "", 60).stdout or ""):gsub("%s+$", "")
  if real_git == "" then return nil, "no git on this machine, so a replay workspace cannot be materialized" end
  if not write_exec(bindir .. "/git", (GIT_GUARD:gsub("__REAL_GIT__", real_git))) then
    return nil, "the replay git guard could not be written"
  end
  for _, name in ipairs({ "ssh", "scp", "sftp", "rsync", "gh" }) do
    local script = GUARD:gsub("${GUARD_NAME:-command}", name)
    if not write_exec(bindir .. "/" .. name, script) then return nil, "the replay guard for " .. name .. " could not be written" end
  end
  record.guards = { "git (remote verbs)", "ssh", "scp", "sftp", "rsync", "gh" }
  return bindir
end

local function child_env(scratch, opts, bindir)
  local home = scratch .. "/home"
  local pairs_ = {
    { "PATH", bindir .. ":/usr/local/bin:/usr/bin:/bin" },
    { "HOME", home },
    { "TMPDIR", scratch .. "/tmp" },
    { "WASM_AGENT_HOME", home },
    { "WASM_AGENT_DB", home .. "/.wasm-agent/memory.db" },
    { "WASM_AGENT_MANAGED", "0" },
    { "WASM_AGENT_RENDEZVOUS", "" },
    { "WASM_AGENT_RELAY", "" },
    { "WA_GRAPH_WATCH", "0" },
    -- Code mode is OFF in a replay, always: a nested tool call inside a script does not cross the hook
    -- boundary where a replay blocks effects (measured 12/11: the model reached `remote` from inside a
    -- script and the sink never saw it), so a replay that left it on could perform an effect while
    -- reporting none. A replay therefore measures the direct tool loop, and says so.
    { "WASM_AGENT_CODEMODE", "off" },
    { "WA_EVAL_SINK_DIR", scratch .. "/sink" },
    { "WA_EVAL_DECISIONS", scratch .. "/decisions" },
  }
  -- The model route is the one thing a replay cannot invent, and the one thing an operator must ask
  -- for: without `--model` the child has no provider and the run records `provider_unavailable` instead
  -- of reaching the node's own account. With it, only the route variables travel - never the whole node
  -- environment, never a connector credential.
  if opts.model then
    for _, name in ipairs({ "WASM_AGENT_VAULT_URL", "WASM_AGENT_VAULT_DIR", "WASM_AGENT_PROVIDER", "WASM_AGENT_MODEL" }) do
      local value = host.getenv(name)
      if value and value ~= "" then pairs_[#pairs_ + 1] = { name, value } end
    end
  end
  local parts = {}
  for _, pair in ipairs(pairs_) do parts[#parts + 1] = pair[1] .. "=" .. shquote(pair[2]) end
  return table.concat(parts, " ")
end

local function read_sink(scratch)
  -- The sink is read through what it RECORDED, not through what it was asked to do: `served.log` has one
  -- line per blocked call naming the decision that was served (a tool name, or `-` when the call had no
  -- recording and was refused by default), and the raw event files stay beside it as evidence.
  local record = { attempts = {}, effects = {}, connectors = {}, commands = {}, unrecorded = 0, events = 0 }
  for _, entry in ipairs(core.entries(scratch .. "/sink")) do
    if entry.kind == "file" and entry.name:match("^event%-") then record.events = record.events + 1 end
  end
  local log = host.read_file(scratch .. "/sink/served.log")
  local blocked = 0
  if log and log ~= "" then
    for name in log:gmatch("[^\n]+") do
      blocked = blocked + 1
      if name == "-" or name == "" then
        record.unrecorded = record.unrecorded + 1
        record.attempts[#record.attempts + 1] = { decision = "blocked, no recording for it" }
      elseif core.is_connector(name) then
        record.connectors[#record.connectors + 1] = { tool = name, decision = "blocked, answered from the recording" }
      elseif core.is_effect(name) then
        record.effects[#record.effects + 1] = { tool = name, decision = "blocked, would have done" }
      else
        record.attempts[#record.attempts + 1] = { tool = name, decision = "blocked" }
      end
    end
  end
  record.blocked = blocked
  local commands = host.read_file(scratch .. "/sink/commands.log")
  if commands and commands ~= "" then
    for line in commands:gmatch("[^\n]+") do record.commands[#record.commands + 1] = line end
  end
  return record
end

local function evaluate(check, scratch, ws)
  check = check or { kind = "human" }
  if check.kind == "human" then return { state = "needs-human" } end
  if check.kind == "command" then
    local cmd = "env -i PATH=" .. shquote(scratch .. "/bin:/usr/local/bin:/usr/bin:/bin")
      .. " HOME=" .. shquote(scratch .. "/home")
      .. " WA_EVAL_SINK_DIR=" .. shquote(scratch .. "/sink")
      .. " sh -c " .. shquote(check.command or "")
    local ran = exec(cmd, ws, 900)
    local state = ran.status == 0 and "pass" or "fail"
    local result = { state = state, exit = ran.status, rule = "the check command's exit status" }
    if state == "fail" then result.detail = tostring((ran.stderr or ""):gsub("%s+$", "")):sub(1, 400) end
    return result
  end
  if check.kind == "file" then
    local text = host.read_file(ws .. "/" .. tostring(check.path or ""))
    if not text then return { state = "fail", detail = "the file the check names is not there" } end
    if check.contains and check.contains ~= "" and not text:find(check.contains, 1, true) then
      return { state = "fail", detail = "the file is there and does not contain the text the check names" }
    end
    return { state = "pass", rule = "the file assertion" }
  end
  return { state = "unknown", detail = "unknown check kind " .. tostring(check.kind) }
end

-- `wa eval run <task|--all> --bin <path> [--model] [--timeout S] [--keep-scratch]`
function M.run(task, opts)
  opts = opts or {}
  local bin = opts.bin and tostring(opts.bin) or ""
  if bin == "" then return nil, "a replay needs --bin <path to the wa binary that should answer>" end
  if not bin:match("^[/\\]") and not bin:match("^%a:[/\\]") then
    return nil, "--bin must be an absolute path (a bare name would resolve against the replay's own PATH)"
  end
  local probe_sh = exec("sh -c 'exit 0'", "", 60)
  if probe_sh.status ~= 0 then return nil, "replay needs a POSIX shell (sh) on this machine" end

  local home = paths.home()
  local scratch, scratch_error = make_scratch(task.id or "task")
  if not scratch then return nil, scratch_error end
  if inside(scratch, home) then
    exec("rm -rf " .. shquote(scratch), "", 60)
    return nil, "refusing a scratch directory inside this node's home: " .. scratch
  end
  write_text(scratch .. "/" .. MARKER, "harness-evaluator replay\n")

  local existing = {}
  for _, id in ipairs(core.run_ids()) do existing[id] = true end
  local run_id = run_id_for(task.id or "task", existing)
  local record = {
    schema = core.SCHEMA,
    id = run_id,
    task_id = task.id,
    category = task.category,
    check = task.check,
    bin = bin,
    started_at = host.now(),
    isolation = {
      scratch = scratch,
      marker = MARKER,
      operator_home = home,
      scratch_inside_operator_home = false,
      environment = "env -i with an allowlist (HOME, ledger, PATH, sink); no node env, no rendezvous, no relay",
      model_route = opts.model and "passed through at the operator's request" or "none (no provider in the child)",
      connectors = "blocked by the replay hook; answers come from the task's recording",
      effects = "blocked by the replay hook and the PATH guards; recorded as would-have-done",
      code_mode = "off: a tool call nested in a code-mode script does not cross the replay hook, so a replay measures the direct tool loop",
    },
    rules = {
      tokens = "sum of harness_events kind=model_call normalized usage",
      refusals = "sink denials plus tool results whose text starts with " .. table.concat(core.REFUSAL_PREFIXES, ", "),
      success = "the task's own check; `human` stays needs-human until `wa eval verdict`",
    },
  }

  local ws, workspace_error = materialize(task, scratch, record)
  if not ws then
    record.error = workspace_error
    record.metrics = core.metrics({ messages = {}, events = {} })
    record.wall_ms = 0
    record.outcome = { state = "error", detail = workspace_error }
    core.record_run(record)
    return record
  end

  local sinkdir = scratch .. "/sink"
  exec("mkdir -p " .. shquote(sinkdir) .. " " .. shquote(scratch .. "/decisions") .. " " .. shquote(scratch .. "/home") .. " " .. shquote(scratch .. "/tmp"), "", 120)
  local sink_path = scratch .. "/sink.sh"
  if not write_exec(sink_path, SINK) then
    record.error = "the replay sink could not be written"
    record.outcome = { state = "error", detail = record.error }
    core.record_run(record)
    return record
  end
  install_decisions(task, scratch .. "/decisions", record)
  local hooks_error
  local hooks_path
  hooks_path, hooks_error = install_hooks(scratch, sink_path)
  if not hooks_path then
    record.error = hooks_error
    record.outcome = { state = "error", detail = hooks_error }
    core.record_run(record)
    return record
  end
  local bindir, guard_error = install_guards(scratch, record)
  if not bindir then
    record.error = guard_error
    record.outcome = { state = "error", detail = guard_error }
    core.record_run(record)
    return record
  end
  record.hooks = hooks_path
  write_text(scratch .. "/prompt.txt", tostring(task.prompt or "") .. "\n")

  local seconds = tonumber(opts.timeout) or 900
  -- The prompt travels on STDIN and no prompt word goes on the command line: a non-terminal stdin already
  -- means "scripted" (lua/core/chat.lua: the turn runs, the session's claim is released, the process
  -- exits), and a binary older than `--once` would take that word as the prompt. `timeout` is the hard
  -- bound either way.
  local command = "cd " .. shquote(ws) .. " && env -i " .. child_env(scratch, opts, bindir)
    .. " timeout " .. math.floor(seconds) .. " " .. shquote(bin) .. " chat < " .. shquote(scratch .. "/prompt.txt")
  -- The exact command line, kept as evidence: a replay must be reproducible by hand.
  record.command = command
  local began = host.monotonic_ms()
  local ran = exec(command, ws, math.floor(seconds) + 120)
  record.wall_ms = host.monotonic_ms() - began
  record.exit_code = ran.status
  record.timed_out = ran.status == 124
  record.stdout_bytes = #tostring(ran.stdout or "")
  record.stdout_tail = tostring(ran.stdout or ""):sub(-2000)
  record.stderr_tail = tostring(ran.stderr or ""):sub(-1200)

  -- Read the replay's own ledger back: the dump script travels into the scratch root and runs with the
  -- candidate binary, so no second database is opened by this process and no sqlite3 is required.
  local dump_path = scratch .. "/ledger-dump.lua"
  local dump = { sessions = {}, messages = {}, events = {}, runs = {} }
  if write_text(dump_path, DUMP) then
    local dumped = exec("env -i PATH=" .. shquote(bindir .. ":/usr/local/bin:/usr/bin:/bin")
      .. " HOME=" .. shquote(scratch .. "/home")
      .. " WASM_AGENT_HOME=" .. shquote(scratch .. "/home")
      .. " WASM_AGENT_DB=" .. shquote(scratch .. "/home/.wasm-agent/memory.db")
      .. " WA_SCRIPT=" .. shquote(dump_path)
      .. " WA_EVAL_DUMP_OUT=" .. shquote(scratch .. "/ledger.json")
      .. " timeout 120 " .. shquote(bin) .. " --db " .. shquote(scratch .. "/home/.wasm-agent/memory.db"), scratch, 180)
    -- The dump writes its answer to a file (see DUMP: stdout is bounded and truncation would cut the
    -- JSON); stdout carries only a one-line receipt.
    local text = host.read_file(scratch .. "/ledger.json") or ""
    local ok, decoded = pcall(json.decode, text)
    if ok and type(decoded) == "table" and type(decoded.messages) == "table" then dump = decoded
    else record.dump_error = "the replay ledger could not be read back" end
  end

  local metrics = core.metrics({ messages = dump.messages, events = dump.events })
  local sink = read_sink(scratch)
  metrics.refusals = (metrics.refusals or 0) + (sink.blocked or 0)
  metrics.effects_attempted = (metrics.effects_attempted or 0) + #sink.effects + #sink.commands
  record.metrics = metrics
  record.effects = {
    would_have_done = sink.effects,
    blocked_tool_calls = sink.attempts,
    refused_without_recording = sink.unrecorded,
    commands_refused = sink.commands,
    connector_answers_from_recording = sink.connectors,
    blocked_total = sink.blocked,
  }
  record.outcome = evaluate(task.check, scratch, ws)
  if (record.exit_code or 1) ~= 0 and record.outcome.state ~= "pass" then
    record.outcome.exit_note = record.timed_out and "the run hit its time limit" or "the run exited non-zero"
  end
  if (record.metrics.model_calls or 0) == 0 and not opts.model then
    record.outcome.detail = (record.outcome.detail or "") .. (record.outcome.detail and "; " or "")
      .. "no model was reachable in the replay (no --model), so this run measured the harness, not an answer"
  end

  -- Evidence: the transcript and the sink stay in the run's own directory (inside the state dir, which is
  -- where personal data is allowed to live); the scratch tree goes away.
  local run_dir = core.runs_dir() .. "/" .. run_id
  core.write_json(run_dir .. "/ledger.json", dump)
  core.write_json(run_dir .. "/sink.json", sink)
  record.kept_scratch = opts.keep_scratch and true or false
  record.scratch_entries = #core.entries(scratch)
  core.record_run(record)
  if not opts.keep_scratch then
    local marker = host.read_file(scratch .. "/" .. MARKER)
    if marker then exec("rm -rf " .. shquote(scratch), "", 120) end
  end
  return record
end

return M
