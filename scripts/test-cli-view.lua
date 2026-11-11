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

-- Equality with the two values in the message: a failure has to say what it saw.
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
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
local wide = view_lib.clip(string.rep("a", 9) .. "Ã©" .. string.rep("b", 40), 11)
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
-- The clock's rule, pinned here and again in rust/wa-capabilities/src/host.rs (`ticker_duration`):
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
local function tty() return true end
ok(view_lib.wants_live(env_of({ TERM = "xterm-256color" }), tty) == true, "a terminal gets the live view")
ok(view_lib.wants_live(env_of({ TERM = "xterm-256color" }), function() return false end) == false,
  "a pipe gets plain output even when TERM is set (wa chat | tee log)")
ok(view_lib.wants_live(env_of({ ORCA_TERMINAL_HANDLE = "term_x" }), tty) == true, "Orca's terminal counts as one")
ok(view_lib.wants_live(env_of({}), tty) == false, "no terminal means no escape sequences")
ok(view_lib.wants_live(env_of({ TERM = "dumb" }), tty) == false, "a dumb terminal is not a terminal to paint")
ok(view_lib.wants_live(env_of({ TERM = "xterm", NO_COLOR = "1" }), tty) == false, "NO_COLOR wins over everything")
ok(view_lib.wants_live(env_of({ NO_COLOR = "1", WASM_AGENT_CLI_VIEW = "live" }), tty) == true,
  "an explicit request wins over NO_COLOR")
ok(view_lib.wants_live(env_of({ TERM = "xterm", WASM_AGENT_CLI_VIEW = "plain" }), tty) == false,
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
ok(has(plain_text, "\226\143\186 Bash(echo hi)"), "with the command it was given, as a call heading")
ok(has(plain_text, "\226\142\191 hi") and has(plain_text, "exit 0"), "and what it returned, and whether it worked")
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
ok(has(live.text(), "\27[?25l\27[s\r"), "the status line is rewritten in place, not printed again")
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
ok(has(live.text(), view_lib.style("success") .. view_lib.DOT), "success is marked as success")
local before_answer = #live.text()
live_view:event({ type = "tool", name = "read", arguments = { path = "ui/app.js" } })
live_view:event({ type = "tool_result", name = "read", result = { error = "no such file" } })
ok(has(live.text(), view_lib.style("error") .. view_lib.DOT), "a failed call is marked as failed, with its reason")
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
ok(has(errored.text(), "\226\143\186 Error: provider_http_500: boom"), "a failed run says so in one line")
ok(has(errored.text(), "\226\143\186 Bash(false)") and has(errored.text(), "nope") and has(errored.text(), "exit 1"),
  "and the step that failed still reads as failed")

-- An interrupt is said as one, not as a stack of file positions.
local cancelled = recorder()
local cancel_view = view_lib.new({ out = cancelled.out, live = false, now = function() return 5 end })
cancel_view:run_started()
cancel_view:failed("lua/core/agent.lua:1285: lua/core/agent.lua:1528: run_cancelled")
ok(has(cancelled.text(), "Interrupted by user") and not has(cancelled.text(), "agent.lua"), "an interrupt reads as one")

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
ok(spec.marks[1] == view_lib.paint(view_lib.spinner(0), "accent", true) .. " ", "this view's marks, in this view's order")
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
animated:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = "hi\n" } })
ok(has(ticker_out.text(), "(echo hi)"), "the tool line is written while the host is not drawing")
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

-- ---- the palette, per component ---------------------------------------------------

-- The roles are pi's names; the colours are Claude Code's dark terminal look. Asserting the exact
-- sequence is the point: a role renamed to a different colour would pass any weaker check.
ok(view_lib.PALETTE.accent == "d77757", "the accent is the warm spinner accent")
ok(view_lib.PALETTE.success == "4eba65" and view_lib.PALETTE.error == "ff6b80",
  "success and error are the green and red of a tool's dot")
ok(view_lib.style("success") == "\27[38;2;78;186;101m", "a role becomes its own 24-bit colour")
ok(view_lib.style("red") == view_lib.style("error"),
  "the old names are the same roles, not a second palette")
ok(view_lib.style("mdHeading") == "\27[38;2;255;255;255m", "and the markdown roles follow it too")
-- Thinking is the view's one blue (inline code's and links'), commentary plain white; both
-- headings are the same grey.
ok(view_lib.style("thinkingText") == view_lib.style("borderAccent"),
  "thinking's body is the view's blue")
do
  local out = recorder()
  local v = view_lib.new({ out = out.out, live = true, now = function() return 1 end, limit = 100 })
  v:reasoning_block("weighing it")
  v:commentary_block("reading it")
  local text = out.text()
  ok(has(text, view_lib.style("muted") .. "\226\156\187 Thinking") and has(text, view_lib.style("muted") .. "\226\156\166 Commentary"),
    "the thinking heading is the same grey as commentary's")
  ok(has(text, view_lib.style("thinkingText") .. "weighing"), "and its body is blue")
end
ok(view_lib.style("commentaryText") == "\27[38;2;255;255;255m", "commentary is white")
ok(view_lib.PROMPT == "\226\157\175 " and view_lib.columns(view_lib.PROMPT) == 2,
  "the prompt glyph is Claude Code's U+276F, one cell plus a space")

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
ok(has(thought.text(), "\226\156\187 Thinking\226\128\166"), "the reasoning is announced as thinking")
ok(has(thought.text(), "read cli_view.lua first"), "and printed in full rather than summarised")
ok(view_lib.columns(thought.text():match("[^\n]*read[^\n]*") or "") <= 80, "and wrapped to the terminal")
local blue = recorder()
local blue_view = view_lib.new({ out = blue.out, live = true, now = function() return 7 end, limit = 80 })
blue_view:run_started()
blue_view:event({ type = "reasoning", text = "plain words to read" })
local tint = view_lib.style("thinkingText")
ok(has(blue.text(), "\27[3m" .. view_lib.style("muted") .. "\226\156\187 Thinking"), "live: the thinking heading is grey italic")
ok(has(blue.text(), tint .. "plain\27[0m " .. tint .. "words"), "and its body is blue, word by word")

-- ---- the commentary, as its own block, like the UI's ✦ commentary topic ----------------

local said = recorder()
local said_view = view_lib.new({ out = said.out, live = false, now = function() return 7 end, limit = 80 })
said_view:run_started()
said_view:event({ type = "commentary", text = "I'll read the config before changing it", message_id = "c1" })
ok(has(said.text(), "\226\156\166 Commentary"), "commentary is announced as commentary, with the UI's glyph")
ok(not has(said.text(), "\226\156\187 Thinking\226\128\166"), "and is not drawn as thinking")
ok(has(said.text(), "read the config before changing it"), "and printed in full")
local white = recorder()
local white_view = view_lib.new({ out = white.out, live = true, now = function() return 7 end, limit = 80 })
white_view:run_started()
white_view:event({ type = "commentary", text = "said to the reader", message_id = "w1" })
ok(has(white.text(), view_lib.style("commentaryText") .. "said\27[0m " .. view_lib.style("commentaryText") .. "to"),
  "live: the commentary body is white")
ok(not has(white.text(), "\27[34msaid"), "and never thinking's blue")
local streamed = recorder()
local streamed_view = view_lib.new({ out = streamed.out, live = false, now = function() return 7 end, limit = 80 })
streamed_view:run_started()
streamed_view:event({ type = "commentary_delta", pending_id = "p1", text = "checking " })
streamed_view:event({ type = "commentary_delta", pending_id = "p1", text = "the logs" })
ok(not has(streamed.text(), "checking"), "streamed commentary waits for its item to close")
streamed_view:event({ type = "commentary_end", message_id = "c2" })
ok(has(streamed.text(), "checking the logs"), "and is printed once, whole")
streamed_view:event({ type = "commentary_end", message_id = "c2" })
local _, count = streamed.text():gsub("checking the logs", "")
ok(count == 1, "never twice")
-- A chat-completions provider's commentary is the step's `content` beside its tool calls, and it
-- arrives as `step_phase` (agent.lua); a DeepSeek run printed none of it before this.
local chat = recorder()
local chat_view = view_lib.new({ out = chat.out, live = false, now = function() return 7 end, limit = 80 })
chat_view:run_started()
chat_view:event({ type = "step_phase", phase = "commentary", text = "I'll list /work/bin first.", message_id = "a1" })
ok(has(chat.text(), "\226\156\166 Commentary") and has(chat.text(), "list /work/bin first"),
  "a chat provider's step commentary is printed as commentary")
chat_view:event({ type = "step_phase", phase = "commentary", text = "  ", message_id = "a2" })
local _, blocks = chat.text():gsub("Commentary", "")
ok(blocks == 1, "an empty step leaves no block behind")
local peer = recorder()
local peer_view = view_lib.new({ out = peer.out, live = false, now = function() return 7 end, limit = 80 })
peer_view:run_started()
peer_view:event({ type = "delta", text = "streamed already" })
peer_view:event({ type = "step_phase", phase = "commentary", text = "streamed already", message_id = "a3" })
local _, peer_count = peer.text():gsub("streamed already", "")
ok(peer_count == 1, "text a peer already streamed is not printed again")

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
ok(has(repaint, "\27[?25l\27[s\r") and repaint:sub(-9) == "\27[u\27[?25h",
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

-- ---- reading a captured screen stream --------------------------------------------
-- A live screen layout writes frames: the synchronized-output pair (`view_lib.SYNC_START` … `_END`)
-- around the writes that belong together. That is what a reader sees painted at once, so it is also
-- the unit these checks are about: what a row held at the end of every frame. A frame that writes
-- nothing emits neither sequence, so a capture has no empty pair to step over.
local function frame_bodies(text)
  local bodies, pos, unterminated = {}, 1, 0
  while true do
    local open = text:find(view_lib.SYNC_START, pos, true)
    if not open then return bodies, unterminated end
    local body_start = open + #view_lib.SYNC_START
    local close = text:find(view_lib.SYNC_END, body_start, true)
    if not close then return bodies, unterminated + 1 end
    bodies[#bodies + 1] = text:sub(body_start, close - 1)
    pos = close + #view_lib.SYNC_END
  end
end
-- Every write this view makes to a row is the whole line (`status_draw`: address, text, pad, erase
-- to the end of the row), so the last one addressed to the row in a frame is what a reader sees there.
-- An address followed by `\27[2K` is the erase the blink was made of: the row holds nothing after it.
local function row_text(body, row)
  local address = "\27[" .. row .. ";1H"
  local at, held = body:find(address, 1, true), nil
  while at do
    local rest = body:sub(at + #address)
    if rest:sub(1, 4) == "\27[2K" then
      held = ""
    else
      local stop = rest:find("\27[u", 1, true) or (#rest + 1)
      held = (rest:sub(1, stop - 1):gsub("\27%[[%d;]*[A-Za-z]", ""))
    end
    at = body:find(address, at + #address, true)
  end
  return held
end
local function row_writes(body, row)
  local address, count, at = "\27[" .. row .. ";1H", 0, 1
  while true do
    local found = body:find(address, at, true)
    if not found then return count end
    count = count + 1
    at = found + #address
  end
end
-- `\27[2K` is the erase that made the blink: it blanks the whole row, and the line is drawn again a
-- frame later. Counted per row, so an erase on another row (the session-status-content line) is not
-- mistaken for one here.
local function count_erases(text, row)
  local needle, count, at = "\27[" .. row .. ";1H\27[2K", 0, 1
  while true do
    local found = text:find(needle, at, true)
    if not found then return count end
    count = count + 1
    at = found + #needle
  end
end
local mark = #screen_out + 1
screen_view:line("hello")
local line_out = since(screen_out, mark)
ok(has(line_out, "\27[10;1Hhello"), "an output line is written inside the region")
-- One frame around it: the synchronized-output pair on the outside, the reader's cursor saved and
-- restored inside it (see "no blink" below for why the write is framed at all).
ok(line_out:sub(1, #view_lib.SYNC_START) == view_lib.SYNC_START
  and has(line_out, "\27[?25l\27[s\27[10;1Hhello")
  and has(line_out, "\27[u\27[?25h")
  and line_out:sub(-#view_lib.SYNC_END) == view_lib.SYNC_END,
  "in one frame, with the reader's cursor saved and restored inside it")

-- The status line has a row of its own, and the ticker is told which: that is what lets it draw
-- there while the terminal's cursor stays on the input row.
mark = #screen_out + 1
screen_view:run_started()
screen_view:event({ type = "status", text = "thinking" })
ok(has(since(screen_out, mark), "\27[11;1H"), "the status line is drawn on the status row")

-- The reader's line is moved into the transcript before the input row is reused.
mark = #screen_out + 1
screen_view:accepted("is this lost?")
ok(has(visible(since(screen_out, mark)), "\226\157\175 is this lost?"),
  "an accepted line is committed to the transcript, after the `❯` user-turn mark")
mark = #screen_out + 1
screen_view:accepted("two\nlines")
local turn_rows = visible(since(screen_out, mark))
ok(has(turn_rows, "\226\157\175 two") and has(turn_rows, "  lines"), "a second line sits under the first one's text")
local bar = since(screen_out, mark):match("\27%[48;2;68;68;68m([^\27]*)") or ""
ok(view_lib.columns(bar) == screen_view.limit, "the grey bar counts `❯` as one cell, not three bytes: " .. view_lib.columns(bar))
mark = #screen_out + 1
screen_view:submitted()
ok(has(since(screen_out, mark), "\27[12;1H\27[2K\226\157\175 "),
  "a submitted line is cleared from the input row before the run begins")

-- Counters persist across turns in this process instead of restarting with each answer.
screen_view:event({ type = "round", n = 1 })
screen_view:answered("one")
screen_view:run_started()
screen_view:event({ type = "round", n = 1 })
ok(has(visible(table.concat(screen_out)), "1 round"),
  "the pinned summary counts rounds in the current run")

-- With a raw editor the host owns and redraws the input row while Lua is blocked.
-- The view must not overwrite it with a canonical prompt or clear it after Enter.
local real_editor = host.input_editor
local editor_calls = {}
host.input_editor = function(row, width, height) editor_calls[#editor_calls + 1] = {row, width, height}; return true end
local editor_view, editor_out = capture({ live = true, limit = 80, rows = function() return 12 end })
editor_view.editor = true
editor_view:prompt("wa> ")
ok(#editor_calls == 1 and editor_calls[1][1] == 11 and editor_calls[1][2] == 80
  and editor_calls[1][3] == 3, "the live view gives the editor three rows and its width")
ok(has(table.concat(editor_out), "\27[1;5r") and has(table.concat(editor_out), "\27[12;1H"),
  "the ticker and editor do not share the output scroll region")
editor_view:run_started()
editor_view:event({ type = "round", n = 6 })
editor_view:event({ type = "tool", name = "bash", arguments = { command = "true" } })
local session_total = { prompt = 120400, completion = 1000, cached = 90540 }
editor_view:event({ type = "usage", total = session_total, prompt = 27200 })
local running = table.concat(editor_out)
ok(has(running, "\240\159\145\1636\194\183") and has(running, "\226\154\146\239\184\1431")
  and has(running, "\226\134\14527.2k \226\134\1471.0k"),
  "the status line shows the step, the run's tools, what it added to the context and its output")
editor_view:answered("## Done")
local summary = editor_view.last_summary
ok(summary and has(summary, "\226\134\1871 ") and has(summary, "\226\151\13575.20%"),
  "completion leaves the session's numbers: runs, and the cache hit rate")
local idle_mark = #editor_out + 1
editor_view:prompt()
ok(has(since(editor_out, idle_mark), "\226\134\1871 ") and has(since(editor_out, idle_mark), "\27[12;1H"),
  "the session summary stays in the footer while idle")
local before_submit = #editor_out
editor_view:submitted()
ok(#editor_out == before_submit, "the submitted draft was already cleared by the editor")
-- The agent adds to one session-totals table in place: the next run's baseline must be a copy
-- of it, or the run's numbers diff against themselves and stay at zero.
local second_mark = #editor_out + 1
editor_view:run_started()
editor_view:event({ type = "round", n = 1 })
session_total.prompt = session_total.prompt + 30000
session_total.completion = session_total.completion + 450
editor_view:event({ type = "usage", total = session_total, prompt = 30000 })
local second = table.concat(editor_out, "", second_mark)
ok(has(second, "\226\134\1452.8k \226\134\147450"),
  "a later run counts its own context growth and output, not zero")
editor_view:answered("ok")
editor_view:screen_off()
host.input_editor = real_editor

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
local boxed = view_lib.screen_rows(12, true)
ok(boxed.bottom == 5 and boxed.status == 5 and boxed.input_top == 6 and boxed.input == 11
  and boxed.footer == 12 and boxed.session == 11 and boxed.region == 4,
  "a live editor, bottom up: footer, the session-status-content line, the box (two borders, three rows),"
    .. " the run-status line above it, and the output")
ok(view_lib.screen_rows(9, true) == nil, "a short console cannot host the boxed editor")
ok(view_lib.screen_rows(3) == nil, "a 3-row console gives it none")
ok(view_lib.screen_rows(nil) == nil, "an unknown height gives it none")

-- ---- no blink: the status row is never erased for a transcript write -----------------
--
-- Reported by Victor (08/11): in `wa chat` the run-status line disappeared and came back on every
-- tool call. `METHODS:clear` erased the status row (`\27[2K`) before any transcript write and the
-- line was drawn again a moment later - two frames, so a reader saw a blink. A screen gives the
-- status line a row of its own, and a transcript write goes into the output region above it, so the
-- erase was never necessary there. What is pinned here is the boxed layout over a whole run: no
-- erase on that row, the line on it at the end of every frame, at most one write per frame, and it
-- is taken back once - in place - when the run ends. The inline layout, which shares the reader's
-- row, is pinned as unchanged: no frames at all, and the same bounded blanking it had before.
do
  local boxed_view, boxed_written = capture({ live = true, limit = 100, rows = function() return 30 end })
  -- The host's editor is the process's real one; the rows it takes are asserted above. Here it only
  -- has to answer, so the layout can be entered the way `prompt` enters it.
  local real_input_editor = host.input_editor
  host.input_editor = function() return true end
  boxed_view.editor = true -- the boxed screen: footer on the last row, status above the box
  boxed_view:prompt("wa> ")
  local status_row = boxed_view.screen.status
  local content_row = boxed_view.screen.content
  -- Where the session-status-content line is drawn in the boxed layout: its own row between the box and
  -- the footer (`screen.session`, the same row `wa-term`'s `session_row` names), not the fallback's
  -- `content`, which is the region's last row. Those are the same row only in the fallback, so reading
  -- `session` first is the difference between asserting the notice's own row and passing by accident
  -- because the status line happened to be written on `content` too.
  local notice_row = boxed_view.screen.session or content_row
  local steps = "\240\159\145\163" -- `👣`, the boxed status line's step count: on it the whole run

  local mark = #boxed_written + 1
  boxed_view:run_started()
  for step = 1, 10 do
    boxed_view:event({ type = "round", n = step })
    boxed_view:event({ type = "tool", name = "read", arguments = { path = "lua/core/agent.lua" } })
    boxed_view:event({ type = "tool_result", name = "read", result = { content = "a\nb\n" } })
  end
  boxed_view:event({ type = "usage", total = { prompt = 12000, completion = 800 }, prompt = 12000 })
  local run = since(boxed_written, mark)

  local bodies, unterminated = frame_bodies(run)
  eq(count_erases(run, status_row), 0, "a turn of ten tool calls erases the status row no times")
  eq(unterminated, 0, "every frame of the run is closed")
  ok(#bodies >= 20, "the run is drawn as frames, one per event or more: " .. #bodies)
  local updated = 0
  for _, body in ipairs(bodies) do updated = updated + row_writes(body, status_row) end
  ok(updated > 0, "and the line is updated in place, on its own row: " .. updated .. " writes")

  -- What the row holds after each frame, starting from screen setup (which blanked it).
  local held, missing, twice = "", 0, 0
  local first_missing
  for index, body in ipairs(bodies) do
    local drawn = row_text(body, status_row)
    if drawn then held = (drawn:gsub("%s+$", "")) end
    if not has(held, steps) then
      missing = missing + 1
      first_missing = first_missing or (index .. ": " .. held)
    end
    if row_writes(body, status_row) > 1 then twice = twice + 1 end
  end
  eq(missing, 0, "the status text is on its row at the end of every frame of the run")
  if first_missing then print("  first frame without the status line: " .. first_missing) end
  eq(twice, 0, "and no frame writes that row twice: an erase plus a redraw is the blink")

  -- The end of a run is the one moment the line really goes away: taken back once, in place.
  local end_mark = #boxed_written + 1
  boxed_view:answered("done: ten reads.")
  local ending = since(boxed_written, end_mark)
  eq(count_erases(ending, status_row), 0, "the end of a run erases no row either")
  eq(row_writes(ending, status_row), 1, "the status row is taken back exactly once, where the run ends")
  eq((row_text(ending, status_row) or ""):gsub("%s", ""), "", "and what it then holds is nothing")
  eq(boxed_view.shown_cols, 0, "so the next frame pads from column zero")

  -- The session-status-content line keeps its own row, above the status line, and is erased there.
  local notice = "Update available (cccccccccccc): run wa update or /update"
  boxed_view.session_notice = notice
  local notice_mark = #boxed_written + 1
  boxed_view:event({ type = "round", n = 11 })
  local noticed = since(boxed_written, notice_mark)
  ok(has(noticed, "\27[" .. notice_row .. ";1H"), "the notice is drawn on the sscontent row, not the status row")
  ok(notice_row ~= status_row, "and that row is not the status line's: " .. notice_row .. " vs " .. status_row)
  eq(count_erases(noticed, status_row), 0, "and the status row is still not erased")
  ok(has(noticed, "\27[1;" .. (content_row - 1) .. "r"), "the output region still shrinks to leave it that row")
  local clear_mark = #boxed_written + 1
  boxed_view.session_notice = nil
  boxed_view:session_draw()
  local cleared_notice = since(boxed_written, clear_mark)
  ok(has(cleared_notice, "\27[" .. notice_row .. ";1H\27[2K"),
    "a notice that goes away takes its own row with it: sscontent is unaffected")
  eq(count_erases(cleared_notice, status_row), 0, "and the status row is untouched by it")
  boxed_view:screen_off()
  host.input_editor = real_input_editor

  -- The inline layout, unchanged: no frames (its status line shares the reader's row), the same
  -- bounded blanking, and the same absence of any erase to the end of that row.
  local inline_view, inline_written = capture({ live = true, limit = 100 })
  inline_view:prompt("wa> ")
  local inline_mark = #inline_written + 1
  inline_view:run_started()
  for step = 1, 10 do
    inline_view:event({ type = "round", n = step })
    inline_view:event({ type = "tool", name = "bash", arguments = { command = "true" } })
    inline_view:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = "ok\n" } })
  end
  local inline = since(inline_written, inline_mark)
  ok(inline_view.screen == nil, "the inline layout is still the inline layout: no screen, no rows")
  ok(not has(inline, view_lib.SYNC_START) and not has(inline, view_lib.SYNC_END),
    "and it is written exactly as before: no synchronized-output sequences at all")
  ok(not has(inline, "\27[2K"), "it still never erases to the end of the reader's row")
  ok(inline:find("\r +\r") ~= nil, "and still blanks exactly its own columns, as it always did")
  ok(has(inline, "\27[?25l\27[s\r"), "the status line is rewritten in place on that row, unprefixed")

  -- `WASM_AGENT_CLI_SYNC=off` turns the frames off for a terminal whose mode-2026 support is worse
  -- than the tearing it prevents. It is the frames only: no blink comes back with the knob, because
  -- the erase is gone independently of them.
  local unframed_view, unframed_written = capture({ live = true, limit = 100, rows = function() return 30 end,
    getenv = function(name) return name == "WASM_AGENT_CLI_SYNC" and "off" or nil end })
  local real_editor_again = host.input_editor
  host.input_editor = function() return true end
  unframed_view.editor = true
  unframed_view:prompt("wa> ")
  local unframed_mark = #unframed_written + 1
  unframed_view:run_started()
  for step = 1, 10 do
    unframed_view:event({ type = "round", n = step })
    unframed_view:event({ type = "tool", name = "read", arguments = { path = "lua/core/agent.lua" } })
    unframed_view:event({ type = "tool_result", name = "read", result = { content = "a\nb\n" } })
  end
  local unframed = since(unframed_written, unframed_mark)
  ok(not has(unframed, view_lib.SYNC_START) and not has(unframed, view_lib.SYNC_END),
    "WASM_AGENT_CLI_SYNC=off writes no frames at all")
  eq(count_erases(unframed, unframed_view.screen.status), 0,
    "and the status row is still never erased: no blink with the knob either")
  local unframed_row = frame_bodies(unframed)
  eq(#unframed_row, 0, "(no frames to find)")
  ok(has(row_text(unframed, unframed_view.screen.status) or "", steps),
    "while the line is still drawn in place on its own row")
  unframed_view:screen_off()
  host.input_editor = real_editor_again
end

-- ---- routed calls: `tool_call` and `remote` --------------------------------------
-- The generic wrapper used to read `tool_call name=remote`: a call happened, nothing about what it
-- ran or what came back. These are the events agent.lua emits for it (`tool` with the wrapper's
-- decoded arguments, then `tool_result` with the wrapper's name and the inner tool's result).
local function routed(arguments, result, limit)
  local out = recorder()
  local v = view_lib.new({ out = out.out, live = false, now = function() return 100 end, limit = limit or 100 })
  v:run_started()
  v:event({ type = "tool", call_id = "c1", name = "tool_call", arguments = arguments })
  local phase = v.phase
  v:event({ type = "tool_result", name = "tool_call", result = result,
    failed = type(result) == "table" and result.error ~= nil, cancelled = false })
  return out.text(), phase
end

local remote_args = { name = "remote", arguments = { node = "openclaw", capability = "bash",
  args = { command = "git status --short" } } }
local remote_text, remote_phase = routed(remote_args, { code = 0, stdout = " M lua/core/cli_view.lua\n?? notes.md\n" })
ok(has(remote_text, "\226\143\186 Remote openclaw \194\183 Bash(git status --short)"),
  "a routed remote call names the peer, the inner tool and its command: " .. remote_text)
ok(not has(remote_text, "name=remote") and not has(remote_text, "Tool_call") and not has(remote_text, "tool_call"),
  "and not the wrapper, in the heading or the status line")
ok(remote_phase == "Running bash", "the status line says what runs, not `tool_call`: " .. tostring(remote_phase))
ok(has(remote_text, "\226\142\191  M lua/core/cli_view.lua") and has(remote_text, "?? notes.md"),
  "the inner command's output is shown, as a direct bash call shows it")
ok(has(remote_text, "exit 0"), "with its exit code")

local failed_text = routed(remote_args, { code = 2, stdout = "", stderr = "fatal: not a git repository\n" })
ok(has(failed_text, "fatal: not a git repository") and has(failed_text, "exit 2"),
  "a remote command that fails shows its stderr and exit code")
ok(view_lib.outcome("tool_call", { code = 2 }, remote_args) == false, "and is judged a failure")

local error_text = routed(remote_args, { error = "remote_error", detail = "connection refused" })
ok(has(error_text, "remote_error: connection refused"), "an `{error}` result says why it failed: " .. error_text)
ok(view_lib.outcome("tool_call", { error = "unknown_node:x" }, remote_args) == false, "and is a failure")
ok(view_lib.outcome("tool_call", '{"error":"capability_not_granted"}', remote_args) == false,
  "even when the peer's error arrives as JSON text")

local local_text = routed({ name = "read", arguments = { path = "lua/core/agent.lua", offset = 10, limit = 5 } },
  { content = "a\nb\nc\n" })
ok(has(local_text, "Read(lua/core/agent.lua (lines 10-14))") and has(local_text, "3 lines"),
  "a routed local tool reads exactly as the direct one: " .. local_text)

-- `remote` called directly is unwrapped the same way.
local label, inside = view_lib.tool_title("remote", remote_args.arguments, 96)
ok(label == "Remote openclaw \194\183 Bash" and inside == "git status --short", "a direct remote names its inner call")
ok(view_lib.outcome("remote", { code = 1 }, remote_args.arguments) == false, "and judges it by its exit code")

-- Bounded: a long command is clipped in the heading, as a direct one is.
local long_label, long_inside = view_lib.tool_title("tool_call", { name = "remote", arguments = {
  node = "openclaw", capability = "bash", args = { command = string.rep("x", 400) } } }, 60)
ok(view_lib.columns(long_label .. "(" .. long_inside .. ")") <= 62 and has(long_inside, "\226\128\166"),
  "a long routed command is clipped to the line")

-- The batch form: each call and what it returned, one line each.
local batch_args = { calls = {
  { name = "read", arguments = { path = "a.lua" } },
  { name = "grep", arguments = { pattern = "TODO", path = "lua" } },
  { name = "read", arguments = { path = "missing.lua" } } } }
local batch_text = routed(batch_args, { ok = false, failed = 1, executed = 3, typed = true, serial = true, results = {
  { content = "1\n2\n" }, { count = 4 }, { error = "no such file" } } })
ok(has(batch_text, "Batch(Read(a.lua) \194\183 Search(pattern: \"TODO\", path: \"lua\") \194\183 Read(missing.lua))"),
  "a batch heading lists its calls: " .. batch_text)
ok(has(batch_text, "Read(a.lua) \226\134\146 2 lines") and has(batch_text, "4 matches")
  and has(batch_text, "Read(missing.lua) \226\134\146 failed: no such file"), "each call says what it returned")
ok(has(batch_text, "3 calls; 1 failed"), "and the batch counts its failures")
ok(view_lib.outcome("tool_call", { ok = true, failed = 0, results = { {}, {} } }, batch_args) == true,
  "a batch with no failures is a success")

-- `wa --continue` / `wa --resume <id>`: the stored thread is drawn again, in order, with the same
-- marks a live run uses - the reader's turn, commentary, the tool call and its result, the answer.
do
  local replay_view, replay_written = capture({ live = false, limit = 100 })
  replay_view:replay({
    { role = "user", content = "list the files" },
    { role = "assistant", content = "Looking first.", phase = "commentary", reasoning = "",
      tool_calls = '[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{\\"command\\":\\"ls\\"}"}}]' },
    { role = "tool", tool_call_id = "c1", tool_name = "bash", ok = 1, ms = 1200,
      content = '{"code":0,"stdout":"a.md\\nb.md\\n"}' },
    { role = "assistant", content = "Two files: a.md and b.md.", tool_calls = "[]", reasoning = "" },
  }, { skipped = 7 })
  local text = table.concat(replay_written)
  local function at(needle) return text:find(needle, 1, true) or 0 end
  ok(at("7 earlier messages") > 0, "a replay says how much it left out")
  ok(at("list the files") > 0 and at("Looking first.") > 0, "the reader's turn and the commentary are drawn")
  ok(at("a.md") > 0, "the tool's result is drawn")
  ok(at("Two files") > at("a.md") and at("a.md") > at("list the files"), "in the order they happened")
  ok(at("continued here") > at("Two files"), "and a rule marks where the new turns begin")
  -- A recorded `!command` comes back as the command and its output, never as raw tags.
  local bash_view, bash_written = capture({ live = false, limit = 100 })
  bash_view:replay({ { role = "user", phase = "bash",
    content = "<bash-input>git status</bash-input>\n<bash-stdout>clean tree</bash-stdout><bash-stderr></bash-stderr>" } })
  local drawn = table.concat(bash_written)
  ok(drawn:find("!git status", 1, true) and drawn:find("clean tree", 1, true), "a bash row is replayed as its command and output")
  ok(not drawn:find("<bash-input>", 1, true), "without its tags")
end

-- ---- session-status-content: between the text area and the session status bar ---------
-- The update notice used to compete with the session numbers on the status bar's own row; then it had
-- ONE line directly above the bar. Victor's 08/11 position spec puts it BELOW the CLI's text area and
-- ABOVE the session status bar (the window's order: textarea, notice, footer), never on the row above
-- the run-status line. A build in flight replaces the notice on that same line; an empty area takes no
-- line at all (no blank gap). The rust twin is `wa-term`'s editor (`session_row`, `session_content`),
-- tested in that crate.
do
  ok(view_lib.screen_rows(24).content == 22,
    "the framed screen keeps its session-status-content row on the output's last row: it has no box")
  ok(view_lib.screen_rows(12, true).session == 11 and view_lib.screen_rows(12, true).status == 5,
    "the boxed one draws it on the row under the box (11) and never on the run-status row (5)")
  -- The order Victor's spec asks for, spelled out on the row table: the text area (the box, from its top
  -- border down), then the notice line, then the session status bar on the last row. The run's own
  -- status line is above all three and is not where the notice goes.
  local box = view_lib.screen_rows(12, true)
  ok(box.session == box.footer - 1, "the notice line is the row directly above the session status bar")
  ok(box.session > box.status, "and below the run-status line, which stays above the box")
  ok(box.session >= box.input, "never above the text area: with no line to show, the box's own bottom"
    .. " border has that row")
  ok(box.status < box.input_top, "the run-status line stays above the box, where it was")
  ok(box.region < box.input_top, "so the output region ends above the whole bottom furniture")
  local notice = "Update available (cccccccccccc): run wa update or /update"
  -- A framed 24-row console, set up the way `prompt`/`paint` do it, with everything after the setup
  -- readable on its own.
  local function framed(extra)
    local options = { live = true, limit = 100, rows = function() return 24 end }
    for key, value in pairs(extra or {}) do options[key] = value end
    local view, written = capture(options)
    view:screen_on()
    return view, written, #written + 1
  end
  local function since(written, mark) return table.concat(written, "", mark) end

  -- (a) empty: no line, and the output region keeps the row.
  local quiet, quiet_written, quiet_mark = framed()
  eq(quiet:region_bottom(), 22, "(a) the output region keeps its last row")
  quiet:session_draw()
  eq(since(quiet_written, quiet_mark), "",
    "(a) with no notice nothing is drawn: no blank gap, and no empty frame to paint")

  -- (b) a notice: its own yellow line above the bar, the bar unchanged.
  local shown, shown_written, shown_mark = framed()
  shown.session_notice = notice
  shown:session_draw()
  local drawn = since(shown_written, shown_mark)
  ok(has(drawn, "\27[22;1H"), "(b) the notice is on its own row: directly above the status bar on 23")
  ok(has(drawn, view_lib.paint(notice, "warning", true)), "(b) in the warning yellow, the same sentence")
  ok(not has(drawn, "\27[23;1H"), "(b) and never on the status bar's row")
  eq(shown:region_bottom(), 21, "(b) and the line is reserved out of the output region")
  eq(visible(shown:session_line()), notice, "(b) the sentence itself is unchanged")
  -- The status bar keeps its own content: the notice never prefixes it.
  local footer_text
  local original_footer = host.editor_footer
  host.editor_footer = function(text) footer_text = text return true end
  local bar = view_lib.new({ live = true, stdout = true, limit = 100, out = function() end })
  bar.screen = view_lib.screen_rows(21, true)
  bar.editor, bar.editor_ready, bar.model = true, true, "m"
  bar.last_summary = "3 runs"
  bar.session_notice = notice
  bar:footer_draw()
  eq(footer_text, "3 runs", "(b) the status bar is its own content only, left-aligned as before")
  if original_footer == nil then host.editor_footer = nil else host.editor_footer = original_footer end

  -- (c) a build in flight replaces the notice on the same line.
  local loader = "\226\159\179 building wasm-agent \194\183 compiling serde"
  local built, built_written, built_mark = framed({ session_status = function() return { kind = "building", text = loader } end })
  built.session_notice = notice
  built:session_draw()
  local building_text = since(built_written, built_mark)
  ok(has(building_text, "building wasm-agent"), "(c) the build loader is the line")
  ok(not has(building_text, "Update available"), "(c) and the notice is gone from it, replaced")
  ok(has(building_text, "\27[22;1H"), "(c) on the same row")

  -- (d) a failed build shows the failure, then the notice comes back on that line.
  local failure = "\226\156\151 wasm-agent build failed (exit 101)"
  local failing, failing_written, failing_mark = framed({ session_status = function() return { kind = "failed", text = failure } end })
  failing.session_notice = notice
  failing:session_draw()
  ok(has(since(failing_written, failing_mark), "build failed (exit 101)"), "(d) a failed build is visible")
  local restored, restored_written, restored_mark = framed()
  restored.session_notice = notice
  restored:session_draw()
  ok(has(since(restored_written, restored_mark), view_lib.paint(notice, "warning", true)),
    "(d) and the notice is back afterwards, in yellow, on the same row")

  -- (e) width 40: exactly 40 columns, an ellipsis, never a wrap.
  local narrow = view_lib.new({ live = true, limit = 40, out = function() end })
  narrow.session_notice = notice
  local narrow_line = narrow:session_line()
  eq(view_lib.visible_columns(narrow_line), 40, "(e) a 40-column terminal gets exactly 40 columns")
  ok(has(visible(narrow_line), "\226\128\166"), "(e) truncated with an ellipsis")
  ok(not has(narrow_line, "\n"), "(e) one row, never wrapped")

  -- The boxed layout names the row itself: it is the row directly under the box, above the footer,
  -- and it does not move with the slash menu, the draft or the run's status line.
  local native = view_lib.new({ live = true, stdout = true, limit = 100, out = function() end })
  native.screen = view_lib.screen_rows(21, true)
  native.editor, native.editor_ready = true, true
  native.session_notice = notice
  eq(native:session_address(), "\27[20;1H", "idle with the native editor: the row under the box, above the bar")
  native.turn = { started = 0, baseline = {} }
  eq(native:session_address(), "\27[20;1H",
    "and the same row while a run is in flight: the run-status line is above the box, not here")

  -- Captured (non-TTY / NO_COLOR, i.e. not live): the same sentence as plain text, once.
  local plain, plain_written = capture({ live = false, limit = 100 })
  plain.session_notice = notice
  plain:paint()
  plain:paint()
  eq(table.concat(plain_written), notice .. "\n", "a captured transcript prints the line once, as plain text")
end


-- ---- a running tool call owns its own block, and never this row --------------------------------
-- Victor, 2026-11-10: "this bash description should be printed in the bash toolcall not at the
-- footer. that place belongs to update message and update launcher seeker, not info about tools,
-- which should be in the terminal content". The session-status-content row is the update notice's,
-- its loader's and its result's; a call's name, its clock and its newest output line are drawn
-- INSIDE that call's block, under its heading, rewritten in place while the host's ticker is the
-- only painter awake (`wa_term::transcript::Transcript::live`, pinned in that crate's own tests).
do
  local notice = "Update available (cccccccccccc): run wa update or /update"
  -- The host's transcript as a small model of the four calls the view makes: a block, a write, the
  -- live line, and the heading rewritten when the result lands. `live` follows the rules the view
  -- relies on: replace the row it already wrote, append it inside the current block otherwise, and
  -- let the next real write take it away.
  local function fake_transcript()
    local blocks = { { topic = false, lines = {} } }
    local api = { blocks = blocks }
    local function last() return blocks[#blocks] end
    api.block = function(topic)
      api.live_at = nil
      if #last().lines == 0 then last().topic = topic
      else blocks[#blocks + 1] = { topic = topic, lines = {} } end
      return true
    end
    api.write = function(text)
      -- The Rust rule the view relies on: the first real write takes the live row away, so a result
      -- never lands under a progress row that outlived its call.
      if api.live_at and last().lines[api.live_at] then table.remove(last().lines, api.live_at) end
      api.live_at = nil
      for line in (tostring(text):gsub("\n$", "") .. "\n"):gmatch("([^\n]*)\n") do
        last().lines[#last().lines + 1] = line
      end
      return true
    end
    api.live = function(text)
      local body = tostring(text or "")
      if body == "" then
        if api.live_at and last().lines[api.live_at] then table.remove(last().lines, api.live_at) end
        api.live_at = nil
        return true
      end
      if api.live_at and last().lines[api.live_at] then
        last().lines[api.live_at] = body
      else
        last().lines[#last().lines + 1] = body
        api.live_at = #last().lines
      end
      return true
    end
    api.head = function(text)
      if #last().lines == 0 then return false end
      last().lines[1] = tostring(text or "")
      return true
    end
    return api
  end
  local saved = { host.transcript_write, host.transcript_block, host.transcript_live, host.transcript_head }
  local fake = fake_transcript()
  host.transcript_block, host.transcript_write = fake.block, fake.write
  host.transcript_live, host.transcript_head = fake.live, fake.head
  local clock = { now = 1000 }
  local view = capture({ live = true, stdout = true, limit = 100, now = function() return clock.now end })
  view.screen = view_lib.screen_rows(24, true)
  view.editor, view.editor_ready = true, true
  view:event({ type = "tool", name = "bash", arguments = { command = "test-remote-call-shape" }, call_id = "c1" })
  local block = fake.blocks[#fake.blocks]
  eq(#fake.blocks, 1, "the call opens ONE block of its own, as it starts")
  eq(block and block.topic, true, "as a collapsible topic, like every tool call")
  eq(block and #block.lines, 1, "its first row is the heading, printed while the call runs")
  ok(has(visible(block and block.lines[1]), view_lib.DOT .. " Bash"), "the heading carries the step's dot")
  ok(has(visible(block and block.lines[1]), "test-remote-call-shape"), "and names what is running")
  eq(view:session_content(), nil, "a running call writes no session-status-content line")
  eq(view:session_line(), nil, "so the row is not drawn at all")
  -- The host ticker's sentence, written where the call's own block is: one row, replaced in place.
  fake.live("\u{27F3} bash \u{b7} 43s \u{b7} remote call shape ok")
  block = fake.blocks[#fake.blocks]
  eq(#fake.blocks, 1, "the progress line joins the call's own block, never a new one")
  eq(#block.lines, 2, "as one row under the heading")
  ok(has(visible(block.lines[2]), "43s"), "carrying the call's clock")
  fake.live("\u{27F3} bash \u{b7} 44s \u{b7} remote call shape ok")
  eq(#fake.blocks[#fake.blocks].lines, 2, "an update rewrites that row in place, never adding one")
  ok(has(visible(fake.blocks[#fake.blocks].lines[2]), "44s"), "with the newer sentence")
  eq(view:session_content(), nil, "and the row still says nothing: it is not the call's")
  -- A notice still owns the row while the call runs, untouched by it.
  view.session_notice = notice
  eq((view:session_content() or {}).text, notice, "the update notice owns the row, call or no call")
  eq(select(2, view:session_line()), "notice", "in its own kind: nothing about the call reaches it")
  view.session_notice = nil
  -- The result lands in the same block: the heading is rewritten (its dot says how it went), the live
  -- row goes with the first real write, and the output follows.
  clock.now = 1043
  view:event({ type = "tool_result", name = "bash",
    result = { code = 0, stdout = "remote call shape ok (59 checks, 0 skipped)\n" } })
  block = fake.blocks[1]
  eq(#fake.blocks, 2, "the result does not open a block of its own")
  ok(#fake.blocks[2].lines <= 1 and not has(visible(table.concat(fake.blocks[2].lines, "\n")), "Bash"),
    "the topic that follows carries nothing of the call")
  ok(has(visible(block.lines[1]), view_lib.DOT .. " Bash"), "the call's heading is rewritten, not printed twice")
  local shown = visible(table.concat(block.lines, "\n"))
  ok(has(shown, "59 checks"), "the result is what the block says now: " .. shown)
  ok(not has(shown, "\u{27F3}"), "and the live clock line is not left behind: " .. shown)
  eq(view:session_content(), nil, "and the row is still nobody's but the update's")
  -- A call whose result never arrives keeps the heading it already had: it is not printed twice.
  local orphan = fake_transcript()
  host.transcript_block, host.transcript_write = orphan.block, orphan.write
  host.transcript_live, host.transcript_head = orphan.live, orphan.head
  local second = capture({ live = true, stdout = true, limit = 100, now = function() return 2000 end })
  second.screen = view_lib.screen_rows(24, true)
  second.editor, second.editor_ready = true, true
  second:event({ type = "tool", name = "bash", arguments = { command = "sleep 600" }, call_id = "c2" })
  orphan.live("\u{27F3} bash \u{b7} 5m01s \u{b7} no output for 3m")
  second:flush_call()
  eq(#orphan.blocks, 1, "a call with no result keeps its one block")
  eq(#orphan.blocks[1].lines, 1, "and its heading is not printed a second time")
  -- The plain layout has no host transcript to hold a live row: the heading keeps the old order.
  host.transcript_block, host.transcript_write = saved[2], saved[1]
  host.transcript_live, host.transcript_head = saved[3], saved[4]
  local plain, plain_written = capture({ live = false, limit = 100 })
  plain:event({ type = "tool", name = "bash", arguments = { command = "echo hi" } })
  plain:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = "hi\n" } })
  ok(has(table.concat(plain_written), "Bash"), "a captured transcript still prints the call")
  eq(plain:session_content(), nil, "and its row says nothing about it either")
  host.transcript_write, host.transcript_block = saved[1], saved[2]
  host.transcript_live, host.transcript_head = saved[3], saved[4]
end

if failed > 0 then
  print(string.format("cli view: %d failed of %d checks", failed, checks))
  os.exit(1)
end
print(string.format("cli view ok (%d checks)", checks))
