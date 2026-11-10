-- The CLI's long-call row: `lua/core/tool_progress.lua`, and the row it shares with the update notice
-- and the build loader (`lua/core/cli_view.lua`, docs/TOOL-PROGRESS.md).
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-tool-progress.lua wa --db <scratch>/t.db
--
-- No model, no node, no network: a clock the test controls, a tail fed by hand, and one live-file
-- fixture written into this run's own scratch home. What is pinned here:
--
--   * the row's exact wording, which `rust/wa-tool-progress` produces too - the two implementations
--     must agree or the CLI and the native editor show different sentences for the same call;
--   * each dialect (cargo's bar and count, npm/pnpm, pip, git) and the generic last-line fallback;
--   * the two-second gate and the three-minute stall hint;
--   * one line, always: no newline, no escape sequence, no control character, and no secret;
--   * the live file (the host's own tail) is preferred while it is fresh, and a stale or finished one
--     shows nothing;
--   * the row's precedence: a build loader wins, then the standing notice, then this.
local tp = dofile('lua/core/tool_progress.lua')
local view_lib = dofile('lua/core/cli_view.lua')

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
end

-- ---- the clock and the bar: the Rust crate's own strings ---------------------

eq(tp.elapsed(45), "45s", "a short clock is seconds")
eq(tp.elapsed(125), "2m05s", "a long one is minutes and seconds")
eq(tp.elapsed(3720), "1h02m", "a very long one is hours and minutes")
eq(tp.compact(180), "3m", "the stall hint drops a zero seconds part")
eq(tp.compact(200), "3m20s", "and keeps the seconds when they matter")
eq(tp.stall(180), "no output for 3m", "the hint's wording")
eq(tp.bar(0), "\u{2595}" .. string.rep("\u{2591}", 14) .. "\u{258F}", "an empty bar is the build loader's")
eq(tp.bar(1), "\u{2595}" .. string.rep("\u{2588}", 14) .. "\u{258F}", "a full one too")
eq(tp.bar(2), tp.bar(1), "a fraction past one is clamped")
eq(tp.printable("\27[32mCompiling\27[0m serde \7\8\tx"), "Compiling serde  x",
  "ANSI, control characters and a tab never reach the row")

-- ---- the dialects ------------------------------------------------------------

local function detail(line) return tp.dialect(line) end
local cargo = detail("    Building [=============>         ] 143/412: serde_json, syn, proc-macro2")
eq(cargo and cargo.kind, "bar", "cargo's Building line is a bar")
eq(cargo and cargo.done, 143, "with the count done")
eq(cargo and cargo.total, 412, "and the count total")
eq(cargo and cargo.label, "building serde_json", "and the first crate it names")
eq((detail("   Compiling wasmtime v50.0.0") or {}).text, "compiling wasmtime", "a bare Compiling line is text")
eq((detail("    Finished `test` profile [unoptimized] target(s) in 4m12s") or {}).text,
  "finished in 4m12s", "so is Finished")
eq((detail("Progress: resolved 143, reused 120, downloaded 23, added 0") or {}).text,
  "resolved 143 packages", "pnpm's Progress line is its own dialect")
eq((detail("\u{2e28}#####\u{2e29} \u{280b} reify:lodash: timing build:queue Completed in 12ms") or {}).text,
  "reify:lodash", "npm's reify step names itself")
local pip = detail("  45%|\u{2588}\u{2588}\u{2588}\u{2588}\u{258c}      | 45.0/100.0 [00:03<00:04, 12.3MB/s]")
eq(pip and pip.kind, "bar", "pip's own bar is a bar")
eq(pip and pip.done, 45, "45 of 100, not 0 of 100 (the decimal is the fraction of a step)")
eq(pip and pip.total, 100, "the total is the integer part")
eq((detail("Downloading numpy-1.26.0-cp311.whl (15.8 MB)") or {}).text,
  "downloading numpy-1.26.0-cp311.whl (15.8 MB)", "pip's download line is text")
local git = detail("Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s")
eq(git and git.kind, "bar", "git's Receiving objects is a bar")
eq(git and git.done, 450, "with the object count")
eq(git and git.total, 1000, "out of the total")
eq(git and git.label, "receiving objects", "labelled with what it is doing")
eq((detail("Resolving deltas:  12% (120/1000)") or {}).done, 120, "and so is Resolving deltas")
eq((detail("Cloning into 'wasm-agent'...") or {}).text, "cloning into 'wasm-agent'...", "a clone says so")
local generic = tp.detail({ "warning: unused import", "test result: ok. 41 passed" }) or {}
eq(generic.kind, "text", "no dialect: the last line is the answer")
eq(generic.text, "test result: ok. 41 passed", "and it is the line, unchanged")
eq(tp.detail({}), nil, "no output at all: no detail")
-- A finished build's bar does not speak for the test run that follows it: only the newest four lines
-- may claim a dialect (`M.RECENT`, `wa-tool-progress`'s `RECENT`).
local finished = { "    Building [=============>         ] 143/412: serde_json, syn",
  "     Running unittests src/lib.rs", "running 41 tests", "test a::one ... ok",
  "test result: ok. 41 passed; 0 failed; 0 ignored" }
local tail_detail = tp.detail(finished) or {}
eq(tail_detail.text, "test result: ok. 41 passed; 0 failed; 0 ignored",
  "four ordinary lines after a bar: the last line is the row")
local interleaved = tp.detail({ finished[1], finished[2], finished[3] }) or {}
eq(interleaved.kind, "bar", "and inside the window the bar is still the row")

-- ---- the row ------------------------------------------------------------------

eq(tp.row_text("bash", 190, { kind = "bar", label = "building serde_json", done = 143, total = 412 },
  1), "\u{27F3} bash \u{00B7} 3m10s " .. tp.bar(143 / 412) .. " 143/412 building serde_json",
  "a bar row: the tool, the clock, the bar, the count, the label")
eq(tp.row_text("bash", 41, { kind = "text", text = "test result: ok. 41 passed" }, 0),
  "\u{27F3} bash \u{00B7} 41s \u{00B7} test result: ok. 41 passed", "a text row: the last line")
eq(tp.row_text("bash", 260, { kind = "text", text = "compiling x" }, 180),
  "\u{27F3} bash \u{00B7} 4m20s \u{00B7} no output for 3m", "a stalled row replaces the detail with the hint")
eq(tp.row_text("bash", 12, nil, 0), "\u{27F3} bash \u{00B7} 12s", "no detail: the tool and the clock only")

-- ---- a call in flight -----------------------------------------------------------

tp.reset()
tp.reset_live()
ok(tp.status({ now = 1000 }) == nil, "nothing running: no row")
tp.begin("bash", 1000)
ok(tp.status({ now = 1000 }) == nil, "just started: the status line is enough")
ok(tp.status({ now = 1001 }) == nil, "still under two seconds")
ok(tp.status({ now = 1002 }) ~= nil, "two seconds is long enough to say something")
tp.observe("   Compiling serde_json v1.0.0\n", 1001)
tp.observe("    Building [=============>         ] 143/412: serde_json, syn\n", 1190)
local status = tp.status({ now = 1190 })
eq(status and status.kind, "tool", "a live call is the `tool` kind (the border accent)")
eq(status and status.text, "\u{27F3} bash \u{00B7} 3m10s " .. tp.bar(143 / 412) .. " 143/412 building serde_json",
  "and the row the Rust crate would draw for the same tail")
ok(not tostring(status and status.text):find("\n", 1, true), "one line, never a wrapped one")

-- A carriage-return bar: the newest rewrite wins, because that is the whole point of one.
tp.begin("bash", 0)
tp.observe("Receiving objects:  10% (100/1000)\rReceiving objects:  20% (200/1000)\r", 1)
eq((tp.status({ now = 3 }) or {}).text, "\u{27F3} bash \u{00B7} 3s " .. tp.bar(0.2) .. " 200/1000 receiving objects",
  "a bar that rewrites itself in place is one line of progress, not ten")

-- The stall hint, and the detail coming back when output does.
tp.begin("bash", 0)
tp.observe("Compiling x\n", 1)
local quiet = tp.status({ now = 1 + 179 })
ok(quiet and quiet.kind == "tool", "179 s of silence is not a stall yet")
local stalled = tp.status({ now = 1 + 180 })
eq(stalled and stalled.kind, "stall", "180 s is: the row is the `stall` kind (dim)")
eq(stalled and stalled.text, "\u{27F3} bash \u{00B7} 3m01s \u{00B7} no output for 3m", "and says so")
tp.observe("Compiling y\n", 300)
eq((tp.status({ now = 300 }) or {}).kind, "tool", "new output clears the hint")
-- A command that never wrote anything counts from its start.
tp.begin("bash", 0)
eq((tp.status({ now = 200 }) or {}).text, "\u{27F3} bash \u{00B7} 3m20s \u{00B7} no output for 3m20s",
  "silence is counted from the start when there was never any output")

-- ---- no secret reaches the line --------------------------------------------------

tp.begin("bash", 0)
tp.observe("curl -H 'authorization: Bearer sk-live-9f2a4c1d8b7e6f50' https://api\n", 1)
local secret_row = (tp.status({ now = 5 }) or {}).text or ""
ok(not secret_row:find("sk-live-9f2a4c1d8b7e6f50", 1, true), "a key-shaped value is masked: " .. secret_row)
ok(secret_row:find("<redacted>", 1, true) ~= nil or secret_row:find("sk-...", 1, true) ~= nil,
  "the row says it was redacted")
-- A value the caller already knows about (the vault's, a value just read) is masked by exact value:
-- the same policy `redact.secrets` applies to the node's own configured secrets.
tp.begin("bash", 0)
tp.observe("export API_KEY=abcdefgh12345678\n", 1)
local named = (tp.status({ now = 5, secrets = { "abcdefgh12345678" } }) or {}).text or ""
ok(not named:find("abcdefgh12345678", 1, true), "a known value is masked too: " .. named)
ok(named:find("<redacted>", 1, true) ~= nil, "and the row says so: " .. named)
tp.finish()
ok(tp.status({ now = 5 }) == nil, "a finished call has no row")

-- ---- the live file the host writes ------------------------------------------------

local path = tp.path()
ok(type(path) == 'string' and path:sub(-18) == "tool-progress.json", "the file has the host's name: " .. tostring(path))
local function publish(facts)
  local wrote, problem = pcall(host.write_file, path, dofile('lua/vendor/json.lua').encode(facts))
  ok(wrote, "the fixture was written: " .. tostring(problem))
  tp.reset_live()
end
local now = 1000
publish({ state = "running", tool = "bash", started_at = now - 190, at = now, last_output_at = now - 1,
  detail = { kind = "bar", label = "building serde_json", done = 143, total = 412, percent = false } })
local from_file = tp.status({ now = now })
eq(from_file and from_file.text, "\u{27F3} bash \u{00B7} 3m10s " .. tp.bar(143 / 412) .. " 143/412 building serde_json",
  "the host's tail is the row, with no call in this process")
ok(tp.active() == nil, "and it is the file that answered, not a local call")
publish({ state = "running", tool = "bash", started_at = now - 190, at = now - 20, last_output_at = now - 190 })
ok(tp.status({ now = now }) == nil, "a file that stopped moving is a dead node, not a running call")
publish({ state = "done", at = now })
ok(tp.status({ now = now }) == nil, "a finished call's file says nothing")
publish({ state = "running", tool = "bash", started_at = now - 1, at = now, last_output_at = now })
ok(tp.status({ now = now }) == nil, "and a call under two seconds has no row either")
publish({ state = "running", tool = "bash", started_at = now - 400, at = now, last_output_at = now - 400 })
eq((tp.status({ now = now }) or {}).text, "\u{27F3} bash \u{00B7} 6m40s \u{00B7} no output for 6m40s",
  "the stall rule applies to the host's file too")

-- ---- the session-status-content row is the update's, never a tool's -----------------
-- Victor, 2026-11-10: "this bash description should be printed in the bash toolcall not at the
-- footer. that place belongs to update message and update launcher seeker, not info about tools,
-- which should be in the terminal content". A running call's sentence - the tool, its clock, the
-- newest line of its output - is drawn INSIDE that call's block in the transcript
-- (`lua/core/cli_view.lua` `METHODS:tool_live`, `wa_term::transcript::Transcript::live`); this row
-- is the update notice's, its loader's and its result's. The module still decides the wording, so
-- the wording is asserted here, and nothing about it is asked of the row.

local function view_with(module)
  local clock = { now = 1000 }
  local view = view_lib.new({ live = false, out = function() end, now = function() return clock.now end,
    limit = 80, rows = function() return 24 end })
  view.tool_progress = module
  return view, clock
end

tp.reset()
tp.reset_live()
tp.begin("bash", 1000)
tp.observe("Building [=====> ] 143/412: serde_json, syn\n", 1190)
local view, clock = view_with(tp)
clock.now = 1190
-- The sentence the call's own block draws: the same words, the same bar, one row.
local sentence = tp.status({ now = clock.now, limit = 80 }) or {}
ok(sentence.text and sentence.text:find(tp.bar(143 / 412), 1, true) ~= nil,
  "the call's own line still decides the bar and the count")
ok(sentence.text and not sentence.text:find("\n", 1, true), "on one row, never a wrapped one")
-- And the row above the status bar says nothing about it.
eq(view:session_content(), nil, "a call in flight writes no session-status-content line")
eq(view:session_line(), nil, "so the row is not drawn at all")
eq(view_lib.session_role("notice"), "warning", "the notice keeps its yellow")
ok(view_lib.session_role("tool") ~= "borderAccent" and view_lib.session_role("stall") ~= "dim",
  "and there is no row role for a tool: it has no kind on this row")

-- The notice owns the row, and a loader outranks the notice - the same precedence as before, with
-- the call no longer among the claimants.
view.session_notice = "Update available (cccccccccccc): run wa update or /update"
eq((view:session_content() or {}).text, "Update available (cccccccccccc): run wa update or /update",
  "the update notice owns the row")
view.session_status = function() return { text = "\u{27F3} building wasm-agent compiling serde", kind = "building" } end
eq((view:session_content() or {}).kind, "building", "and a build loader replaces it")
view.session_status = nil
view.session_notice = nil
eq(view:session_content(), nil, "with both gone the row is empty, never the call's")
-- The width is the block's business, not the module's: the sentence is one row here (asserted
-- above) and the transcript wraps it to whatever the terminal is. What the module must never do is
-- hand out more than one line, or an escape sequence of its own.
local wide = tp.status({ now = clock.now, limit = 30 }) or {}
ok(wide.text and not wide.text:find("\27", 1, true), "no escape sequence in the sentence: " .. tostring(wide.text))
tp.finish()
eq(view:session_content(), nil, "the call ends: the row stays the update's, empty")

print(string.format("%d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
