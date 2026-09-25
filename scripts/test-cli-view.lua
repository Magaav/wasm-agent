-- The live view `wa chat` prints.
--
-- What is asserted here is the *rendering decision*, which is the part that can be
-- wrong without a model: which line a tool call becomes, whether a failed call looks
-- failed, whether a captured (non-terminal) transcript is free of escape sequences,
-- and whether the numbers in the footer are the run's own.
--
-- No model is involved and no database is needed: the view is handed the same events
-- the agent emits, with a clock the test controls.
local view_lib = dofile("lua/core/cli_view.lua")
local json = dofile("lua/vendor/json.lua")

local failed = 0
local checks = 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    print("FAIL " .. label)
    failed = failed + 1
  end
end

local function has(text, needle)
  return tostring(text):find(needle, 1, true) ~= nil
end

-- The visible text of a rendered line, with colour removed. The layout assertions are about
-- what the reader sees, so they must not break when a role is recoloured - which is exactly
-- what happened when this view moved from six literal colours to pi's roles. The colour
-- assertions below name the role instead of the escape, so they still say which colour.
local function visible(text)
  return (tostring(text):gsub("\27%[[%d;]*m", ""):gsub("\27%]2;[^\7]*\7", ""))
end

-- ---- what a call is ------------------------------------------------------------

ok(view_lib.phase("") == "Thinking", "a model call is 'Thinking'")
ok(view_lib.phase("bash") == "Running bash", "bash reads as running, not as a name")
ok(view_lib.phase("read") == "Reading read" or view_lib.phase("read") == "Reading read",
  "a known tool uses its verb")
ok(view_lib.phase("some_plugin") == "Working: some_plugin", "an unknown tool is still named")

ok(has(view_lib.call_line("bash", { command = "echo hi" }), "$ echo hi"),
  "a command call shows the command, not the JSON")
ok(has(view_lib.call_line("read", { path = "ui/app.js", offset = 10, limit = 20 }), "lines 10-29"),
  "a read shows its line range")
ok(has(view_lib.call_line("grep", { pattern = "host.exec", path = "lua" }), "/host.exec/ in lua"),
  "a search shows pattern and scope")
ok(has(view_lib.call_line("ls", {}), "."), "an empty path lists the working directory")
ok(has(view_lib.call_line("plugin_tool", { alpha = "one", beta = 2 }), "alpha=one"),
  "an unknown tool shows its scalar arguments")

-- A clip must not split a multi-byte character in half: the spinner and the ellipsis
-- are UTF-8, and half a character on screen is a rendering bug, not a cosmetic one.
local wide = view_lib.clip(string.rep("a", 9) .. "é" .. string.rep("b", 40), 11)
ok(#wide > 0 and not wide:find("\195\169$"), "a clip never ends mid-character")
ok(not has(wide, "\n"), "a clip is one line")
ok(view_lib.clip(string.rep("\194\183", 10), 4) == string.rep("\194\183", 3) .. "\226\128\166",
  "a clip counts columns, not bytes")

-- ---- what came back ------------------------------------------------------------

local ok_bash, note_bash = view_lib.outcome("bash", { code = 0, stdout = "hi" })
ok(ok_bash and note_bash == "exit 0", "a zero exit is a success with its code")
local ok_fail, note_fail = view_lib.outcome("bash", { code = 1, stderr = "boom" })
ok(ok_fail == false and note_fail == "exit 1", "a non-zero exit is a failure, and says so")
local ok_error, note_error = view_lib.outcome("read", { error = "no such file" })
ok(ok_error == false and has(note_error, "no such file"), "a tool error is a failure with its reason")
local _, note_lines = view_lib.outcome("read", { content = "a\nb\nc" })
ok(note_lines == "2 lines", "a read reports lines, counting the content's own newlines")
local _, note_one = view_lib.outcome("grep", { count = 1 })
ok(note_one == "1 match", "one match is singular")
local _, note_many = view_lib.outcome("grep", { count = 4 })
ok(note_many == "4 matches", "several matches are plural")
local _, note_entries = view_lib.outcome("ls", { entries = { {}, {}, {} } })
ok(note_entries == "3 entries", "a listing reports its entry count")
local _, note_memory = view_lib.outcome("recall", { { content = "x" }, { content = "y" } })
ok(note_memory == "2 memories", "a recall reports how much memory it found")

local preview = view_lib.preview("bash", { code = 0, stdout = "\nfirst\nsecond\nthird\n" })
ok(#preview == 2 and preview[1] == "first", "a command's own output is shown, blank lines dropped")
local from_stderr = view_lib.preview("bash", { code = 1, stdout = "  ", stderr = "no such file" })
ok(#from_stderr == 1 and from_stderr[1] == "no such file", "a silent stdout falls back to stderr")
ok(#view_lib.preview("read", { content = "the whole file" }) == 0,
  "a file's contents are not repeated under the call that read them")

ok(view_lib.tokens(940) == "940" and view_lib.tokens(1200) == "1.2k" and view_lib.tokens(1500000) == "1.5M",
  "tokens are shown at a size a person reads")
ok(view_lib.elapsed(200) == "200ms" and view_lib.elapsed(3400) == "3.4s", "a step's duration carries its unit")
ok(view_lib.duration(9.5) == "9.5s" and view_lib.duration(74) == "1m14s", "a run's duration grows into minutes")
-- The clock's rule, pinned here and again in rust/wa-host/src/host.rs (`ticker_duration`):
-- the host draws the clock while this process is blocked, so the rule exists on both sides.
-- The same three values are asserted in both suites, so changing one alone fails a test here
-- instead of flickering a frame on a screen.
ok(view_lib.duration(59.94) == "59.9s", "under a minute the clock counts tenths of a second")
ok(view_lib.duration(60.0) == "1m00s", "at a minute it carries its seconds")
ok(view_lib.duration(125.4) == "2m05s", "and keeps counting in minutes")

-- ---- is this a terminal? --------------------------------------------------------

local function env_of(table_of)
  return function(name) return table_of[name] end
end
ok(view_lib.wants_live(env_of({ TERM = "xterm-256color" })) == true, "a terminal gets the live view")
ok(view_lib.wants_live(env_of({ ORCA_TERMINAL_HANDLE = "term_x" })) == true, "Orca's terminal counts as one")
ok(view_lib.wants_live(env_of({})) == false, "no terminal means no escape sequences")
ok(view_lib.wants_live(env_of({ TERM = "dumb" })) == false, "a dumb terminal is not a terminal to paint")
ok(view_lib.wants_live(env_of({ TERM = "xterm", NO_COLOR = "1" })) == false, "NO_COLOR wins over everything")
ok(view_lib.wants_live(env_of({ NO_COLOR = "1", WASM_AGENT_CLI_VIEW = "live" })) == true,
  "an explicit request wins over NO_COLOR")
ok(view_lib.wants_live(env_of({ TERM = "xterm", WASM_AGENT_CLI_VIEW = "plain" })) == false,
  "an explicit refusal wins over the terminal")

-- ---- a run, replayed ------------------------------------------------------------

local function recorder()
  local buffer = {}
  return {
    out = function(text) buffer[#buffer + 1] = text end,
    text = function() return table.concat(buffer) end,
  }
end

-- The events a real run emits, in the order agent.lua emits them: the status, a round,
-- the call, its result, a second round with a call that fails, the usage, the reply.
local function replay(view)
  view:run_started()
  view:event({ type = "status", text = "thinking" })
  view:event({ type = "round", n = 1 })
  view:event({ type = "status", text = "model" })
  view:event({ type = "tool", name = "bash", arguments = { command = "echo hi" }, timeout_ms = 300000 })
  view:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = "hi\n" } })
  view:event({ type = "round", n = 2 })
  view:event({ type = "status", text = "compaction failed: nothing to compact" })
  view:event({ type = "tool", name = "read", arguments = { path = "ui/app.js" } })
  view:event({ type = "tool_result", name = "read", result = { error = "no such file" } })
  view:event({ type = "usage", total = { prompt = 12000, completion = 800, cached = 11000, cost = 0.0021,
    last = { prompt = 45000 } } })
  view:event({ type = "reply", text = "done: one command ran." })
  view:answered("done: one command ran.")
end

-- Plain: a captured transcript. No escape sequences at all, one line per event, and the
-- same facts the live view shows.
local plain = recorder()
local plain_view = view_lib.new({
  out = plain.out, live = false, now = function() return 100 end,
  title = "wa - wasm_cli",
  workspace = "~/orca/workspaces/wasm-agent/wasm_cli", branch = "change/cli-run-view",
  budget = 128000, limit = 100,
})
plain_view:run_started()
plain_view:event({ type = "status", text = "thinking" })
plain_view:event({ type = "round", n = 1 })
plain_view:event({ type = "tool", name = "bash", arguments = { command = "echo hi" }, timeout_ms = 300000 })
plain_view:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = "hi\n" } })
plain_view:event({ type = "usage", total = { prompt = 1200, completion = 800, cached = 1100, cost = 0.0021 }, prompt = 45000 })
plain_view:answered("done: one command ran.")
local plain_text = plain.text()

ok(not has(plain_text, "\27"), "a captured transcript carries no escape sequences")
ok(not has(plain_text, view_lib.spinner(0)), "and no spinner: a moving frame is not a transcript")
ok(has(plain_text, "Thinking"), "the captured transcript says the run was thinking")
ok(has(plain_text, "Running bash"), "and what it ran")
ok(has(plain_text, "$ echo hi"), "with the command it was given")
ok(has(plain_text, "ok \194\183 exit 0"), "and whether it worked")
ok(has(plain_text, "hi"), "and what it printed")
ok(has(plain_text, "done: one command ran."), "the answer is in the transcript")
ok(select(2, plain_text:gsub("done: one command ran%.", "")) == 1, "the answer appears exactly once")
ok(has(plain_text, "1 round \194\183 1 tool"), "the footer counts the run's rounds and tools")
ok(has(plain_text, "1.2k"), "and its input tokens")
ok(has(plain_text, "CH91.7%"), "and how much of that input came from the cache")
ok(has(plain_text, "$0.0021"), "and its cost")
ok(has(plain_text, "ctx 35.2%/128.0k"), "and how full the context window is")
ok(view_lib.columns(plain_text:match("[^\n]*ctx[^\n]*")) <= 100, "and the footer is one line that fits")

-- A node that reports no measured prompt (an older binary, a provider without usage)
-- must not print a context figure it does not have.
local unmeasured = view_lib.footer({ rounds = 1, prompt = 100 }, { context = 0, budget = 128000 })
ok(not has(unmeasured, "ctx"), "an unmeasured context is left out rather than shown as zero")

-- The denominator is the *model's* window, resolved where compaction resolves it. This
-- deployment's model has a 1,000,000-token window while the old global says 128000, so a
-- footer that read the global reported the same context eight times fuller than it was.
ok(view_lib.window("m", function() return { context = 1000000, source = "pi-model-store" } end) == 1000000,
  "the footer divides by the model's window, not by the global")
ok(has(view_lib.footer({ rounds = 1, prompt = 100 }, { context = 450000, budget = 1000000 }),
  "ctx 45.0%/1.0M"), "and prints that window")
ok(view_lib.window("m", function() return { context = 0, source = "unknown" } end)
  == (tonumber(host.getenv("WASM_AGENT_LLM_CONTEXT")) or 0),
  "an unknown window falls back to the global rather than guessing")
ok(view_lib.window("m", function() error("no catalogue") end)
  == (tonumber(host.getenv("WASM_AGENT_LLM_CONTEXT")) or 0),
  "and a catalogue that fails does not take the banner down with it")
ok(view_lib.window("m", nil) == (tonumber(host.getenv("WASM_AGENT_LLM_CONTEXT")) or 0),
  "a missing resolver falls back too")

-- The banner: where this chat is, and what it is running with. A chat in the wrong
-- worktree is otherwise a mistake that costs an hour to notice.
local banner = view_lib.banner({
  live = false, version = "0.1.0", model = "deepseek-v4.1-flash @ https://example.invalid/v1",
  database = "~/.wasm-agent/memory.db", session = "abc", continued = true,
  workspace = "~/orca/workspaces/wasm-agent/wasm_cli", branch = "change/cli-run-view",
})
ok(has(banner, "~/orca/workspaces/wasm-agent/wasm_cli"), "the banner says which worktree this is")
ok(has(banner, "change/cli-run-view"), "and which branch it is on")
ok(has(banner, "deepseek-v4.1-flash"), "and which model is answering")
ok(has(banner, "abc"), "and which thread it is continuing")
ok(not has(banner, "\27"), "and stays plain when the output is captured")
ok(has(view_lib.banner({ live = false, session = "abc", unfinished = "cut off at seq 4" }),
  "unfinished cut off at seq 4"), "a thread cut off mid-answer is announced, not left quiet")

-- ---- where this is running -------------------------------------------------------

-- Read from `.git`, not by running `git`, and read the way git writes it: a linked
-- worktree's `.git` is a file, its path carries a carriage return on Windows, and a
-- branch name with a CR in it is a path that cannot be opened.
local scratch = (host.paths and host.paths().temp or "/tmp"):gsub("\\", "/") .. "/wa-cli-view-test"
local wrote = host.write_file(scratch .. "/worktree/.git", "gitdir: " .. scratch .. "/realgit/worktrees/one\r\n")
ok(wrote == true, "the test can write a fake worktree")
host.write_file(scratch .. "/realgit/worktrees/one/HEAD", "ref: refs/heads/change/cli-run-view\n")
ok(view_lib.branch(scratch .. "/worktree") == "change/cli-run-view",
  "a linked worktree's branch is read through its gitdir")
host.write_file(scratch .. "/plain/.git/HEAD", "ref: refs/heads/main\n")
ok(view_lib.branch(scratch .. "/plain") == "main", "a plain checkout's branch is read from .git/HEAD")
host.write_file(scratch .. "/detached/.git/HEAD", "9f4c1b2e8a7d6c5b4a39281706f5e4d3c2b1a090\n")
ok(view_lib.branch(scratch .. "/detached") == "9f4c1b2e", "a detached HEAD is shown as a short sha")
ok(view_lib.branch(scratch .. "/nowhere") == "", "a directory that is not a repository says nothing")
ok(view_lib.branch("") == "", "and so does no directory at all")
ok(view_lib.workspace("C:\\Users\\Victor\\orca\\w", "C:\\Users\\Victor") == "~/orca/w",
  "the workspace is abbreviated against the home directory")
ok(view_lib.workspace("/srv/tree", "C:\\Users\\Victor") == "/srv/tree",
  "and left alone when it is not under it")

-- Live: a terminal. The status line is rewritten in place, colour marks the phases, and
-- the title carries the same word.
local live = recorder()
local clock = { value = 0 }
local live_view = view_lib.new({
  out = live.out, live = true, now = function() return clock.value end,
  title = "wa - wasm_cli",
  workspace = "~/orca/workspaces/wasm-agent/wasm_cli", branch = "change/cli-run-view",
  budget = 128000, limit = 100,
})
live_view:run_started()
ok(has(live.text(), "\27]2;"), "the terminal title is set when a run starts")
clock.value = 3
live_view:event({ type = "status", text = "thinking" })
clock.value = 12
live_view:event({ type = "round", n = 1 })
ok(has(live.text(), "\27" .. "7\r"), "the status line is rewritten in place, not printed again")
ok(not has(live.text(), "\27[2K"), "and never erases to the end of the row the reader types on")
ok(has(live.text(), view_lib.spinner(0)), "the status line carries a spinner")
ok(has(visible(live.text()), "Thinking \194\183 12.0s \194\183 run 1 \194\183 step 1"),
  "the status line says what, for how long, and counts the run and its steps")
clock.value = 20
live_view:event({ type = "tool", name = "bash", arguments = { command = "echo hi" }, timeout_ms = 300000 })
ok(has(live.text(), "Running bash"), "a call in flight is named in the status line")
ok(has(live.text(), "of 5m00s"), "and the deadline it is running against is visible")
clock.value = 21
live_view:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = "hi\n" } })
ok(has(live.text(), "1.0s"), "a step reports how long it took")
ok(has(live.text(), view_lib.style("success") .. "ok"), "success is marked as success")
local before_answer = #live.text()
live_view:event({ type = "tool", name = "read", arguments = { path = "ui/app.js" } })
live_view:event({ type = "tool_result", name = "read", result = { error = "no such file" } })
ok(has(live.text(), view_lib.style("error") .. "failed"), "a failed call is marked as failed, with its reason")
ok(has(live.text(), "no such file"), "and the reason is shown")
clock.value = 30
live_view:event({ type = "usage", total = { prompt = 1200, completion = 800, cached = 1100, cost = 0.0021 },
  prompt = 45000 })
live_view:answered("done: one command ran.")
local live_text = live.text()
ok(#live_text > before_answer, "the run kept writing after the first call")
ok(has(live_text, "done: one command ran."), "the answer is printed")
ok(select(2, live_text:gsub("done: one command ran%.", "")) == 1, "and printed once")
ok(has(live_text, view_lib.style("dim")), "the footer is dimmed rather than shouted")
ok(has(live_text:sub(-40), "wa - wasm_cli"), "the title returns to the workspace when the run ends")
ok(not has(live_text:sub(-80), "Thinking"), "and the status line is gone when the run ends")

-- The replay helper is here so the two renderings above stay the same run: if the event
-- order ever changes, both break together.
ok(type(replay) == "function", "the replay is shared by both renderings")

-- An error is visible, and it does not swallow the run's numbers.
local errored = recorder()
local error_view = view_lib.new({ out = errored.out, live = false, now = function() return 5 end })
error_view:run_started()
error_view:event({ type = "tool", name = "bash", arguments = { command = "false" } })
error_view:event({ type = "tool_result", name = "bash", result = { code = 1, stderr = "nope" } })
error_view:failed("provider_http_500: boom")
ok(has(errored.text(), "! provider_http_500: boom"), "a failed run says so in one line")
ok(has(errored.text(), "failed \194\183 exit 1"), "and the step that failed still reads as failed")

-- A bug in the renderer must not kill the run it describes, and must not be silent.
local warned = recorder()
local warn_view = view_lib.new({ out = warned.out, live = false, now = function() return 1 end })
warn_view:run_started()
warn_view:warn("attempt to index a nil value")
warn_view:warn("a second failure nobody needs to read")
ok(select(2, warned.text():gsub("the run view failed", "")) == 1, "a view failure is reported once")
ok(has(warned.text(), "attempt to index a nil value"), "and it says what went wrong")

-- ---- the line keeps moving -------------------------------------------------------

-- While this process is blocked the host draws the status line, so two things have to be
-- true: what the host is handed is exactly the line this module would have printed, and it is
-- never drawing that line while the module writes to it. The host is stubbed here - one line
-- of decoration must not need a terminal to be testable - and the real timer is measured by
-- `scripts/test-cli-ticker.lua`, through a captured child process.
local handed = {}
local real_ticker = host.ticker
local ticker_out = recorder()
host.ticker = function(spec)
  handed[#handed + 1] = {
    kind = spec == nil and "stop" or "start",
    at = #ticker_out.text(),
    spec = spec and json.decode(spec) or nil,
  }
  return spec ~= nil
end
local ticker_clock = { value = 100 }
local animated = view_lib.new({
  out = ticker_out.out, live = true, stdout = true, now = function() return ticker_clock.value end,
  limit = 100,
})
animated:run_started()
ok(#handed == 1 and handed[1].kind == "start", "a starting run hands its line to the host")
local spec = handed[1].spec
ok(type(spec) == "table" and type(spec.line) == "string", "and what it hands over is a line")
ok(spec.line == animated:status_template(), "the layout, with its two tokens still in it")
ok(spec.marks[1] == "\226\160\139 ", "this view's marks, in this view's order")
ok(spec.started == animated.turn.started, "and the origin of the clock, so a redraw does not restart it")
ok(not has(spec.line, view_lib.spinner(0)), "no frame is baked into the layout")

-- The strongest statement available without a terminal: filling the layout by the host's own
-- rules gives back the line this module prints for itself.
local mark = spec.marks[(spec.frame % #spec.marks) + 1]
local filled = spec.line:gsub("{m}", function() return mark end)
filled = filled:gsub("{t}", function() return view_lib.duration(0) end)
ok(filled == animated:status_text(true), "and the host's frame is word for word the view's own line")

ticker_clock.value = 130
animated:event({ type = "round", n = 1 })
animated:event({ type = "tool", name = "bash", arguments = { command = "echo hi" } })
ok(has(ticker_out.text(), "$ echo hi"), "the tool line is written while the host is not drawing")
animated:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = "hi\n" } })
animated:answered("done: one command ran.")

-- The invariant: nothing is written to that line between the moment the host is given it and
-- the moment it is taken back (`at` is how much output existed at each call).
local drift, holding = 0, nil
for _, call in ipairs(handed) do
  if holding ~= nil and holding ~= call.at then drift = drift + 1 end
  holding = call.kind == "start" and call.at or nil
end
ok(drift == 0, "no writer touches the line while the host is holding it")
ok(holding == nil and handed[#handed].kind == "stop",
  "and the run ends with the line taken back, not left moving")

-- A view whose output is not this process's stdout must leave the terminal alone: the host
-- draws on stdout and nowhere else.
local before = #handed
local quiet = recorder()
local not_mine = view_lib.new({ out = quiet.out, live = true, now = function() return 1 end, limit = 100 })
not_mine:run_started()
not_mine:event({ type = "round", n = 1 })
ok(#handed == before, "a view that does not own stdout asks the host for nothing")
local transcript = view_lib.new({ out = quiet.out, live = false, now = function() return 1 end })
transcript:run_started()
ok(#handed == before, "and a captured transcript never animates")

-- A host older than this view has no ticker at all: decoration must degrade, not raise.
host.ticker = nil
local degraded = pcall(function()
  local older = view_lib.new({ out = quiet.out, live = true, stdout = true, now = function() return 1 end })
  older:run_started()
  older:event({ type = "round", n = 1 })
  older:answered("still answered")
end)
host.ticker = real_ticker
ok(degraded == true and has(quiet.text(), "still answered"),
  "a host without the ticker still finishes the run")

-- ---- pi's palette, per component -------------------------------------------------

-- The roles are pi's own and the colours are pi's own
-- (`dist/modes/interactive/theme/dark.json` in `@earendil-works/pi-coding-agent`). Asserting
-- the exact sequence is the point: "coloured" is not the property, "coloured the way pi
-- colours it" is, and a role renamed to a different colour would pass any weaker check.
ok(view_lib.PALETTE.accent == "8abeb7", "the accent is pi's accent")
ok(view_lib.PALETTE.success == "b5bd68" and view_lib.PALETTE.error == "cc6666",
  "success and error are pi's green and red")
ok(view_lib.style("success") == "\27[38;2;181;189;104m", "a role becomes its own 24-bit colour")
ok(view_lib.style("red") == view_lib.style("error"),
  "the old names are the same roles, not a second palette")
ok(view_lib.style("mdHeading") == "\27[38;2;240;198;116m", "and the markdown roles are pi's too")

-- The status line carries the colour, and the colour is a rendering decision: the same line
-- is plain when the output is captured, and plain again on a terminal too narrow for it -
-- `clip` counts columns, and a coloured line clipped by width loses its reset and bleeds.
local status_out = recorder()
local live_status = view_lib.new({ out = status_out.out, live = true, now = function() return 3 end, limit = 100 })
live_status:run_started()
ok(has(status_out.text(), view_lib.style("accent")), "the phase word on the status line is pi's accent")
ok(has(status_out.text(), "Thinking"), "and the words are still there")
local plain_status = recorder()
local quiet_status = view_lib.new({ out = plain_status.out, live = false, now = function() return 3 end, limit = 100 })
quiet_status:run_started()
ok(not has(plain_status.text(), "\27"), "a captured status line carries no escape sequence")
local narrow_status = recorder()
local narrow_view = view_lib.new({ out = narrow_status.out, live = true, now = function() return 3 end, limit = 8 })
narrow_view:run_started()
ok(not has(narrow_status.text(), "\27[38;2;"),
  "a terminal too narrow for the status line gets it plain rather than cut mid-colour")

-- ---- the answer is markdown --------------------------------------------------------

local answered = recorder()
local answer_view = view_lib.new({ out = answered.out, live = true, now = function() return 5 end, limit = 80 })
answer_view:run_started()
answer_view:answered("# Done\n\n- one\n- two\n\n```lua\nlocal x = 1\n```\n\nplain words")
local answer = answered.text()
ok(has(answer, view_lib.style("mdHeading")), "a heading in the answer is coloured as a heading")
ok(has(answer, view_lib.style("mdListBullet")), "a bullet is coloured as a bullet")
ok(has(answer, view_lib.style("syntaxKeyword")), "and code in a fence is coloured as code")
ok(not has(answer, "# Done"), "the markdown marks do not reach the screen")
ok(has(answer, "plain words"), "and the words do")

-- A reply the renderer produces nothing for is printed raw: a view that swallowed an answer
-- because its parser did not recognise it would be the worst bug in the file.
local odd = recorder()
local odd_view = view_lib.new({ out = odd.out, live = false, now = function() return 5 end, limit = 80 })
odd_view:run_started()
odd_view:answered("   \n  \n")
ok(has(odd.text(), "   ") or not has(odd.text(), "answered"), "an empty reply prints nothing rather than crashing")

-- ---- the reasoning, as its own block -----------------------------------------------

local thought = recorder()
local think_view = view_lib.new({ out = thought.out, live = false, now = function() return 7 end, limit = 80 })
think_view:run_started()
think_view:event({ type = "reasoning", text = "the reader wants the view fixed, so I will read cli_view.lua first" })
ok(has(thought.text(), "\226\156\187 thinking"), "the reasoning is announced as thinking")
ok(has(thought.text(), "read cli_view.lua first"), "and printed in full rather than summarised")
ok(view_lib.columns(thought.text():match("[^\n]*read[^\n]*") or "") <= 80, "and wrapped to the terminal")

-- ---- the console -------------------------------------------------------------------

local raw = recorder()
local console_view = view_lib.new({ out = raw.out, live = true, now = function() return 9 end, limit = 40 })
ok(console_view:set_console(true) == true, "the console can be turned on")
console_view:run_started()
console_view:event({ type = "tool", name = "bash", arguments = { command = "seq 1 60" } })
local many = {}
for line = 1, 60 do many[#many + 1] = "output line " .. line end
console_view:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = table.concat(many, "\n") } })
local console_text = raw.text()
ok(has(console_text, '"command":"seq 1 60"'), "the console shows the arguments the tool was given")
ok(has(console_text, "output line 60"), "and a tool's output whole, not the two lines the view prints")
ok(not has(console_text, "ok \194\183 exit 0"),
  "and no formatted result line: the console is one line per event")
ok(console_view:console_on() == true and console_view:set_console(false) == false,
  "and it can be turned off again")

-- ---- the width ---------------------------------------------------------------
--
-- The width a terminal *has* is not the width a child can know. `COLUMNS` is a shell variable on most
-- machines and is not exported to children, so the only number this had was the 80 it fell back to -
-- measured: a 120-column terminal, `COLUMNS` empty, answers wrapped at 78 columns. The console is
-- asked first (`host.terminal_size`), the environment second, and 80 last.
--
-- Every case below is one that happens: the console answers, it answers zero because nothing is
-- attached, an older binary has no `terminal_size` at all, or `COLUMNS` is stale or junk.
local platform = dofile("lua/core/platform.lua")
local says = function(columns) return function() return { columns = columns } end end
ok(platform.columns(nil, says(120)) == 120, "the console's width is the width used")
ok(platform.columns("90", says(120)) == 120, "and it wins over a stale COLUMNS")
ok(platform.columns("100", function() return nil end) == 100, "without a console, COLUMNS is used")
ok(platform.columns(nil, function() return nil end) == 80, "and 80 is the last resort")
ok(platform.columns(nil, says(0)) == 80, "a console that answers zero is not a width of zero")
ok(platform.columns("0", says(0)) == 80, "and neither is a zero in COLUMNS")
ok(platform.columns("abc", function() return nil end) == 80, "nor junk in COLUMNS")
ok(platform.columns(nil, function() return { columns = "120" } end) == 120,
  "and a width that arrives as text (the shape JSON would give) is still a width")

-- ---- the prompt, and the row the reader types on ---------------------------------
--
-- The prompt used to be pinned to the console's last row (CUD 999) with that row erased first
-- (`\27[2K`). Both halves were wrong on the row a reader types on: once the transcript has reached
-- the bottom of the screen that row holds a line of output, and the erase takes the reader's own
-- half-typed message with it. The status line is written in place on that same row, so what is
-- pinned here is the bound - only the columns this view drew, never an erase to the right of them,
-- a newline when the line needs more room than it drew - and that a transcript gets none of it.
local function capture(options)
  local written = {}
  options = options or {}
  options.out = function(text) written[#written + 1] = text end
  return view_lib.new(options), written
end

local live_view, live_written = capture({ live = true, limit = 100 })
live_view:prompt("wa> ")
local drawn = table.concat(live_written)
ok(not has(drawn, "\27[999B"), "a live prompt does not jump down to the console's last row")
ok(not has(drawn, "\27[2K"), "and erases nothing on the way there")
ok(drawn:sub(-4) == "wa> ", "so the prompt lands where the output ended, where the typing goes")

local plain_view, plain_written = capture({ live = false, limit = 100 })
plain_view:prompt("wa> ")
ok(table.concat(plain_written) == "wa> ", "a transcript gets the bare prompt, with no escapes")

-- The reader may be typing on the row the status line is rewritten on: a run is exactly when they
-- type, and the terminal's echo lands at the end of that line.
local typed_view, typed_out = capture({ live = true, limit = 100 })
typed_view:run_started()
typed_view:event({ type = "status", text = "thinking" })
local repaint = table.concat(typed_out)
ok(not has(repaint, "\27[2K"), "a live status line never erases to the end of that row")
ok(has(repaint, "\27" .. "7\r") and repaint:sub(-2) == "\27" .. "8",
  "it saves and restores the cursor, which is also where the reader's next keystroke lands")

-- A shorter line: the columns it drew are padded, or the tail of the last frame stays on screen.
local pad_view, pad_out = capture({ live = true, limit = 100 })
pad_view:status_draw("  twelve chars")
pad_view:status_draw("  four")
ok(has(table.concat(pad_out), "  four" .. string.rep(" ", 8)),
  "a shorter status line pads the columns it drew, so no tail of the last frame stays")

-- A longer line: five columns that may hold the reader's text are not this view's to take.
local grow_view, grow_out = capture({ live = true, limit = 100 })
grow_view:status_draw("  four")
grow_view:status_draw("  a much longer status line")
ok(has(table.concat(grow_out), "\r\n"),
  "a longer status line commits the row instead of writing over the reader's columns")

-- Taking the line back is the same bound: its own columns blanked, the cursor at the row's start.
local clear_view, clear_out = capture({ live = true, limit = 100 })
clear_view:status_draw("  working")
clear_view:clear()
local cleared = table.concat(clear_out)
ok(has(cleared, "\r" .. string.rep(" ", 9) .. "\r"), "a clear blanks its own columns and no more")
ok(not has(cleared, "\27[2K"), "and never erases to the end of the row")

-- Colour is an instruction, not columns: the pad is measured against what a terminal shows.
ok(view_lib.visible_columns("\27[33mab\27[0m") == 2, "an escape sequence is not a column")
ok(view_lib.visible_columns("\27]2;title\7ab") == 2, "nor is a title")

-- ---- the screen: output, the status line, and the reader's row -------------------
--
-- The prompt cannot be pinned to the bottom row from an unknown cursor position (see above), so the
-- honest way to own the bottom is to own the rows: a scroll region for the output, a status row, and
-- an input row the terminal keeps echoing into. What is pinned here is the byte discipline. Whether
-- a given terminal renders it is not testable from here, which is why the knob exists.
local screen_view, screen_out = capture({ live = true, limit = 100, rows = function() return 12 end })
screen_view:prompt("wa> ")
local opened = table.concat(screen_out)
ok(has(opened, "\27[1;10r"), "the screen scrolls the output in a region above its own rows")
ok(has(opened, "\27[11;1H\27[2K"), "the status row is its own")
ok(has(opened, "\27[12;1H\27[2Kwa> "), "and the prompt is written on the last row, where typing goes")
ok(opened:sub(-4) == "wa> ", "leaving the cursor there")

-- Output goes inside the region, never on the two rows below it, and the reader's cursor comes back.
local function since(written, from)
  return table.concat(written, "", from)
end
local mark = #screen_out + 1
screen_view:line("hello")
local line_out = since(screen_out, mark)
ok(has(line_out, "\27[10;1Hhello"), "an output line is written inside the region")
ok(line_out:sub(1, 2) == "\27" .. "7" and line_out:sub(-2) == "\27" .. "8",
  "with the reader's cursor saved and restored around it")

-- The status line has a row of its own, and the ticker is told which: that is what lets it draw
-- there while the terminal's cursor stays on the input row.
mark = #screen_out + 1
screen_view:run_started()
screen_view:event({ type = "status", text = "thinking" })
ok(has(since(screen_out, mark), "\27[11;1H"), "the status line is drawn on the status row")

-- The reader's line is moved into the transcript before the input row is reused.
mark = #screen_out + 1
screen_view:accepted("is this lost?")
ok(has(visible(since(screen_out, mark)), "wa> is this lost?"),
  "an accepted line is committed to the transcript")
mark = #screen_out + 1
screen_view:submitted()
ok(has(since(screen_out, mark), "\27[12;1H\27[2Kwa> "),
  "a submitted line is cleared from the input row before the run begins")

-- Counters persist across turns in this process instead of restarting with each answer.
screen_view:event({ type = "round", n = 1 })
screen_view:answered("one")
screen_view:run_started()
screen_view:event({ type = "round", n = 1 })
ok(has(visible(table.concat(screen_out)), "run 2 \194\183 step 2"),
  "the live ticker counts runs and steps across turns")

-- Leaving gives the screen back: a scroll region outlives the process that set it.
mark = #screen_out + 1
screen_view:screen_off()
ok(has(since(screen_out, mark), "\27[r"), "the scroll region is reset on the way out")
ok(screen_view.screen == nil, "and the screen is forgotten")

-- A resized window: the rows move with it, so the old screen is given back and a new one is laid out
-- on the height the console now reports. Without this, a window made smaller leaves output scrolling
-- over the status and input rows for the rest of the chat.
local height = { rows = 12 }
local resize_view, resize_out = capture({ live = true, limit = 100, rows = function() return height.rows end })
resize_view:prompt("wa> ")
mark = #resize_out + 1
height.rows = 6
resize_view:prompt("wa> ")
local resized = since(resize_out, mark)
ok(has(resized, "\27[r"), "a resized window gives the old scroll region back")
ok(has(resized, "\27[1;4r"), "and lays the screen out on the new height")
ok(has(resized, "\27[6;1H\27[2Kwa> "), "with the prompt on the row that is last now")
ok(#resize_out > mark and not has(since(resize_out, mark), "\27[1;10r"),
  "and never both regions at once")

-- A console too short for one output row, and a reader who refuses the screen: both fall back to the
-- prompt at the cursor rather than to a broken one.
local short_view, short_out = capture({ live = true, limit = 100, rows = function() return 3 end })
short_view:prompt("wa> ")
ok(short_view.screen == nil, "no screen on a console too short for output, status and input")
ok(not has(table.concat(short_out), "\27[1;"), "and no region is claimed")
ok(table.concat(short_out):sub(-4) == "wa> ", "the prompt is still written")

local off_view, off_out = capture({ live = true, limit = 100, rows = function() return 30 end,
  getenv = function(name) return name == "WASM_AGENT_CLI_FRAME" and "off" or nil end })
off_view:prompt("wa> ")
ok(off_view.screen == nil and not has(table.concat(off_out), "\27[1;28r"),
  "WASM_AGENT_CLI_FRAME=off refuses the screen")

-- The rows themselves, from a height - with the same rule as the width: a console that answers zero
-- or nothing is not a height.
ok(view_lib.rows(function() return 24 end) == 24, "the console's height is the height used")
ok(view_lib.rows(function() return 0 end) == nil, "a console that answers zero is not a height")
ok(view_lib.rows(function() return nil end) == nil, "nor is a console that will not answer")
ok(view_lib.rows(function() return "24" end) == 24,
  "and a height that arrives as text (the shape JSON would give) is still a height")
ok(view_lib.screen_rows(24).input == 24 and view_lib.screen_rows(24).status == 23
  and view_lib.screen_rows(24).bottom == 22, "a 24-row console gives the screen its three zones")
ok(view_lib.screen_rows(3) == nil, "a 3-row console gives it none")
ok(view_lib.screen_rows(nil) == nil, "an unknown height gives it none")

if failed > 0 then
  print(string.format("cli view: %d failed of %d checks", failed, checks))
  os.exit(1)
end
print(string.format("cli view ok (%d checks)", checks))
