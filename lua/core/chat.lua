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
-- `/vault`: keys the agent uses by reference and never sees (see that module).
local keys = dofile("lua/core/keys.lua")
-- `!command`: Claude Code's bash mode (see that module).
local bash_mode = dofile("lua/core/bash_mode.lua")
-- Restarting into the same session when a new build is installed or a restart is asked for.
local cli_restart = dofile("lua/core/cli_restart.lua")
-- `/status`: the session, its usage and every provider's limits, as bars.
local status = dofile("lua/core/status.lua")

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
  local binding=dofile('lua/core/binding.lua')
  if binding.present() then
    local transport=host.binding_transport and json.decode(host.binding_transport('start'))
    if not transport or not transport.ok then print('binding_transport_unavailable: '..tostring(transport and transport.error));return 2 end
  end
  argv = argv or {}
  -- Session selection. A new thread is the default; `--continue` resumes the
  -- most recent one; `--session <id>` picks exactly that one. A bare word is the
  -- first prompt, so a launcher can start the agent with work already queued.
  local session_id, resume_last, prompt = nil, false, {}
  local index = 2
  while argv[index] do
    local arg = argv[index]
    if arg == "--session" or arg == "--resume" then
      session_id = argv[index + 1] or ""
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
      print("--resume needs an id; list them with: wa sessions")
      return 2
    end
    session = memory.session(session_id)
    if not session then
      print("no such session: " .. session_id)
      print("list them with: wa sessions")
      return 2
    end
  elseif resume_last then
    session = memory.latest_thread(USER, NODE)
    if not session then print("nothing to continue; starting a new session") end
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
  -- The model in use, shown at the right of the footer under the input; read again after /login
  -- and /provider, which can change it.
  local function refresh_model()
    local current = provider.settings()
    local level = (function()
      local ok, value = pcall(provider.reasoning, current.model)
      if not ok or type(value) ~= "table" or not value.supported then return "" end
      return (value.selected == "provider" or not value.selected) and "" or value.selected
    end)()
    view.model = provider.configured() and (tostring(current.model) .. (level ~= "" and ("\194\183" .. level) or ""))
      or "no model"
  end
  refresh_model()
  local agent = agentlib.new(session.id, printer(view), "master", USER, NODE)
  -- What is on disk now is the build this process runs: a later change is a new install.
  if host.binary_changed then pcall(host.binary_changed) end
  -- The host reads complete lines while the interpreter is in a provider/tool call.
  -- Give the next model round any waiting messages; slash commands still belong to
  -- the REPL and remain queued for after the run.
  local height = view.rows()
  local input = cli_input.new({ editor = view.live and view.stdout and height and height >= 7
    and host.getenv("WASM_AGENT_CLI_FRAME") ~= "off" })
  view.editor = input.editor
  -- The slash menu: typing `/` lists these under the box, the way Claude Code does.
  if input.editor and host.input_commands then pcall(host.input_commands, json.encode(commands.menu())) end
  -- Set once the view is up (below): the `/status` snapshot refreshed at every round of a run.
  local refresh_status
  agent.steer = function()
    if refresh_status then refresh_status() end
    local lines = input:take_steering()
    for _, line in ipairs(lines) do view:accepted(line) end
    return lines
  end

  -- The screen first, so the welcome block is output like any other and sits right above the input.
  view:screen_on()
  print(cli_view.banner({
    live = view.live,
    limit = (view.live and cli_view.terminal_columns()) or view.limit,
    version = "0.1.0",
    model = mode .. (reasoning ~= "" and ("  \194\183  reasoning " .. reasoning) or ""),
    database = host.getenv("WASM_AGENT_DB") or "~/.wasm-agent/memory.db",
    session = agent.session_id,
    continued = resume_last or session_id ~= nil,
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

  -- A continued thread (`--continue`, `--resume <id>`) is drawn again under the banner, so the reader
  -- picks up where the window was closed instead of in front of an empty screen. The newest messages
  -- only: a day-long thread is hundreds of rows, and the window or `wa conversation` has the rest.
  if resume_last or session_id then
    local REPLAY = tonumber(host.getenv("WASM_AGENT_CLI_REPLAY")) or 400
    if REPLAY > 0 then
      local rows = memory.session_messages(agent.session_id, { all = true }) or {}
      local skipped = math.max(0, #rows - REPLAY)
      if skipped > 0 then
        local newest = {}
        for index = skipped + 1, #rows do newest[#newest + 1] = rows[index] end
        rows = newest
      end
      -- Drawn once, at the end: a frame per row is what made a long thread take a minute to appear.
      local hold = host.transcript_hold
      if hold then pcall(hold, true) end
      local replayed, problem = pcall(view.replay, view, rows, { skipped = skipped })
      if hold then pcall(hold, false) end
      if not replayed then view:warn(redact.text("could not draw the earlier transcript: " .. tostring(problem))) end
    end
  end
  -- Started by a restart (lua/core/cli_restart.lua): say why, under the transcript it drew again.
  local restarted = host.getenv("WA_CLI_RESTARTED")
  if restarted and restarted ~= "" then
    print(cli_view.paint("  \226\134\187 restarted: " .. redact.text(restarted), "dim", view.live))
  end

  -- `/status` as a panel spec. One module instance for the chat, so the limits it read are reused.
  local function status_panel(opts)
    local rows = {}
    for _, row in ipairs(status.session_lines(agent.session_id, opts)) do rows[#rows + 1] = redact.text(row) end
    return { title = "Status", lines = rows }
  end
  -- What the host shows if `/status` is submitted while a run is in flight (Lua is blocked in the model
  -- call then): refreshed at the start of a run and at every round, from limits already read - the
  -- provider is asked at most every five minutes, at a run's start, never in the middle of one.
  local function snapshot_status(opts)
    if not (host.status_snapshot and view.editor and view.stdout) then return end
    local built, spec = pcall(status_panel, opts)
    if built then pcall(host.status_snapshot, json.encode(spec)) end
  end

  refresh_status = function() snapshot_status({ color = view.live, cached = true }) end

  local function turn(line)
    snapshot_status({ color = view.live, max_age = 300 })
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

  if prompt ~= "" then view:prompt(); turn(prompt) end

  -- 29/10: a continued thread whose last run stopped without an answer (the CLI was killed mid-run, or
  -- the provider cut the stream past its retries) is re-driven now, from the recorded state, instead
  -- of waiting for the reader to notice and type. One attempt per interruption; the host's session
  -- claim refuses it while another live process still owns the thread (lua/core/run_recovery.lua).
  if prompt == "" and (resume_last or session_id) then
    local found, recovery = pcall(function() return dofile("lua/core/run_recovery.lua").due(agent.session_id) end)
    if found and recovery then
      print(cli_view.paint("  \226\134\187 resuming the interrupted run: " .. redact.text(recovery.reason), "dim", view.live))
      view:prompt(); turn(recovery.prompt)
    end
  end

  -- The input, and where the prompt is drawn. Both matter to the same thing: a reader who can see
  -- where they are typing, and who is not locked out while the agent works. The prompt is drawn
  -- once per wait rather than in a loop, because the prompt and the reader's typing share a row -
  -- a redraw on a timeout would erase what they have typed so far.
  -- Restart between runs, never over anything the reader is doing; a refusal is said once.
  local restart_checked, restart_refused = 0, nil
  local function restart(reason)
    local message, torn = cli_restart.restart(agent.session_id, reason, function()
      print("  restarting: " .. reason .. " - session " .. agent.session_id .. " continues")
      input:stop()
      view:screen_off()
    end)
    if torn then io.write(redact.text(message) .. "\n"); os.exit(1) end
    print(redact.text(message))
    -- Remembered with its time: the loop guard refuses for its window only, and a refusal kept forever
    -- left a CLI on a replaced binary for hours after the churn that tripped it (28/10).
    restart_refused = { reason = reason, at = host.now() }
  end
  local function restart_if_due()
    local now = host.now()
    if now - restart_checked < cli_restart.CHECK_SECONDS then return end
    restart_checked = now
    local reason = cli_restart.reason()
    local refused = restart_refused
    local settled = not refused or refused.reason ~= reason or now - refused.at > cli_restart.WINDOW
    if reason and settled and cli_restart.idle() then restart(reason) end
  end

  -- Turns another process adds to this session - a sentinel wake runs on the node, the window may
  -- continue the same thread - are drawn here as they land, so what the sentinel reports back reaches
  -- the reader in this terminal too. Only at the idle prompt (the same 2 s wake as the restart check)
  -- and only beyond what this CLI has already shown; its own turns are marked seen as they end.
  local seen_seq, last_caught = 0, nil
  local function mark_seen()
    local ok, bounds = pcall(memory.session_message_bounds, agent.session_id)
    seen_seq = ok and tonumber(bounds and bounds.last_seq) or seen_seq
  end
  mark_seen()
  local function catch_up()
    if not (view.editor and view.stdout) then return end
    local ok, bounds = pcall(memory.session_message_bounds, agent.session_id)
    local last = ok and tonumber(bounds and bounds.last_seq) or 0
    if last <= seen_seq then return end
    local fetched, rows = pcall(memory.session_messages, agent.session_id, { all = true, after_seq = seen_seq })
    seen_seq = last
    if not fetched or type(rows) ~= "table" or #rows == 0 then return end
    -- One header per burst: a wake lands as its prompt, then its reply a few seconds later.
    if host.now() - (last_caught or 0) > 60 then
      view:line(cli_view.paint("  \226\134\187 added to this session elsewhere (the node, a sentinel wake):", "dim", view.live))
    end
    last_caught = host.now()
    local hold = host.transcript_hold
    if hold then pcall(hold, true) end
    pcall(view.replay, view, rows, { rule = false })
    if hold then pcall(hold, false) end
  end

  local function read_line()
    view:prompt()
    while true do
      restart_if_due()
      catch_up()
      -- Woken every CHECK_SECONDS (not WAIT_MS, half an hour) so an install is noticed at an idle
      -- prompt; the prompt is drawn once, above, so a wake that brings no line redraws nothing.
      local line, eof = input:poll(math.min(cli_input.WAIT_MS, cli_restart.CHECK_SECONDS * 1000))
      if line ~= nil then
        -- The reader's own line, into the transcript, before the input row is reused: the echo of
        -- it lives only on that row, and a message that vanishes when it is sent is one its author
        -- cannot check. See `cli_view.accepted`.
        -- A `/vault` line is echoed by name only: its value is never written to the transcript.
        view:accepted(line:match("^%s*/vault%s") and keys.masked(line:gsub("^%s+", "")) or line)
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

  -- Ask once, on start, and say one line only when this node is actually behind. Pi's version check
  -- is the model (see its `version-check.js`): the answer is cached, a failure is silent rather than
  -- an error on every start, and `unknown` - no recorded release, unreachable feed - prints nothing,
  -- because "I could not ask" repeated at every prompt is noise, not information.
  if not host.getenv("WA_SKIP_UPDATE_CHECK") then
    local seen = dofile("lua/core/release.lua").check({
      installed = dofile("lua/core/release.lua").installed(updater.installed_record()),
    })
    if seen.state == "behind" then
      print(redact.text("update available: " .. (seen.message or "a newer release is published") .. " - /update installs it"))
    end
  end

  while true do
    -- Whatever the last command wrote (a turn, a `!` line, /new) is this CLI's own: already shown.
    mark_seen()
    local line = read_line()
    if line == nil then break end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
      -- keep prompting
    elseif line == "/exit" or line == "/quit" then
      break
    elseif line == "/help" then
      print(HELP)
    elseif line == "/bind" or line:sub(1, 6) == "/bind " then
      dofile('lua/core/binding_cli.lua').run('bind',line:sub(7),read_line,print)
    elseif line == "/unbind" then
      dofile('lua/core/binding_cli.lua').run('unbind','',read_line,print)
    elseif line == "/nodes" then
      -- The cluster as a panel to move through, like /login; `/nodes pending` stays a binding command.
      local panel = dofile('lua/core/cli_panel.lua')
      local panels = view.editor and view.stdout and panel.available()
      local done, problem = pcall(dofile('lua/core/nodes_cli.lua').run, {
        print = print,
        panel = panels and panel.open or nil,
        paint = function(text, role) return cli_view.paint(text, role, view.live) end,
      })
      if panels then panel.close() end
      if not done then print(redact.text(tostring(problem))) end
    elseif line:sub(1, 7) == "/nodes " then
      dofile('lua/core/binding_cli.lua').run('nodes',line:sub(8),read_line,print)
    elseif line == "/accept" or line:sub(1, 8) == "/accept " then
      dofile('lua/core/binding_cli.lua').run('accept',line:sub(9),read_line,print)
    elseif line == "/promote" or line:sub(1, 9) == "/promote " then
      dofile('lua/core/binding_cli.lua').run('promote',line:sub(10),read_line,print)
    elseif line == "/demote" or line:sub(1, 8) == "/demote " then
      dofile('lua/core/binding_cli.lua').run('demote',line:sub(9),read_line,print)
    elseif line == "/revoke" or line:sub(1, 8) == "/revoke " then
      dofile('lua/core/binding_cli.lua').run('revoke',line:sub(9),read_line,print)
    elseif line == "/session" then
      print(agent.session_id)
    elseif line == "/status" then
      -- A panel, like /model: Esc, Left or Enter goes back to the chat. Printed where there is none.
      -- During a run the host shows it by itself (see `status_snapshot` above); this arm is between runs.
      local panel = dofile('lua/core/cli_panel.lua')
      if view.editor and view.stdout and panel.available() then
        panel.open(status_panel({ color = view.live }))
        panel.close()
      else
        print(redact.text(status.session_report(agent.session_id)))
      end
    elseif line == "/restart" then
      restart_refused = nil
      restart("restart requested from the chat")
    elseif line:sub(1, 1) == "!" then
      -- Bash mode: run here, show it, record it as context; no model turn (lua/core/bash_mode.lua).
      local command = bash_mode.command(line)
      if not command then print("  ! needs a command, e.g. !git status")
      else
        local done, problem = pcall(bash_mode.run, command, { session_id = agent.session_id, cwd = platform.cwd(), view = view })
        if not done then print(redact.text("  ! failed: " .. tostring(problem))) end
      end
    elseif line == "/vault" or line:sub(1, 7) == "/vault " then
      -- Handled here and nowhere else: the line never reaches `turn`, so the value never reaches a
      -- model, a transcript row or the ledger. Without a value, the value is asked for in a secret
      -- panel (bullets, no history) where the editor has one.
      local name, value = keys.parse(line)
      if not name or name == "" then
        local stored = keys.names()
        print("usage: /vault <name> <value>   (stored: " .. (#stored > 0 and table.concat(stored, ", ") or "none") .. ")")
      else
        if not value or value == "" then
          local panel = dofile('lua/core/cli_panel.lua')
          if view.editor and view.stdout and panel.available() then
            local answer = panel.open({ title = "Key " .. name, input = "secret",
              lines = { "Stored as " .. keys.path(name) .. " (0600). The agent uses it by name; its value is redacted everywhere." },
              placeholder = "value" })
            panel.close()
            value = type(answer) == "table" and answer.action == "submit" and answer.text or nil
          end
        end
        if not value or value == "" then
          print("usage: /vault " .. name .. " <value>")
        else
          local result = keys.set(name, value)
          value = nil
          if result.ok then
            print(string.format("  %s %s - %s (0600). Use it as \"$(cat %s)\"; its value is redacted in every output.",
              result.replaced and "replaced" or "stored", name, result.path, result.path))
          else
            print("  vault: " .. result.error .. (result.note and (" - " .. result.note) or ""))
          end
        end
      end
    elseif line == "/new" then
      -- The window's `/new`, in the REPL. The session being left is not closed: `M:close` finishes a
      -- session, and this thread is not finished, only left - `wa chat --session <id>` comes back to
      -- it, and `wa sessions` still lists it.
      local previous = agent.session_id
      local id, notice = commands.new_session({ previous = previous, user = USER, node = NODE })
      agent = agentlib.new(id, printer(view), "master", USER, NODE)
      agent.steer = function()
        if refresh_status then refresh_status() end
        local lines = input:take_steering()
        for _, text in ipairs(lines) do view:accepted(text) end
        return lines
      end
      print(redact.text(notice))
    elseif line == "/model" or line == "/reasoning" or line == "/thinking" then
      local panel = dofile('lua/core/cli_panel.lua')
      local panels = view.editor and view.stdout and panel.available()
      local picker = dofile('lua/core/model_cli.lua')
      local done, problem = pcall(line == "/model" and picker.model or picker.reasoning, {
        print = print,
        ask = function(text) view:prompt(text); while true do
          local answer, eof = input:poll(cli_input.WAIT_MS)
          if answer ~= nil then view:accepted(answer); view:submitted(); return answer end
          if eof then return nil end end end,
        panel = panels and panel.open or nil,
        paint = function(text, role) return cli_view.paint(text, role, view.live) end,
      })
      if panels then panel.close() end
      refresh_model()
      if not done then print(redact.text(tostring(problem))) end
    elseif line == "/login" or line == "/provider" then
      -- Credentials never pass through this REPL/editor, whose lines have recall history: a ChatGPT
      -- login is a device code entered in the browser, an API key is pasted on the vault page.
      local function ask(text)
        view:prompt(text)
        while true do
          local answer, eof = input:poll(cli_input.WAIT_MS)
          if answer ~= nil then
            view:accepted(answer)
            view:submitted()
            return answer
          end
          if eof then return nil end
        end
      end
      local manager = dofile('lua/core/provider_management.lua')
      local flow = line == "/login" and manager.login_cli or manager.provider_cli
      local panel = dofile('lua/core/cli_panel.lua')
      local panels = view.editor and view.stdout and panel.available()
      local done, problem = pcall(flow, {
        print = print,
        ask = ask,
        -- A panel over the bottom of the screen (Esc closes it); nil where there is no raw editor,
        -- and the flow falls back to numbered questions.
        panel = panels and panel.open or nil,
        paint = function(text, role) return cli_view.paint(text, role, view.live) end,
        wait = function(ms)
          local deadline = host.monotonic_ms() + ms
          while host.monotonic_ms() < deadline do
            local answer = input:poll(math.min(cli_input.WAIT_MS, deadline - host.monotonic_ms()))
            if answer ~= nil then view:submitted(); return answer end
          end
          return nil
        end,
      })
      if panels then panel.close() end
      refresh_model()
      if not done then print(redact.text(tostring(problem))) end
    elseif line == "/stats" then
      print(json.encode(memory.stats()))
    elseif line == "/console" then
      -- The console is the raw view of the same run: every event as it arrived, and a tool's
      -- output whole. It is a toggle rather than a flag on the launcher because the question
      -- ("what is it actually doing?") arrives in the middle of a run, not before it.
      local on = view:set_console(not view:console_on())
      print(on and "  console on: every event, and a tool's output unclipped"
        or "  console off: the formatted view")
    elseif line == "/orchestration" or line == "/ochestration" then
      local mode=dofile('lua/core/orchestration_mode.lua')
      local current=mode.read(agent.session_id)
      local result=mode.control({mode_action='toggle',revision=current.revision},{role='master',user_id=USER,session_id=agent.session_id})
      print(result.ok and ('orchestration '..(result.orchestration.enabled and 'on' or 'off')) or json.encode(result))
    elseif line == "/update" then
      -- The same report the window gets from POST /update, and the same sentence: this node cannot
      -- replace itself, so the answer is what it decided and what it queued for the sentinel.
      local report = updater.run({
        reason = "requested from the interactive chat",
        session_id = agent.session_id,
      })
      print(redact.text(report.message or json.encode(report)))
      if report.release and report.release.state == "behind" then
        print(redact.text("release: " .. report.release.message))
      end
      if report.next then print(redact.text("next: " .. report.next)) end
    elseif line == "/merge" then
      -- Not a node operation: the merge runs outside this process, in the worktrees. The command
      -- is the agent's brief, and it names the skill that holds the procedure.
      turn(merger.brief)
    elseif line == "/merge all" then
      turn(merger.all_brief)
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
    elseif line:match("^/[%w_-]+$") or line:match("^/[%w_-]+%s") then
      -- A slash word that is not a command (a typo like /hlep, or a command missing its argument) used to
      -- start a full agent run with tools. A path ("/home/x ...") has a second slash and still goes through.
      print("unknown or incomplete command " .. line:match("^(/[%w_-]+)") .. " - /help lists them")
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
