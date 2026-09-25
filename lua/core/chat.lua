-- Interactive `wa` chat: model + memory, with local slash commands.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")
-- Where this chat is running, for the banner and the footer: `platform.cwd()` is the
-- host's own working directory and `paths.home()` the home to abbreviate it against
-- (never `$HOME` or a drive letter, per AGENTS.md and docs/HOST.md).
local platform = dofile("lua/core/platform.lua")
local paths = dofile("lua/core/paths.lua")
-- Everything this REPL prints is captured by whatever launched it (a terminal,
-- an orchestrator, a test), so it all goes out through the redactor.
local redact = dofile("lua/core/redact.lua")
local updater = dofile("lua/core/update.lua")
-- What a run looks like while it is running. The view owns the status line, the tool
-- lines and the footer; this file owns the session, the commands and the prompt.
local cli_view = dofile("lua/core/cli_view.lua")
-- The reader's input. It is the host that reads it, on a thread of its own, because this
-- interpreter spends the run blocked inside the model call - see that module for why
-- `io.read("*l")` here was the reason nothing could be typed while a run was in flight.
local cli_input = dofile("lua/core/cli_input.lua")
-- `/merge`: the git orchestrator brief. The node does not perform the merge (the worktrees live
-- outside it); the command hands the agent the intent with the hand-off rule suspended.
local merger = dofile("lua/core/merge.lua")
-- `/efficiency_report`: a deterministic read of the harness ledger and the transcript - what the
-- last call sent, what it cost, and which part did not come from the provider's prefix cache. No
-- model call, so it can be run mid-session without spending anything or changing the thread.
local efficiency = dofile("lua/core/efficiency.lua")

local M = {}

-- The CLI runs as one user on one node; sessions are keyed by both, so the same
-- machine can keep separate threads per user.
local USER, NODE = "master", ""

-- The commands, their help and the flags that select a session are one registry
-- (`lua/core/commands.lua`), so the list a reader is shown and the arms below cannot drift apart, and
-- `scripts/test-command-parity.cjs` can fail when this REPL is missing a command the window offers.
local commands = dofile("lua/core/commands.lua")

local HELP = commands.help()

local function each(rows, render, output)
  output = output or print
  if #rows == 0 then output("(empty)") return end
  for _, row in ipairs(rows) do output(render(row)) end
end

local function memory_line(row)
  local tags = (#row.tags > 0) and (" [" .. table.concat(row.tags, ", ") .. "]") or ""
  return string.format("%s  %s%s  %s", row.id, row.scope, tags, row.content)
end

-- Streaming printer. `wa chat` is launched as a TUI agent (Orca, or a
-- terminal), so output must appear as it is produced: a silent terminal looks
-- hung, and an orchestrator waiting for the terminal to go idle cannot tell the
-- difference between working and stuck.
--
-- The events are handed to the view rather than formatted here, because the shape of a
-- run's output is one decision, not two: `lua/core/cli_view.lua` renders the same
-- events live in a terminal and plainly when this output is captured. The redactor
-- still wraps everything that carries tool or provider text.
local function printer(view)
  return function(event)
    local ready = event
    if event.type == "tool_result" then
      -- Tool results are usually tables (bash returns {code, stdout, stderr}); the view
      -- reads the fields it knows and redacts whatever text it prints.
      local value = event.result
      if type(value) == "table" then
        local clean = {}
        for key, field in pairs(value) do
          clean[key] = (type(field) == "string") and redact.text(field) or field
        end
        value = clean
      elseif type(value) == "string" then
        value = redact.text(value)
      end
      ready = { type = event.type, name = event.name, result = value }
    elseif event.type == "reasoning" then
      -- Reasoning is model output and goes through the redactor for the same reason a tool's
      -- output does: it is text this process did not write and is about to print.
      ready = { type = "reasoning", text = redact.text(tostring(event.text or "")) }
    end
    -- A rendering bug must not kill the run it is describing, and must not be silent
    -- either: the view says so once and the run keeps going.
    local handled, problem = pcall(view.event, view, ready)
    if not handled then view:warn(redact.text(tostring(problem))) end
  end
end

-- Where this chat is running, and on which branch: pi shows both in front of the
-- reader, and a chat in the wrong worktree is otherwise a mistake that costs an hour to
-- notice. Both live in `cli_view` because both are what the banner prints.
function M.run(argv)
  argv = argv or {}
  -- Session selection. A new thread is the default; `--continue` resumes the
  -- most recent one; `--session <id>` picks exactly that one. A bare word is the
  -- first prompt, so a launcher can start the agent with work already queued.
  local session_id, resume_last, prompt = nil, false, {}
  local index = 2
  while argv[index] do
    local arg = argv[index]
    if arg == "--session" then
      session_id = argv[index + 1]
      index = index + 2
    elseif arg == "--continue" or arg == "-c" then
      resume_last = true
      index = index + 1
    elseif arg == "--help" or arg == "-h" then
      print(HELP)
      return 0
    else
      prompt[#prompt + 1] = arg
      index = index + 1
    end
  end
  prompt = table.concat(prompt, " ")

  -- Which thread this process runs in. Conversational history is the transcript
  -- of that thread; remembered facts live in memory and are deliberately
  -- independent of it, so `--continue` never changes what `recall` finds.
  local session
  if session_id then
    if session_id == "" then
      print("  --session needs an id; list them with: wa sessions")
      return 2
    end
    session = memory.session(session_id)
    if not session then
      print("  no such session: " .. session_id)
      print("  list them with: wa sessions")
      return 2
    end
  elseif resume_last then
    session = memory.latest_session(USER, NODE)
    if not session then print("  nothing to continue; starting a new session") end
  end
  if not session then
    local id = memory.start_session(NODE, "chat", { user_id = USER, node_id = NODE, title = "chat" })
    session = memory.session(id) or { id = id }
  end

  local settings = provider.settings()
  local mode = provider.configured() and (settings.model .. " @ " .. settings.base_url)
    or "local mode (no model configured)"
  -- Where this chat is, for the banner and the footer. `host.paths()` is the only
  -- supported way to ask for the home directory (AGENTS.md): the environment lies on
  -- Windows, and it does not answer for the working directory at all - that is
  -- `host.runtime_info().cwd`, wrapped by `platform.lua`.
  local cwd = platform.cwd()
  local workspace = cli_view.workspace(cwd, paths.home())
  local reasoning = (function()
    local ok, value = pcall(provider.reasoning, settings.model)
    if not ok or type(value) ~= "table" or not value.supported then return "" end
    -- "provider" is what the node says when it has no level of its own to report: it
    -- means "the endpoint decides", which is not a level a reader can act on.
    local selected = value.selected or ""
    return selected == "provider" and "" or selected
  end)()
  local view = cli_view.new({
    -- The terminal title names the worktree, the way pi names the workspace it is
    -- running in; while a run is in flight it carries the phase instead.
    title = "wa - " .. (workspace:match("([^/]+)$") or "chat"),
    workspace = workspace,
    branch = cli_view.branch(cwd),
    -- The model's own window, the same one compaction uses; the env global is only a
    -- fallback inside `cli_view.window`. Reading the global here reported a 1,000,000-token
    -- model as 128.0k and made the footer's percentage eight times too high.
    budget = cli_view.window(settings.model, function(model) return provider.budget(model) end),
    -- The terminal width when it says so, and otherwise the width every terminal has: a
    -- status line that wraps is erased only on its last row, which leaves the row above it
    -- behind as litter.
    -- The terminal's real width, asked of the console rather than assumed: `COLUMNS` is a shell
    -- variable that is normally not exported, and a CLI that fell back to 80 wrapped its answers
    -- into a third of a wide window. See `platform.columns`.
    limit = platform.columns(host.getenv("COLUMNS")),
  })
  -- Commands must use the view's scroll region, not Lua's global print at the
  -- hardware cursor (which now belongs to the native editor). The view writer is
  -- serialized with the input thread and the ticker by host.terminal_write.
  local function print(text) view:line(text or "") end
  local agent = agentlib.new(session.id, printer(view), "master", USER, NODE)
  -- The host reads complete lines while the interpreter is in a provider/tool call.
  -- Give the next model round any waiting messages; slash commands still belong to
  -- the REPL and remain queued for after the run.
  local height = view.rows()
  local input = cli_input.new({ editor = view.live and view.stdout and height and height >= 7
    and host.getenv("WASM_AGENT_CLI_FRAME") ~= "off" })
  view.editor = input.editor
  agent.steer = function()
    local lines = input:take_steering()
    for _, line in ipairs(lines) do view:accepted(line) end
    return lines
  end

  print("")
  print(cli_view.banner({
    live = view.live,
    version = "0.1.0",
    model = mode .. (reasoning ~= "" and ("  \194\183  reasoning " .. reasoning) or ""),
    database = host.getenv("WASM_AGENT_DB") or "~/.wasm-agent/memory.db",
    session = agent.session_id,
    continued = resume_last,
    workspace = view.workspace,
    branch = view.branch,
    -- The banner is the last place a user can be told before they type: a thread
    -- that was cut off mid-answer looks like one that is simply quiet, and the
    -- recovery below (the model is told in its context) is invisible from here.
    unfinished = (function()
      local session_state = memory.session_state(agent.session_id)
      if session_state and session_state.state == "unfinished" then return session_state.detail end
      return nil
    end)(),
  }))
  print("")

  local function turn(line)
    view:run_started()
    local ok, reply = pcall(agent.run, agent, line)
    if not ok then
      view:failed(redact.text(tostring(reply)))
    else
      -- The view prints the reply when nothing streamed (an error before the first
      -- token, or a provider without streaming), so the turn is never silent.
      view:answered(reply)
    end
  end

  if prompt ~= "" then turn(prompt) end

  -- The input, and where the prompt is drawn. Both matter to the same thing: a reader who can see
  -- where they are typing, and who is not locked out while the agent works. The prompt is drawn
  -- once per wait rather than in a loop, because the prompt and the reader's typing share a row -
  -- a redraw on a timeout would erase what they have typed so far.
  local function read_line()
    view:prompt("wa> ")
    while true do
      local line, eof = input:poll(cli_input.WAIT_MS)
      if line ~= nil then
        -- The reader's own line, into the transcript, before the input row is reused: the echo of
        -- it lives only on that row, and a message that vanishes when it is sent is one its author
        -- cannot check. See `cli_view.accepted`.
        view:accepted(line)
        -- The terminal echoes a submitted line on the input row. Reclaim it before
        -- the synchronous run starts; otherwise it stays there for the entire run.
        view:submitted()
        return line
      end
      -- The input ended: a closed pipe, or the terminal's own end-of-file. Nothing left to wait
      -- for, and a REPL that keeps prompting for a stream it cannot read is worse than one that
      -- stops, so the loop ends.
      if eof then return nil end
    end
  end

  while true do
    local line = read_line()
    if line == nil then break end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
      -- keep prompting
    elseif line == "/exit" or line == "/quit" then
      break
    elseif line == "/help" then
      print(HELP)
    elseif line == "/session" then
      print(agent.session_id)
    elseif line == "/new" then
      -- The window's `/new`, in the REPL. The session being left is not closed: `M:close` finishes a
      -- session, and this thread is not finished, only left - `wa chat --session <id>` comes back to
      -- it, and `wa sessions` still lists it.
      local previous = agent.session_id
      local id, notice = commands.new_session({ previous = previous, user = USER, node = NODE })
      agent = agentlib.new(id, printer(view), "master", USER, NODE)
      agent.steer = function()
        local lines = input:take_steering()
        for _, text in ipairs(lines) do view:accepted(text) end
        return lines
      end
      print(redact.text(notice))
    elseif line == "/stats" then
      print(json.encode(memory.stats()))
    elseif line == "/console" then
      -- The console is the raw view of the same run: every event as it arrived, and a tool's
      -- output whole. It is a toggle rather than a flag on the launcher because the question
      -- ("what is it actually doing?") arrives in the middle of a run, not before it.
      local on = view:set_console(not view:console_on())
      print(on and "  console on: every event, and a tool's output unclipped"
        or "  console off: the formatted view")
    elseif line == "/update" then
      -- The same report the window gets from POST /update, and the same sentence: this node cannot
      -- replace itself, so the answer is what it decided and what it queued for the sentinel.
      local report = updater.run({ reason = "requested from the interactive chat" })
      print(redact.text(report.message or json.encode(report)))
      if report.next then print(redact.text("  next: " .. report.next)) end
    elseif line == "/merge" then
      -- Not a node operation: the merge runs outside this process, in the worktrees. The command
      -- is the agent's brief, and it names the skill that holds the procedure.
      turn(merger.brief)
    elseif line == "/efficiency_report" then
      -- Deterministic: it reads the ledger and the transcript, writes the prefix artifact, and
      -- prints. It is not sent to the model, so it cannot spend a token or change the thread.
      local text = efficiency.report({ session_id = agent.session_id, agent = agent, hours = 48 })
      print(redact.text(text))
    elseif line == "/memories" then
      each(memory.memories(nil, 50), memory_line, print)
    elseif line:sub(1, 10) == "/remember " then
      print(memory.remember(line:sub(11)))
    elseif line:sub(1, 8) == "/recall " then
      each(memory.recall(line:sub(9), 10), memory_line, print)
    elseif line:sub(1, 8) == "/search " then
      each(memory.search_ledger(line:sub(9), nil, 20), function(row)
        return string.format("%s  %s  %s", row.conversation_id, row.sender_id or "-", row.body)
      end, print)
    elseif line:sub(1, 14) == "/conversation " then
      each(memory.conversation(line:sub(15), 50), function(row)
        return string.format("%s  %s  %s", row.conversation_id, row.sender_id or "-", row.body)
      end, print)
    else
      turn(line)
    end
  end
  agent:close()
  -- The screen's scroll region is not this process's to leave set: a shell whose output scrolls only
  -- the top rows of the window is a bug the next reader gets to explain.
  input:stop() -- restore terminal echo before returning the screen to the shell
  view:screen_off()
  -- Tell the host to stop reading stdin. Not required for correctness - the thread dies with the
  -- process - but this is the one place that knows the REPL is finished rather than blocked.
  return 0
end

return M
