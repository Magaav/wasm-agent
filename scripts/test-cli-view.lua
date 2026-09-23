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
ok(has(live.text(), "\r\27[2K"), "the status line is rewritten in place, not printed again")
ok(has(live.text(), view_lib.spinner(0)), "the status line carries a spinner")
ok(has(live.text(), "Thinking \194\183 12.0s"), "the status line says what and for how long")
clock.value = 20
live_view:event({ type = "tool", name = "bash", arguments = { command = "echo hi" }, timeout_ms = 300000 })
ok(has(live.text(), "Running bash"), "a call in flight is named in the status line")
ok(has(live.text(), "of 5m00s"), "and the deadline it is running against is visible")
clock.value = 21
live_view:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = "hi\n" } })
ok(has(live.text(), "1.0s"), "a step reports how long it took")
ok(has(live.text(), "\27[32mok"), "success is marked as success")
local before_answer = #live.text()
live_view:event({ type = "tool", name = "read", arguments = { path = "ui/app.js" } })
live_view:event({ type = "tool_result", name = "read", result = { error = "no such file" } })
ok(has(live.text(), "\27[31mfailed"), "a failed call is marked as failed, with its reason")
ok(has(live.text(), "no such file"), "and the reason is shown")
clock.value = 30
live_view:event({ type = "usage", total = { prompt = 1200, completion = 800, cached = 1100, cost = 0.0021 },
  prompt = 45000 })
live_view:answered("done: one command ran.")
local live_text = live.text()
ok(#live_text > before_answer, "the run kept writing after the first call")
ok(has(live_text, "done: one command ran."), "the answer is printed")
ok(select(2, live_text:gsub("done: one command ran%.", "")) == 1, "and printed once")
ok(has(live_text, "\27[2m"), "the footer is dimmed rather than shouted")
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

if failed > 0 then
  print(string.format("cli view: %d failed of %d checks", failed, checks))
  os.exit(1)
end
print(string.format("cli view ok (%d checks)", checks))
