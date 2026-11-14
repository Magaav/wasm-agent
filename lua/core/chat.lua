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
--
-- Live reload (docs/HOTRELOAD.md). Every module of the UI and command layer is reached through
-- `reload.require`, which answers a stable proxy: an edit to one of them reaches this session at its next
-- frame or command, and nothing below has to know that happened. The modules this file keeps as plain
-- `dofile`s are the core - the agent, memory, the provider, the ledger, the (guarded) hooks engine and the
-- input reader - which own the session and the in-flight run and are deliberately not reloadable.
local reload = dofile("lua/core/reload.lua")
local cli_view = reload.require("lua/core/cli_view.lua")
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
local status = reload.require("lua/core/status.lua")
-- `/hooks` and the operator's own `/` commands and footer segments (docs/HOOKS.md, docs/MODS.md).
local hooks = dofile("lua/core/hooks.lua")

local M = {}

-- The CLI runs as one user on one node; sessions are keyed by both, so the same
-- machine can keep separate threads per user.
local USER, NODE = "master", ""

-- The commands, their help and the flags that select a session are one registry
-- (`lua/core/commands.lua`), so the list a reader is shown and the arms below cannot drift apart, and
-- `scripts/test-command-parity.cjs` can fail when this REPL is missing a command the window offers.
local commands = reload.require("lua/core/commands.lua")

-- The help is asked for when it is drawn, not once at start: `/help` is part of the reloadable command
-- layer, so a row added to `commands.lua` while a chat is running is in the next `/help` printed.
local function help() return commands.help() end

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

-- The update notice at start, and where it lands: the session-status-content line, ONE row above the
-- session status bar, and NOWHERE else (#106).
--
-- Reported twice by the operator (09/11, and again 11/11: "at CLI start ... 'Update available (...)'
-- also lands in the transcript under the welcome block"). The earlier fix moved the notice into that
-- row and then still printed it, so the reader got the same sentence twice: once in the footer, where
-- it belongs, and once in the transcript above the first prompt, where it became part of the chat and
-- scrolled away with it. A transcript line also looks like something the *agent* said, which is the
-- real cost: the notice is the node's, not the conversation's.
--
-- So this returns the line it put in the footer and prints nothing. It is one function instead of an
-- inline block for one reason: `wa chat` cannot be driven to its start in a test (it opens memory, a
-- provider, a binding and a terminal first), and the operator's finding has to be pinned by a test that
-- goes red when a `print` comes back. `scripts/test-cli-notice.lua` is that test - it calls this with a
-- live view and a stubbed host and asserts the transcript receives nothing, and it also starts a real
-- `wa chat` behind it to check the same thing from outside the process.
--
-- `options.banner`, `options.seen` and `options.released` are the seams the test uses; on a real start
-- the banner is read once here, from the same module the footer's session line delegates to.
local function start_notice(view, options)
  local o = options or {}
  if not o.forced and host.getenv("WA_SKIP_UPDATE_CHECK") then return nil end
  local banner = o.banner or dofile("lua/core/update_banner.lua")
  local seen = o.seen or banner.check({ refresh = true })
  local line = seen and seen.line or nil
  if not line and seen and seen.state == "unknown" and seen.reason ~= "checks_disabled" then
    -- The second check, unchanged in what it decides: an install that records a version tag rather
    -- than a published binary release (`release.lua`) still gets told. It used to print; it is the same
    -- one line in the same one row now, because a notice that is worth showing is worth showing once.
    local release_module = dofile("lua/core/release.lua")
    local released = o.released or release_module.check({
      installed = release_module.installed(updater.installed_record()),
    })
    if released and released.state == "behind" then
      line = "update available: " .. (released.message or "a newer release is published") .. " - /update installs it"
    end
  end
  if type(line) ~= "string" or line == "" then return nil end
  -- The row's own text, and the draw that puts it there. `session_notice` is what
  -- `METHODS:session_content` falls back to when no rebuild is claiming the row.
  view.session_notice = redact.text(line)
  if view.session_draw then view:session_draw() end
  return view.session_notice
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
  local session_id, resume_last, prompt, once = nil, false, {}, false
  local dev = nil
  local index = 2
  while argv[index] do
    local arg = argv[index]
    if arg == "--session" or arg == "--resume" then
      session_id = argv[index + 1] or ""
      index = index + 2
    elseif arg == "--continue" or arg == "-c" then
      resume_last = true
      index = index + 1
    elseif arg == "--dev" then
      -- `wa chat --dev <dir>`: reload the UI and command layer from that working tree (docs/HOTRELOAD.md).
      -- `<dir>` is the directory that CONTAINS `lua/` - a checkout's root - and the status bar says
      -- `dev reload` for as long as it is in use, because a CLI running code that is not what it was
      -- installed with has to say so.
      dev = argv[index + 1] or ""
      index = index + 2
    elseif arg == "--once" or arg == "-p" or arg == "--print" then
      -- The explicit form of what a non-terminal stdin already means: run the turn(s), let go of the
      -- session and exit with the run's status. `-p` is the same letter `pi -p` uses.
      once = true
      index = index + 1
    elseif arg == "--help" or arg == "-h" then
      print(help())
      return 0
    else
      prompt[#prompt + 1] = arg
      index = index + 1
    end
  end
  prompt = table.concat(prompt, " ")

  -- The reload source, named BEFORE the first module of the UI layer is read: `--dev` first (a person at a
  -- keyboard means it), then `WASM_AGENT_HOTRELOAD_DEV`, then - with no flag at all - the payload this node
  -- was deployed with, which is what makes a deploy of UI-only changes reach a session that is already
  -- running (docs/HOTRELOAD.md).
  local requested_dev = (type(dev) == "string" and dev ~= "") and dev or nil
  if not requested_dev then
    local from_env = host.getenv("WASM_AGENT_HOTRELOAD_DEV")
    if type(from_env) == "string" and from_env ~= "" then requested_dev = from_env end
  end
  if requested_dev then
    local kind_ok, kind = pcall(host.path_kind, requested_dev)
    if not kind_ok or kind ~= "dir" then
      print("--dev needs a directory (the one that contains lua/): " .. tostring(requested_dev))
      return 2
    end
    reload.configure({ dev = requested_dev })
  end

  -- SCRIPTED, OR INTERACTIVE. `wa chat "<prompt>"` launched from a script, a scheduled task or an
  -- orchestrator has no terminal on its stdin, and until now it ran its turn and then sat at the
  -- prompt for ever, holding the session: measured 2026-11-11, orchestrators killed `wa` five or more
  -- times in one night and the sessions stayed on `resource_busy` after each kill because nothing
  -- released them in an orderly way. So the mode is decided from the one fact that describes it -
  -- `host.isatty("stdin")` - and an explicit `--once`/`-p` says the same thing for a caller piping a
  -- prompt into a terminal.
  --
  -- A reader at a terminal gets exactly what they had. A scripted caller gets: the turn(s) run, the
  -- session's claim released (each run releases its own, `lua/core/agent.lua`), the process exits with
  -- the run's status, and stdin is never waited on when a prompt came from the command line. A binary
  -- that cannot answer `host.isatty` (an older one) is treated as interactive: this must not change
  -- what an unknown binary does.
  local function stdin_is_a_terminal()
    if type(host) ~= "table" or type(host.isatty) ~= "function" then return nil end
    local ok, value = pcall(host.isatty, "stdin")
    if not ok then return nil end
    return value and true or false
  end
  local scripted = once or stdin_is_a_terminal() == false

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
  -- A scripted run has no reader: the plain view (no frame, no status line, no escape sequences), so its
  -- stdout is the transcript and not a screen. `nil` means "decide from the terminal", which is what an
  -- interactive run keeps.
  local view_live = nil
  if scripted then view_live = false end
  local view = cli_view.new({
    -- A scripted run has no reader: the plain view, whatever the terminal looks like.
    live = view_live,
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
    -- The session whose wakes the footer counts (docs/SELF-LOOP.md).
    session_id = session.id,
  })
  -- Commands must use the view's scroll region, not Lua's global print at the
  -- hardware cursor (which now belongs to the native editor). The view writer is
  -- serialized with the input thread and the ticker by host.terminal_write.
  local function print(text) view:line(text or "") end
  -- Live reload between two commands (docs/HOTRELOAD.md). The view ticks the watcher at every frame it
  -- begins, which is what covers a streaming run - the interpreter runs event by event while a stream is
  -- arriving - and this is the other boundary: before a command reads `commands`, a balloon builder or any
  -- other member of the UI layer, so the command a reader types is the tree's newest one.
  local function hot()
    local notices = reload.tick(host.now())
    for _, notice in ipairs(notices) do
      view:line(cli_view.paint("  " .. tostring(notice.text), notice.ok and "dim" or "warning", view.live))
    end
  end
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
  local input = cli_input.new({
    -- A scripted run reads no stdin of its own. The host's reader thread would sit on a stream nobody
    -- is going to close - which is precisely the leak this mode removes - and the REPL never polls it.
    read = not scripted,
    editor = view.live and view.stdout and height and height >= 7
      and host.getenv("WASM_AGENT_CLI_FRAME") ~= "off" })
  view.editor = input.editor
  -- The reader's input is session state: the store holds the object, so a reload of the module that made
  -- it cannot lose a line typed while the run was working (docs/HOTRELOAD.md).
  reload.store.input = input
  -- The slash menu: typing `/` lists these under the box, the way Claude Code does.
  if input.editor and host.input_commands then pcall(host.input_commands, json.encode(commands.menu())) end
  -- Set once the view is up (below): the `/status` snapshot refreshed at every round of a run.
  local refresh_status
  -- The local views the client can draw while this interpreter is blocked
  -- (`lua/core/local_views.lua`, docs/HOST.md), declared here because `agent.steer` below - the round
  -- boundary - is where they are refreshed.
  local local_views = reload.require("lua/core/local_views.lua")
  local views_reported = false
  -- Publish the views that are missing or older than `opts.max_age`. Never blocks on the network
  -- itself (`local_views.refresh`) and never waits for anything: it either hands the client a spec or
  -- reports, once, that it could not.
  local function publish_views(opts)
    -- A panel needs the raw editor, the same condition `/status`'s snapshot has.
    if not (view.editor and view.stdout) then return 0 end
    local count, problem = local_views.refresh(opts)
    if problem and not views_reported then
      views_reported = true
      -- Once, not once per round: a snapshot that never lands is a fact, and a fact repeated every
      -- round is noise on a screen the reader is trying to read.
      view:warn(redact.text("  local views: " .. tostring(problem) .. " (reported once)"))
    end
    return count
  end
  agent.steer = function()
    if refresh_status then refresh_status() end
    -- The round boundary: the model's call has returned, so this is a frame in the middle of a run - the
    -- second place a reload takes effect without interrupting the turn (docs/HOTRELOAD.md).
    hot()
    -- The round boundary: the only other moment at which this side runs during a run. `cached` keeps
    -- the rendezvous out of the turn's critical path - a snapshot is allowed to be a minute old and to
    -- say so, and is not allowed to make the model wait.
    publish_views({ max_age = local_views.MAX_AGE, cached = true, session_id = agent.session_id, ctx = { user_id = USER, role = "master", session_id = agent.session_id } })
    local lines = input:take_steering()
    for _, line in ipairs(lines) do view:accepted(line) end
    return lines
  end

  -- The screen first, so the welcome block is output like any other and sits right above the input.
  -- A scripted run has neither: its stdout is a transcript a program reads, and a banner (version,
  -- workspace, branch, database path, the session id and the model) in the middle of it is noise that
  -- would also make `$(wa chat --once ...)` unusable. The session id is said on stderr instead, below.
  if not scripted then
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
    -- The reload source, said on the line under the banner as well as on the status bar: a reader who is
    -- about to edit a command file needs to know that this session will pick the edit up, and from where.
    if reload.status() then
      print(cli_view.paint("  \194\183 " .. reload.status() .. ": the UI and commands come from "
        .. tostring(reload.root()), "warning", view.live))
    end
  end

  -- Continuing a thread is the resume (operator, 13/11: "interrupting a session should be in sync with
  -- the schedule, once interrupted, it stops, once it resumes, it resumes"). `--continue`, `--resume
  -- <id>` and `--session <id>` all open a thread the reader is coming back to, so a schedule an
  -- interrupt held runs again from here; the wakes themselves were never touched, so an overdue one
  -- fires once at its next claim. A reader who closes this without continuing leaves them held, and the
  -- footer says `2 wakes paused`.
  if resume_last or session_id then
    local resumed_ok, resumed = pcall(function()
      return dofile("lua/core/selfloop.lua").resume(agent.session_id)
    end)
    if resumed_ok and type(resumed) == "table" and resumed.resumed then
      if not scripted then
        print(cli_view.paint("  \226\143\176 wakes resumed: " .. tostring(resumed.pending or 0)
          .. ((tonumber(resumed.overdue) or 0) > 0 and " (the overdue one fires once)" or ""), "dim", view.live))
      end
    end
  end

  -- A continued thread (`--continue`, `--resume <id>`) is drawn again under the banner, so the reader
  -- picks up where the window was closed instead of in front of an empty screen. The newest messages
  -- only: a day-long thread is hundreds of rows, and the window or `wa conversation` has the rest.
  -- A scripted run draws nothing: replaying 400 rows into a log is not the answer the caller asked for.
  if not scripted and (resume_last or session_id) then
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

  -- The model's own wakes (docs/SELF-LOOP.md). A node fires them from its placement tick; an
  -- interactive CLI has no served scheduler, so it claims a due wake between waits and runs the turn
  -- in this same session and view. The claim is a compare-and-set, so a CLI beside a node never runs
  -- the same wake twice. Assigned after `mark_seen` exists; `turn` only calls it when it is set.
  local wake_if_due

  local function turn(line)
    snapshot_status({ color = view.live, max_age = 300 })
    -- Nothing is blocked yet: a live read of the roster is exactly what a `/nodes` typed in a moment
    -- will be drawn from, and the reader is not waiting on anything but this turn.
    publish_views({ max_age = local_views.MAX_AGE, session_id = agent.session_id, ctx = { user_id = USER, role = "master", session_id = agent.session_id } })
    view:run_started()
    local ok, reply = pcall(agent.run, agent, line)
    if not ok then
      view:failed(redact.text(tostring(reply)))
    else
      -- The view prints the reply when nothing streamed (an error before the first
      -- token, or a provider without streaming), so the turn is never silent.
      view:answered(reply)
    end
    if wake_if_due then wake_if_due() end
    -- The turn's status, for the caller that exits with it (`wa chat --once`, or any scripted run).
    return ok
  end

  local ran_ok = true
  if prompt ~= "" then
    -- A scripted run has no reader, so there is nothing to prompt: the prompt is a row of a screen the
    -- caller does not have (in plain output it would prefix the transcript with `> `).
    if not scripted then view:prompt() end
    ran_ok = turn(prompt)
  end

  -- 29/10: a continued thread whose last run stopped without an answer (the CLI was killed mid-run, or
  -- the provider cut the stream past its retries) is re-driven now, from the recorded state, instead
  -- of waiting for the reader to notice and type. One attempt per interruption; the host's session
  -- claim refuses it while another live process still owns the thread (lua/core/run_recovery.lua).
  if prompt == "" and (resume_last or session_id) then
    local found, recovery = pcall(function() return dofile("lua/core/run_recovery.lua").due(agent.session_id) end)
    if found and recovery then
      print(cli_view.paint("  \226\134\187 resuming the interrupted run: " .. redact.text(recovery.reason), "dim", view.live))
      if not scripted then view:prompt() end
      ran_ok = turn(recovery.prompt)
    end
  end

  -- SCRIPTED: run the turn(s), let go of the session, exit with the run's status.
  --
  -- Measured 2026-11-11: an orchestrator ran `wa chat "<prompt>" > log` five times in one night and had
  -- to kill the process five times, because after the turn the REPL sat at its prompt on a stdin that
  -- was not a terminal; the sessions were left claimed until each kill. The exit below is the orderly
  -- version of that kill: `agent:close()` releases the session presence and ends the thread exactly as
  -- `/exit` does, and the process returns the last turn's status (0 answered, 1 failed) so a script can
  -- act on it.
  --
  -- Lines still waiting on stdin become turns, but only when nothing was given on the command line: a
  -- caller that passed its prompt as an argument is never made to wait on a stream it may not close.
  if scripted then
    if prompt == "" then
      while true do
        local line = io.read("*l")
        if line == nil then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
          -- What was asked, in the transcript: a scripted run's log is read by a person later, and a
          -- reply with no question in front of it is a log nobody can check.
          print(cli_view.paint("> " .. line, "dim", view.live))
          ran_ok = turn(line)
        end
      end
    end
    -- The session id goes to stderr, so stdout stays the run's own output for a caller capturing it,
    -- and the id is still there to resume the thread or steer a later run of it.
    io.stderr:write(string.format("wa: session %s %s\n", tostring(agent.session_id),
      ran_ok and "ok" or "failed"))
    agent:close()
    input:stop()
    view:screen_off()
    return ran_ok and 0 or 1
  end

  -- The input, and where the prompt is drawn. Both matter to the same thing: a reader who can see
  -- where they are typing, and who is not locked out while the agent works. The prompt is drawn
  -- once per wait rather than in a loop, because the prompt and the reader's typing share a row -
  -- a redraw on a timeout would erase what they have typed so far.
  -- Restart between runs, never over anything the reader is doing; a refusal is said once.
  local restart_checked, restart_refused = 0, nil
  -- The reason a restart is due but has not happened yet: while it is set, the session-status-content
  -- line says `updating…` (lua/core/cli_restart.lua), because a reader whose build was replaced should
  -- see that the CLI is on its way into the new one instead of wondering why the old one keeps answering.
  local restart_pending = nil
  local function restart(reason)
    local message, torn = cli_restart.restart(agent.session_id, reason, function()
      print("  restarting: " .. reason .. " - session " .. agent.session_id .. " continues")
      input:stop()
      view:screen_off()
    end)
    if torn then io.write(redact.text(message) .. "\n"); os.exit(1) end
    -- The restart did not happen (refused or failed): the line goes back to what it was, because
    -- "updating…" would then be a claim about a restart that is not coming.
    restart_pending = nil
    view:session_draw()
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
    if reason and settled and cli_restart.idle() then
      restart_pending = reason
      view:session_draw()
      restart(reason)
    end
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

  local selfloop = dofile("lua/core/selfloop.lua")
  local function wake_turn(row)
    local content, trace = selfloop.turn_content(row)
    snapshot_status({ color = view.live, max_age = 300 })
    view:run_started()
    agent.self_wake = trace
    local ok, reply = pcall(agent.run, agent, content)
    agent.self_wake = nil
    -- Two things, and they are different halves of the same interrupt: what the READER sees (one line,
    -- naming the wake, `lua/core/cli_view.lua`'s `failed`) and what happens to the SCHEDULE (the wake
    -- settles `cancelled` and is never re-armed - settling it as a failure would re-arm a repeating wake
    -- for its cadence, under a cancel flag the CLI keeps set until the next submitted line: one failed
    -- turn and one error line per interval, 13/11). The line is a cancel, not a failure; the row is not.
    if not ok then view:failed(redact.text(tostring(reply)), { self_wake = true }) else view:answered(reply) end
    if not ok and selfloop.cancelled_stop(reply) then selfloop.settle_interrupted(row)
    else selfloop.finish(row, ok, reply) end
    mark_seen()
  end
  wake_if_due = function()
    local row = selfloop.claim_due(agent.session_id, agent.user or USER)
    if not row then return false end
    print(cli_view.paint("  \226\143\176 self-wake: " .. redact.text(tostring(row.reason or "")), "dim", view.live))
    wake_turn(row)
    return true
  end

  local function read_line()
    view:prompt()
    while true do
      restart_if_due()
      catch_up()
      -- A due self-wake is a turn this session promised itself; run it now rather than at the next
      -- line the reader types. A wake that brings no line redraws the prompt after its own turn.
      if wake_if_due() then view:prompt() end
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
  --
  -- Two checks, one line. `update_banner.lua` compares the installed *commit* with the newest
  -- `node-<sha12>` release and prints `Update available (<sha>): run wa update or /update` - the
  -- sentence the footer and the window show. When it cannot decide (a release-bundle install records
  -- a version tag, not a published binary release), `release.lua`'s tag feed answers exactly as it did
  -- before; only one of them ever prints, so the reader is told one fact in one wording.
  -- The session-status-content line has two producers and one row, so it is resolved here in one place:
  -- a pending restart (`updating…`) wins - it is the thing happening right now - and the update notice is
  -- the standing text underneath it. `update_banner.session_content` still owns the build/failure
  -- precedence inside the notice's own half, which is why this delegates rather than re-deciding.
  local banner, seen = nil, nil
  view.session_status = function()
    local updating = cli_restart.line(restart_pending)
    if updating then return updating end
    if banner then return banner.session_content({ notice = seen and seen.line }) end
    return nil
  end
  if not scripted and not host.getenv("WA_SKIP_UPDATE_CHECK") then
    banner = dofile("lua/core/update_banner.lua")
    seen = banner.check({ refresh = true })
    -- No print: the notice is the session-status-content row's line (`start_notice`, #106). What the
    -- line says is still `update_banner.session_content`'s decision through `view.session_status`, because
    -- a rebuild in flight REPLACES the notice on the same row and hands it back afterwards.
    start_notice(view, { banner = banner, seen = seen })
  end

  -- The one overlay every command below draws in (`lua/core/balloon.lua`). `ui.say` is a line of
  -- acknowledgement through the transcript writer (redacted, as every command's output has been);
  -- `ui.show` is the balloon - pages, arrow keys, Enter, Esc - and a pipe gets the same pages as text
  -- from the same renderer. No arm below calls `print`, `host.panel` or `io.write` itself, and
  -- `scripts/test-cli-balloon.lua` fails when one does.
  local balloon = reload.require("lua/core/balloon.lua")
  local ui = balloon.for_view(view, { print = print, redact = redact })

  while true do
    -- Whatever the last command wrote (a turn, a `!` line, /new) is this CLI's own: already shown.
    mark_seen()
    -- A save lands here as well as on the next frame: a reload source that only reaches the screen during
    -- a run would miss the idle prompt, which is exactly where a reader is when they edit a command.
    hot()
    local line = read_line()
    if line == nil then break end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
      -- keep prompting
    elseif line == "/exit" or line == "/quit" then
      break
    elseif line == "/help" then
      -- The same help text, in the balloon: a screen at a time, arrow keys and Enter, Esc closes. The
      -- rows are not re-wrapped (`nowrap`): they are columns, and a hint that moved to its own line
      -- would stop being one.
      local rows = {}
      for row in (help() .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = row end
      ui.show(balloon.paged("Help", rows, { per = 14, nowrap = true }))
    elseif line == "/bind" or line:sub(1, 6) == "/bind " then
      reload.require('lua/core/binding_cli.lua').run('bind',line:sub(7),read_line,ui.print)
    elseif line == "/unbind" then
      reload.require('lua/core/binding_cli.lua').run('unbind','',read_line,ui.print)
    elseif line == "/nodes" then
      -- The cluster as pages to move through (lua/core/nodes_cli.lua builds them; the walk is the
      -- balloon's). `/nodes pending` stays a binding command.
      local done, problem = pcall(reload.require('lua/core/nodes_cli.lua').run, {
        print = ui.print, show = ui.show,
        paint = function(text, role) return cli_view.paint(text, role, view.live) end,
      })
      if not done then ui.say(redact.text(tostring(problem))) end
    elseif line:sub(1, 7) == "/nodes " then
      reload.require('lua/core/binding_cli.lua').run('nodes',line:sub(8),read_line,ui.print)
    elseif line == "/accept" or line:sub(1, 8) == "/accept " then
      reload.require('lua/core/binding_cli.lua').run('accept',line:sub(9),read_line,ui.print)
    elseif line == "/promote" or line:sub(1, 9) == "/promote " then
      reload.require('lua/core/binding_cli.lua').run('promote',line:sub(10),read_line,ui.print)
    elseif line == "/demote" or line:sub(1, 8) == "/demote " then
      reload.require('lua/core/binding_cli.lua').run('demote',line:sub(9),read_line,ui.print)
    elseif line == "/revoke" or line:sub(1, 8) == "/revoke " then
      reload.require('lua/core/binding_cli.lua').run('revoke',line:sub(9),read_line,ui.print)
    elseif line == "/session" then
      ui.say(agent.session_id)
    elseif line == "/wakes" or line == "/wake" or line:sub(1, 6) == "/wake " then
      -- The model's own schedule (docs/SELF-LOOP.md), as a balloon: one row per wake, and a cancel is
      -- still `/wake cancel <id>`.
      local ctx = { user_id = USER, role = "master", session_id = agent.session_id }
      local arg = line == "/wakes" and "" or line:sub(6):gsub("^%s+", "")
      if arg ~= "" then
        local verb, id = arg:match("^(%S+)%s+(%S+)$")
        if verb ~= "cancel" or not id then
          ui.say("usage: /wake cancel <id>")
        else
          local result = selfloop.cancel({ id = id }, ctx)
          ui.say(result.ok and ("  cancelled " .. id) or ("  " .. tostring(result.error or "not cancelled")))
        end
      else
        local listed = selfloop.list({}, ctx)
        if listed.error then
          ui.say("  " .. tostring(listed.error))
        elseif listed.count == 0 then
          ui.say("  no pending wakes")
        else
          local rows = {}
          for _, wake in ipairs(listed.wakes) do
            local when = wake.due_at and os.date("%Y-%m-%d %H:%M", math.floor(wake.due_at))
              or ("on " .. table.concat(wake.on, ", "))
            rows[#rows + 1] = string.format("%s  %s  %s%s%s", wake.id, wake.status, when,
              wake.every_seconds and (" every " .. wake.every_seconds .. "s") or "",
              wake.last_error ~= "" and ("  ! " .. wake.last_error) or "")
          end
          ui.show(balloon.paged("Wakes", rows, { per = 14, nowrap = true }))
        end
      end
    elseif line == "/status" then
      -- A balloon, like every other view. During a run the host shows it by itself from the snapshot
      -- (`status_snapshot` above); this arm is the one between runs, from the same lines.
      local rows = {}
      for _, row in ipairs(status.session_lines(agent.session_id, { color = view.live })) do
        rows[#rows + 1] = redact.text(row)
      end
      ui.show(balloon.paged("Status", rows, { per = 14, nowrap = true }))
    elseif line == "/restart" then
      restart_refused = nil
      restart("restart requested from the chat")
    elseif line:sub(1, 1) == "!" then
      -- Bash mode: run here, show it, record it as context; no model turn (lua/core/bash_mode.lua).
      local command = bash_mode.command(line)
      if not command then ui.say("  ! needs a command, e.g. !git status")
      else
        local done, problem = pcall(bash_mode.run, command, { session_id = agent.session_id, cwd = platform.cwd(), view = view })
        if not done then ui.say(redact.text("  ! failed: " .. tostring(problem))) end
      end
    elseif line == "/vault" or line:sub(1, 7) == "/vault " then
      -- Handled here and nowhere else: the line never reaches `turn`, so the value never reaches a
      -- model, a transcript row or the ledger. Without a value, the value is asked for in a secret page
      -- (bullets, no history) of the same balloon every other command uses.
      local name, value = keys.parse(line)
      if not name or name == "" then
        local stored = keys.names()
        ui.say("usage: /vault <name> <value>   (stored: " .. (#stored > 0 and table.concat(stored, ", ") or "none") .. ")")
      else
        if not value or value == "" then
          value = ui.ask(balloon.page({ title = "Key " .. name, input = "secret",
            lines = { "Stored as " .. keys.path(name) .. " (0600). The agent uses it by name; its value is redacted everywhere." },
            placeholder = "value" }))
        end
        if not value or value == "" then
          ui.say("usage: /vault " .. name .. " <value>")
        else
          local result = keys.set(name, value)
          value = nil
          if result.ok then
            ui.say(string.format("  %s %s - %s (0600). Use it as \"$(cat %s)\"; its value is redacted in every output.",
              result.replaced and "replaced" or "stored", name, result.path, result.path))
          else
            ui.say("  vault: " .. result.error .. (result.note and (" - " .. result.note) or ""))
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
        publish_views({ max_age = local_views.MAX_AGE, cached = true, session_id = agent.session_id, ctx = { user_id = USER, role = "master", session_id = agent.session_id } })
        local lines = input:take_steering()
        for _, text in ipairs(lines) do view:accepted(text) end
        return lines
      end
      ui.say(redact.text(notice))
    elseif line == "/model" or line == "/reasoning" or line == "/thinking" then
      local picker = reload.require('lua/core/model_cli.lua')
      local done, problem = pcall(line == "/model" and picker.model or picker.reasoning, {
        print = ui.print, show = ui.show,
        paint = function(text, role) return cli_view.paint(text, role, view.live) end,
      })
      refresh_model()
      if not done then ui.say(redact.text(tostring(problem))) end
    elseif line == "/login" or line == "/provider" then
      -- Credentials never pass through this REPL/editor, whose lines have recall history: a ChatGPT
      -- login is a device code entered in the browser, an API key is pasted in the balloon's secret
      -- field or on the vault page.
      local manager = reload.require('lua/core/provider_management.lua')
      local flow = line == "/login" and manager.login_cli or manager.provider_cli
      local done, problem = pcall(flow, {
        print = ui.print, show = ui.show,
        paint = function(text, role) return cli_view.paint(text, role, view.live) end,
      })
      refresh_model()
      if not done then ui.say(redact.text(tostring(problem))) end
    elseif line == "/stats" then
      local stats = memory.stats()
      local rows = {}
      for _, key in ipairs({ "sessions", "messages", "memories", "turns" }) do
        if stats[key] ~= nil then rows[#rows + 1] = string.format("%-10s %s", key, tostring(stats[key])) end
      end
      for key, value in pairs(stats) do
        if type(value) ~= "table" then rows[#rows + 1] = string.format("%-10s %s", tostring(key), tostring(value)) end
      end
      ui.show(balloon.paged("Database", rows, { per = 14, nowrap = true }))
    elseif line == "/console" then
      -- The console is the raw view of the same run: every event as it arrived, and a tool's
      -- output whole. It is a toggle rather than a flag on the launcher because the question
      -- ("what is it actually doing?") arrives in the middle of a run, not before it.
      local on = view:set_console(not view:console_on())
      ui.say(on and "  console on: every event, and a tool's output unclipped"
        or "  console off: the formatted view")
    elseif line == "/orchestration" or line == "/ochestration" then
      local mode=dofile('lua/core/orchestration_mode.lua')
      local current=mode.read(agent.session_id)
      local result=mode.control({mode_action='toggle',revision=current.revision},{role='master',user_id=USER,session_id=agent.session_id})
      ui.say(result.ok and ('orchestration '..(result.orchestration.enabled and 'on' or 'off')) or json.encode(result))
    elseif line == "/update" then
      -- The same report the window gets from POST /update, and the same sentence: this node cannot
      -- replace itself, so the answer is what it decided and what it queued for the sentinel.
      local report = updater.run({
        reason = "requested from the interactive chat",
        session_id = agent.session_id,
      })
      ui.say(redact.text(report.message or json.encode(report)))
      if report.release and report.release.state == "behind" then
        ui.say(redact.text("release: " .. report.release.message))
      end
      if report.next then ui.say(redact.text("next: " .. report.next)) end
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
      local rows = {}
      for row in tostring(redact.text(text) .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = row end
      ui.show(balloon.paged("Efficiency", rows, { per = 14, nowrap = true }))
    elseif line == "/memories" then
      local rows = {}
      for _, row in ipairs(memory.memories(nil, 50)) do rows[#rows + 1] = memory_line(row) end
      if #rows == 0 then rows[1] = "(empty)" end
      ui.show(balloon.paged("Memories", rows, { per = 12 }))
    elseif line:sub(1, 10) == "/remember " then
      ui.say((memory.remember(line:sub(11))))
    elseif line:sub(1, 8) == "/recall " then
      local rows = {}
      for _, row in ipairs(memory.recall(line:sub(9), 10)) do rows[#rows + 1] = memory_line(row) end
      if #rows == 0 then rows[1] = "(empty)" end
      ui.show(balloon.paged("Recall", rows, { per = 12 }))
    elseif line == "/hooks" or line:sub(1, 7) == "/hooks " then
      -- What is configured and what happened last (docs/HOOKS.md). A read: no hook runs for it, and
      -- no payload, prompt or hook output is printed - names, events, timeouts and outcomes only.
      local arg = line:sub(7):gsub("^%s+", "")
      if arg == "reload" then
        hooks.reset()
        ui.say("  hooks: configuration reread, footer segment cache cleared")
      elseif arg ~= "" and arg ~= "list" then
        ui.say("usage: /hooks [reload]")
      end
      local rows = {}
      for row in tostring(hooks.report({ session_id = agent.session_id, cwd = platform.cwd() }) .. "\n"):gmatch("([^\n]*)\n") do
        rows[#rows + 1] = row
      end
      ui.show(balloon.paged("Hooks", rows, { per = 14, nowrap = true }))
    elseif line == "/approve" or line:sub(1, 9) == "/approve " then
      -- The operator's gate on outgoing WhatsApp drafts (docs/APPROVE.md): the switch, the queue of
      -- drafts, and the balloon Enter / e / r decide in. Every answer here comes from the node that
      -- HOLDS THE ACCOUNT - the one whose `whatsapp_send` reads the policy - so this arm only asks and
      -- draws; it never changes a policy or a draft of its own.
      --
      -- The command is reloadable (docs/HOTRELOAD.md): `lua/core/approve.lua` is in `reload.UI`, so an
      -- edit to it reaches a running session through `reload.require` above. The GATE is not, and
      -- cannot be: it is the compiled `whatsapp_approve.rs` on the node that holds the account, which a
      -- reload source cannot supply - and a gate that could be swapped at runtime is not a gate.
      local done, problem = pcall(reload.require("lua/core/approve.lua").run, line, ui, {
        user_id = USER, role = "master", session_id = agent.session_id,
      })
      if not done then ui.say(redact.text(tostring(problem))) end
    elseif line == "/reload" then
      -- Live reload, stated (docs/HOTRELOAD.md): which tree the UI comes from, whether a deployed payload
      -- verified, what has been swapped and what failed. The mechanism is invisible by design, so "is it
      -- on, and is it reading the tree I am editing?" has to be a command and not an inference from a
      -- screen that changed on its own.
      ui.show(balloon.paged("Reload", reload.report(), { per = 14, nowrap = true }))
    elseif line == "/mcp" or line:sub(1, 5) == "/mcp " then
      -- Every connector this node can use - its own registry and each peer's - as one balloon
      -- (lua/core/mcp_command.lua builds the pages, lua/core/mcp_cli.lua drives them). A change goes
      -- through mcp.control here or the peer's own registry through the fabric; a running session is
      -- told by the existing [session update] note.
      local done, problem = pcall(reload.require("lua/core/mcp_cli.lua").run, line:sub(5), {
        print = ui.print, io = ui,
        ctx = { user_id = USER, role = "master", session_id = agent.session_id },
      })
      if not done then ui.say(redact.text(tostring(problem))) end
    elseif line:match("^/[%w_-]+$") or line:match("^/[%w_-]+%s") then
      -- A slash word that is not a built-in command: the operator's own command (docs/MODS.md), run
      -- with the payload on stdin, and shown in the balloon. Unknown words stay a refusal rather than a
      -- model turn: a typo like /hlep used to start a full agent run with tools.
      local name, rest = line:match("^(/[%w_-]+)%s*(.*)$")
      local ran = hooks.run_command(name, rest, { session_id = agent.session_id, cwd = platform.cwd() })
      if ran.ok then
        if ran.output ~= "" then
          local rows = {}
          for row in (ran.output .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = row end
          ui.show(balloon.paged(name, rows, { per = 14, nowrap = true }))
        end
      else
        ui.say("unknown or incomplete command " .. name .. " - /help lists them")
        if ran.error ~= "unknown_hook_command" then
          ui.say(redact.text("  " .. tostring(ran.error) .. (ran.detail and (": " .. tostring(ran.detail)) or "")))
        end
      end
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

-- The seam `scripts/test-cli-notice.lua` drives: "start a chat with an update available" without
-- memory, a provider, a binding or a terminal (#106).
M.start_notice = start_notice

return M
