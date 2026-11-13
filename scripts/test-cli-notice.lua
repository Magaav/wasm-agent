-- #106: "Update available (...)" is the session-status-content line's sentence, and it appears ONCE.
--
-- Reported twice by the operator (09/11, and again 11/11: "at CLI start ... the footer notice ...
-- also lands in the transcript under the welcome block"). The earlier fix moved the notice into the
-- row above the session status bar and left the `print` behind it, so the reader got the same
-- sentence in two places - and the transcript copy is the worse one: it becomes part of the chat,
-- it scrolls away with it, and it reads like something the agent said rather than something the
-- node is telling the reader.
--
-- Two halves, because the bug has two faces:
--
--   (a) from OUTSIDE the process: a real `wa chat` on a terminal, started behind a release that is
--       behind. The transcript (`stdout`) must carry no notice. This is the operator's own
--       observation, and it goes red on the tree before the fix (`print`). The terminal is not a
--       detail: a stdin that is not a tty is a scripted run (`docs/SCRIPTED-RUNS.md`), which prints
--       no banner and checks for no update, so this half runs the child behind a pseudo-terminal.
--   (b) from INSIDE the process: the same start decision against a live, terminal-shaped view -
--       the transcript receives nothing and the notice is the line the session-status-content row
--       draws. That is the half (a) cannot see, because a pty's captured screen is not a row.
--
--   WASM_AGENT_LUA_ROOT=$PWD WA_SCRIPT=scripts/test-cli-notice.lua wa --db <scratch>/t.db
--
-- No network: the published side is a fixture feed (`WA_UPDATE_CHECK_FIXTURE`) and the installed side
-- is a written `installed.txt`. The scratch is its own (`mktemp -d`, marked, removed only while the
-- marker is this run's), and the child gets its own home inside it, so nothing here can read - or
-- write - the operator's node.
local json = dofile("lua/vendor/json.lua")
local chat = dofile("lua/core/chat.lua")
local cli_view = dofile("lua/core/cli_view.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end

-- ---- the scratch ----------------------------------------------------------------------------------
local function shell(command, cwd)
  local ran, raw = pcall(host.exec, command, cwd or "", 90)
  if not ran or type(raw) ~= "string" then return { code = -1, stdout = "", stderr = tostring(raw) } end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return { code = -1, stdout = raw, stderr = "" } end
  return { code = tonumber(decoded.code) or -1, stdout = tostring(decoded.stdout or ""),
    stderr = tostring(decoded.stderr or "") }
end
local scratch = (shell("mktemp -d 2>/dev/null || mktemp -d -t wa-cli-notice")).stdout:gsub("%s+$", "")
assert(scratch ~= "", "cli notice: could not create a scratch directory; refusing to run without its own")
local marker = scratch .. "/.wa-test-scratch"
local token = tostring(host.uuid and host.uuid() or (host.now and host.now() or ""))
assert(host.write_file(marker, "test-cli-notice " .. token .. "\n"), "cli notice: could not mark its own scratch")
local function cleanup()
  local read_ok, text = pcall(host.read_file, marker)
  if not read_ok or type(text) ~= "string" or not text:find(token, 1, true) then return end
  if dofile("lua/core/path_guard.lua").command("rm -rf '" .. scratch .. "'") then
    pcall(host.exec, "rm -rf '" .. scratch .. "'", "", 30)
  end
end

-- The published side: two node releases this machine can install, the newer one first, exactly as
-- `scripts/test-update-banner.lua` writes that fixture. The installed side is a *prebuilt* record
-- whose release has fallen out of the window, which is the one "behind" a fixture can prove without
-- a network, a git ancestry or a specific commit in this repository.
local TARGET = "x86_64-unknown-linux-gnu"
local function release(sha)
  return '{"tag_name":"node-' .. sha .. '","name":"node-' .. sha .. '",'
    .. '"html_url":"https://example.invalid/' .. sha:sub(1, 4) .. '",'
    .. '"published_at":"2026-11-06T10:00:00Z","draft":false,"assets":['
    .. '{"name":"node-' .. sha .. '.manifest"},'
    .. '{"name":"wa-' .. TARGET .. '-' .. sha .. '"},'
    .. '{"name":"wa-sentinel-' .. TARGET .. '-' .. sha .. '"}]}'
end
local feed = scratch .. "/feed.json"
assert(host.write_file(feed, "[" .. release("cccccccccccc") .. "," .. release("aaaaaaabbbbb") .. "]"),
  "cli notice: could not write the release fixture")
local install = scratch .. "/install"
assert(shell("mkdir -p '" .. install .. "' '" .. scratch .. "/home'").code == 0, "cli notice: mkdir")
assert(host.write_file(install .. "/installed.txt",
  "commit=1111111111111111111111111111111111111111\nbranch=main\ndirty=0\n"
  .. "binary_source=prebuilt-release\nbinary_release=node-111111111111\nvia=deploy.sh\n"),
  "cli notice: could not write the install record")

local NOTICE = "Update available (cccccccccccc): run wa update or /update"

-- ---- (a) a real `wa chat`, from outside ----------------------------------------------------------
-- The child is run from the scratch directory rather than from the tree: `update.lua`'s "buildable
-- tree" channel answers from the local checkout, and this test is about the *release* notice, so the
-- tree channel must not answer first (a tree commit this repository does not contain is `unknown`).
local function binary()
  -- A list with an explicit index, never `#list + 1`: an unset variable is a nil in the middle of the
  -- list, `#` over nil holes is unspecified, and measured 13/11 that made this row SKIP while FAST_BIN
  -- was set and executable - the one candidate the fast path hands it - because the three nil slots
  -- collapsed and the path landed at index 1 only when the first slot was not nil. A lost candidate is
  -- a row that reports less coverage than it has.
  local candidates, count = {}, 0
  local function add(value)
    if type(value) == "string" and value ~= "" then count = count + 1; candidates[count] = value end
  end
  add(host.getenv("WA_BIN"))
  add(host.getenv("WA_TEST_BIN"))
  add(host.getenv("FAST_BIN"))
  add(shell("command -v wa").stdout:gsub("%s+$", ""))
  add((host.getenv("HOME") or "") .. "/.local/bin/wa")
  add((host.getenv("WASM_AGENT_LUA_ROOT") or "") .. "/rust/target/release/wa")
  for _, candidate in ipairs(candidates) do
    if candidate and candidate ~= "" and shell("test -x '" .. candidate .. "'").code == 0 then return candidate end
  end
  return nil
end
local bin = binary()
if not bin then
  print("SKIP cli notice: no wa binary (WA_BIN/WA_TEST_BIN/FAST_BIN, PATH, ~/.local/bin, rust/target/release)")
else
  -- `-u WA_SCRIPT`: the fast path hands every row a script to run, and a child that inherited it
  -- would run this very test instead of starting a chat (measured: a 120 s recursion).
  -- `WASM_AGENT_LUA_ROOT` is passed on purpose: the child must read THIS tree's `chat.lua`, which is
  -- the file under test, not the binary's embedded copy.
  local root = host.getenv("WASM_AGENT_LUA_ROOT") or ""
  local env = "WASM_AGENT_HOME='" .. scratch .. "/home' WA_INSTALL_DIR='" .. install
    .. "' WA_UPDATE_CHECK_FIXTURE='" .. feed .. "' WA_UPDATE_CHECK_CACHE='" .. scratch .. "/cache.json'"
    .. " WASM_AGENT_LUA_ROOT='" .. root .. "'"
  -- The child's command, in a file rather than nested in the pty tool's own quoting: the tool below is
  -- handed one string, and `sh -c '<cmd>'` inside a Lua string inside a shell string is where a test
  -- like this stops being readable. The scratch is this run's (marked), so the file goes with it.
  local child_sh = scratch .. "/child.sh"
  assert(host.write_file(child_sh,
    "#!/bin/sh\nexec env -u WA_SCRIPT -u WA_FAST_ROW_ENV " .. env .. " '" .. bin .. "' chat\n"),
    "cli notice: could not write the child's command")
  shell("chmod +x '" .. child_sh .. "'")
  -- A READER'S START IS A TERMINAL, and #107 made that load-bearing: a stdin that is not a tty is a
  -- SCRIPTED run - no banner, no prompt row and no update check (docs/SCRIPTED-RUNS.md). So piping
  -- `/exit` into the child stopped being the start this half is about, and its witness with it
  -- (measured: no banner, and `/exit` answered with a model turn instead of exiting). The child is
  -- given a pseudo-terminal instead: util-linux `script -qefc "<cmd>" /dev/null`, which also returns
  -- the child's exit code; BSD/macOS `script -q /dev/null sh -c "<cmd>"`, which does not - there the
  -- two content assertions carry the meaning, not the code. `stty rows 24 cols 80` first: a reader
  -- has a terminal with a size, and a pty a parent pipe created has none. Where no pty tool exists
  -- this half is a NAMED SKIP, never a pass.
  local function pty(command)
    if shell("command -v script >/dev/null 2>&1").code ~= 0 then return nil end
    -- util-linux answers `--version`; BSD/macOS `script` has no such option and prints its usage.
    if shell("script --version 2>&1").stdout:find("util%-linux") then
      return "script -qefc \"stty rows 24 cols 80 2>/dev/null; exec '" .. command .. "'\" /dev/null"
    end
    return "script -q /dev/null sh -c \"stty rows 24 cols 80 2>/dev/null; exec '" .. command .. "'\""
  end
  local on_a_terminal = pty(child_sh)
  if not on_a_terminal then
    print("SKIP cli notice: no pty tool (`script`) to give the child a terminal, so the "
      .. "outside-the-process half cannot start an interactive CLI here")
  else
    local child = shell("printf '/exit\\n' | timeout 60 " .. on_a_terminal .. " 2>&1", scratch)
    ok(child.code == 0, "a `wa chat` on a terminal starts and exits cleanly (code "
      .. tostring(child.code) .. ")")
    -- The banner is the interactive start itself: a scripted run prints none, so this assertion is
    -- also what says the child above really was given a terminal.
    ok(has(child.stdout, "Welcome to wasm-agent"), "and it is the CLI's own transcript: "
      .. child.stdout:sub(1, 120))
    -- Not vacuous: the fixture and the record the child was given really do compare as "behind", read
    -- through the same two decisions the check makes (`fetch` then `compare`). Without this, a
    -- transcript with no notice could just be a fixture that never fired.
    local banner = dofile("lua/core/update_banner.lua")
    local list, reason, transport = banner.fetch({ fixture = feed })
    ok(reason == nil and type(list) == "table" and #list == 2,
      "the fixture feed parses (" .. tostring(reason) .. " via " .. tostring(transport) .. ")")
    local prebuilt = banner.identity({ commit = string.rep("1", 40), binary_source = "prebuilt-release",
      binary_release = "node-111111111111" })
    ok(prebuilt ~= nil and banner.compare(prebuilt, list, nil, true) == "older",
      "and the install record the child was given is behind it, so a notice really was due")
    ok(string.format(banner.LINE, list[1].sha12) == NOTICE, "in the sentence the test then looks for")
    -- The bug, from outside the process: on the tree before #106 this line was a `print`, and it
    -- appears in the capture (`Update available (cccccccccccc): run wa update or /update`). After it,
    -- the notice is the footer's session row and nothing of it reaches the transcript.
    ok(not has(child.stdout, "Update available"), "the started CLI prints no notice into its transcript")
    ok(not has(child.stdout, "run wa update or /update"), "in either wording: nothing about an update")
  end
end

-- ---- (b) the same decision, on a live view -------------------------------------------------------
-- A view built the way `wa chat` builds one: live, a terminal it owns, a host editor, and the host
-- transcript for its output. Everything the view is handed is recorded, so "the notice is not in the
-- transcript" is a fact about what was written, not about what happened to be visible.
local function recorded()
  local calls = {}
  return calls, function(text) calls[#calls + 1] = text end
end
local function live_view()
  local calls, out = recorded()
  local view = cli_view.new({ out = out, live = true, limit = 100, rows = function() return 30 end })
  local real_editor = host.input_editor
  host.input_editor = function() return true end
  view.editor = true
  view:prompt("wa> ")
  host.input_editor = real_editor
  return view, calls
end
local function joined(calls) return table.concat(calls, "") end

do
  local view, calls = live_view()
  local transcript_calls = {}
  local real_write = host.transcript_write
  host.transcript_write = function(text) transcript_calls[#transcript_calls + 1] = text; return true end
  local mark = #calls + 1
  local line = chat.start_notice(view, {
    banner = { check = function() return { state = "behind", line = NOTICE } end,
      session_content = function() return nil end },
  })
  host.transcript_write = real_write
  ok(line == NOTICE, "the start decision answers the notice line: " .. tostring(line))
  ok(view.session_notice == NOTICE, "and it is the session-status-content line's text")
  ok(#transcript_calls == 0, "the transcript received nothing: " .. table.concat(transcript_calls, "|"))
  -- The row itself: drawn on the row `screen_rows` calls the session-status-content row, in the
  -- warning yellow, exactly as the footer's own render tests say (`scripts/test-cli-view.lua`).
  local drawn = joined({ table.concat(calls, "", mark) })
  local row = view.screen and (view.screen.session or view.screen.content) or nil
  ok(row ~= nil and has(drawn, "\27[" .. tostring(row) .. ";1H"),
    "it is drawn on the session-status-content row (" .. tostring(row) .. ")")
  ok(has(drawn, cli_view.paint(NOTICE, "warning", true)), "in the warning yellow, the same sentence")
  ok(not has(drawn, "\27[" .. tostring(view.screen and view.screen.status) .. ";1H" .. NOTICE),
    "and never on the run-status row")
  ok(view:session_content().text == NOTICE, "the row's content resolves to the notice")
end

-- The second producer, unchanged in what it decides and changed in where it says it: an install that
-- records a version tag instead of a published release gets the same one line, in the same one row.
do
  local view, calls = live_view()
  local mark = #calls + 1
  local released = "update available: installed v0.1.0 is behind v0.2.0 - /update installs it"
  local line = chat.start_notice(view, {
    banner = { check = function() return { state = "unknown", reason = "installed_not_in_release_feed" } end,
      session_content = function() return nil end },
    released = { state = "behind", message = "installed v0.1.0 is behind v0.2.0" },
  })
  ok(line == released, "the release feed's notice is the same one line: " .. tostring(line))
  ok(view.session_notice == released, "and it is the footer's, not the transcript's")
  ok(has(table.concat(calls, "", mark), released), "drawn on the row")
end

-- `WA_SKIP_UPDATE_CHECK` is still the one switch that turns the whole check off.
do
  local view = live_view()
  local real_getenv = host.getenv
  host.getenv = function(name)
    if name == "WA_SKIP_UPDATE_CHECK" then return "1" end
    return real_getenv(name)
  end
  local line = chat.start_notice(view, { seen = { state = "behind", line = NOTICE } })
  host.getenv = real_getenv
  ok(line == nil and view.session_notice == nil, "a skipped check draws no line at all")
end

cleanup()
if failed > 0 then
  print(string.format("cli notice: %d of %d checks failed", failed, checks))
  os.exit(1)
end
print(string.format("cli notice ok: %d checks", checks))
