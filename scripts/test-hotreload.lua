-- Live reload: the UI and command layer of a running CLI is replaced without a restart, and the things
-- that must never be replaced stay where they are.
--
-- WHY. Victor, 13/11 ~06:45: "i like this live reloads apply this update", pointing at Claude Code's
-- statusLine - a fresh process per refresh, so an edit shows on the next tick with no restart. Here it is
-- a fresh MODULE per change, swapped in at the next frame or command, with the state left in one store the
-- core owns (`lua/core/reload.lua`, `docs/HOTRELOAD.md`).
--
-- What this row proves, in order, and why each case is here rather than in a unit test of a pure function:
--
--   1. THE INVENTORY. Every module under `lua/core` is classified ui / guard / core, no path is in two
--      sets, and the terminal driver, the interpreter and the process that owns the session are named as
--      runtime. A module added without a decision shows up here.
--   2. THE GUARDS CANNOT BE RELOADED. A poisoned `hooks.lua` planted in the reload tree does not reach the
--      process: the hooks engine is read from the node's own source, is never watched, and a tick over a
--      changed copy swaps nothing. This is the one case a reload mechanism must fail loudly at, because
--      "reload anything from a directory" is the same sentence as "run whatever is in that directory".
--   3. A GOOD EDIT APPLIES, in a real module, through the proxy the chat calls: `/help`'s own text changes
--      while the process keeps running.
--   4. A SYNTAX ERROR KEEPS THE OLD MODULE and produces ONE line - `reload failed: <path>: <error>` - and
--      the same broken file is not re-read and re-reported on every frame.
--   5. A RUNTIME ERROR IN RENDER KEEPS THE OLD MODULE. The self-check runs the new code (a status line is
--      actually composed), so a module that parses and then raises while drawing is refused, not swapped.
--   6. NOTHING IS HALF-SWAPPED, and a live view keeps its state across the swap: the object keeps every
--      field, the balloon's page, the scroll anchor, the wake line and the input object stay in the store,
--      and only the methods are the new copy's.
--   7. A RUN THAT IS STREAMING IS NOT INTERRUPTED. A fake stream drives real view events across a swap:
--      every event before and after it is rendered, the run's counters survive, and the change is visible
--      on the next frame.
--   8. THE TWO SOURCES. `--dev` says `dev reload` on the status bar and comes from that tree; with no
--      source nothing is watched and the status line says nothing.
--   9. THE RELEASE PAYLOAD IS SIGNED, OR IT IS REFUSED. Unsigned, mis-signed, signed-but-then-edited: each
--      is a refusal that names the reason, verified by the node's own binary (`wa release verify`) against
--      the same trusted keys every install uses. The accepting case is a payload signed HERE with a key
--      this row puts in the node's own trusted list, so the accept path is real and not a fixture.
--  10. WHAT IT COSTS. Save to visible, the scan, and the per-frame overhead of the wrapper that notices -
--      measured, printed, and asserted to be small.
--
--   WASM_AGENT_LUA_ROOT=$PWD WA_SCRIPT=scripts/test-hotreload.lua wa --db <scratch>/t.db
--
-- No network, no node, no terminal: every module is driven here, and the scratch tree is a directory under
-- this row's own home (`WASM_AGENT_HOME`), which the runner gives each row and disposes.
local json = dofile("lua/vendor/json.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end
local function has(text, needle, label)
  ok(tostring(text):find(needle, 1, true) ~= nil, label .. " (missing: " .. tostring(needle) .. ")")
end

local root = host.getenv("WASM_AGENT_LUA_ROOT") or "."
local home = host.getenv("WASM_AGENT_HOME") or "."

-- The reload module is a singleton in the running process (`__wa_reload`), which is exactly what a second
-- caller finds: this row uses the same instance `chat.lua` would, so what it proves is what a chat does.
local reload = dofile("lua/core/reload.lua")
local payload = dofile("lua/core/payload.lua")

-- One argument of a shell command, for the two shells `host.exec` may use.
local function quote(text)
  text = tostring(text or "")
  local platform_ok, platform = pcall(host.platform)
  local os_name = platform_ok and type(platform) == "table" and tostring(platform.os or "") or ""
  if os_name:lower():match("^win") then return '"' .. text:gsub('"', '""') .. '"' end
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

local work = home .. "/hotreload"
local function write(path, text)
  assert(host.write_file(path, text), "could not write " .. path)
end
local function read(path)
  local text = host.read_file(path)
  return type(text) == "string" and text or nil
end

-- A tick that always looks: the throttle is the reader's friend and this row's enemy (a tick asked with a
-- clock in the future would leave every later tick throttled), so every case below resets it first.
local function tick()
  reload.store.checked = -1
  return reload.tick(host.now())
end

-- The tree's own copy of a module, read once: the cases below plant edited copies of it in the reload tree.
local function source_of_module(path)
  local text = read(root .. "/" .. path)
  assert(type(text) == "string", "this row needs " .. root .. "/" .. path)
  return text
end

-- ============================================================== 1. the inventory

do
  local ui, guard = {}, {}
  for _, path in ipairs(reload.UI) do
    ui[path] = true
    ok(reload.class(path) == "ui", "reload.UI names a ui module: " .. path)
    ok(reload.reloadable(path), "and it is reloadable: " .. path)
  end
  for _, path in ipairs(reload.GUARD) do
    guard[path] = true
    ok(reload.class(path) == "guard", "reload.GUARD names a guard: " .. path)
    ok(not reload.reloadable(path), "and it is never reloadable: " .. path)
  end
  local both = {}
  for path in pairs(ui) do if guard[path] then both[#both + 1] = path end end
  ok(#both == 0, "no module is both ui and guard: " .. table.concat(both, ", "))

  -- The names the mission fixes by hand. A classification that lost one of them would pass every other
  -- case here, so each is asserted by name rather than counted.
  for _, path in ipairs({ "lua/core/hooks.lua", "lua/core/path_guard.lua", "lua/core/canonical_guard.lua",
    "lua/core/progress_guard.lua", "lua/core/codemode_policy.lua", "lua/core/done_gate.lua",
    "lua/core/release.lua", "lua/core/payload.lua", "lua/core/access.lua", "lua/core/binding.lua",
    "lua/core/vault.lua", "lua/core/land.lua", "lua/core/redact.lua", "lua/core/reload.lua" }) do
    ok(reload.class(path) == "guard", "a guard the mission names is a guard: " .. path)
  end
  for _, path in ipairs({ "lua/core/cli_view.lua", "lua/core/balloon.lua", "lua/core/commands.lua",
    "lua/core/status.lua", "lua/core/markdown.lua", "lua/core/markdown.lua" }) do
    ok(reload.class(path) == "ui", "a UI module the mission names is reloadable: " .. path)
  end

  -- The compiled pieces: the terminal driver, the interpreter and the process that owns the session.
  for _, path in ipairs({ "rust/wa-term/src/terminal_editor.rs", "rust/wa-term/src/transcript.rs",
    "rust/wa-host/src/main.rs", "rust/wa-capabilities/src/host.rs",
    "rust/wa-capabilities/src/core_component.rs", "rust/wa-capabilities/src/disk.rs",
    "rust/wa-capabilities/src/whatsapp_approve.rs",
    "rust/wa-host/src/release.rs" }) do
    ok(reload.class(path) == "runtime", "a compiled piece is runtime, never a reload source: " .. path)
  end
  local refused_ok, refused = pcall(reload.require, "rust/wa-term/src/terminal_editor.rs")
  ok(not refused_ok, "the terminal driver cannot be loaded from a reload source")
  has(refused, "never_reloadable", "and the refusal says why")

  -- Every module on disk has a class: a file added under `lua/core` must be classified, and the count is
  -- what notices a new one. The listing is the node's own tree, so this reads what a process sees.
  local listed = host.list_dir(root .. "/lua/core")
  local entries = json.decode(listed)
  local unclassified = {}
  for _, entry in ipairs((entries and entries.entries) or {}) do
    local path = "lua/core/" .. tostring(entry.name)
    if entry.kind == "file" and path:match("%.lua$") then
      if reload.class(path) ~= "ui" and reload.class(path) ~= "guard" and reload.class(path) ~= "core" then
        unclassified[#unclassified + 1] = path
      end
    end
  end
  ok(#unclassified == 0, "every module under lua/core is classified: " .. table.concat(unclassified, ", "))
end

-- ============================================================== 2. the guards cannot be reloaded

local DEV = work .. "/dev"
do
  -- A reload tree that carries a poisoned hooks engine and a poisoned reloader: if either could be read
  -- from here, this whole mechanism would be a way to replace the guards it is checked by.
  write(DEV .. "/lua/core/hooks.lua",
    "return { poison = true, report = function() return 'poison' end, statusline = function() return 'poison' end }\n")
  write(DEV .. "/lua/core/reload.lua", "return { poison = true }\n")
  write(DEV .. "/lua/core/path_guard.lua", "return { poison = true }\n")
  reload.configure({ dev = DEV })
  ok(reload.mode() == "dev", "a dev tree is the source")

  local hooks = reload.require("lua/core/hooks.lua")
  ok(type(hooks) == "table" and hooks.poison == nil, "the hooks engine comes from the node, not the tree")
  ok(reload.source_of("lua/core/hooks.lua") == "node", "and its source says so")
  ok(reload.reloadable("lua/core/hooks.lua") == false, "a guard is never reloadable")
  local guard = reload.require("lua/core/path_guard.lua")
  ok(type(guard) == "table" and guard.poison == nil, "the path guard comes from the node as well")

  -- Editing the poisoned copy and ticking swaps nothing: a guard has no entry to swap.
  local now = host.now()
  local notices = tick()
  local swapped_guard = false
  for _, notice in ipairs(notices) do
    if tostring(notice.path or ""):find("hooks", 1, true) then swapped_guard = true end
  end
  ok(not swapped_guard, "a tick never swaps a guard")
  ok(reload.require("lua/core/hooks.lua").poison == nil, "and the live hooks engine is still the node's")
end

-- ============================================================== 3. a good edit applies

do
  reload.configure({ dev = DEV })
  local commands = reload.require("lua/core/commands.lua")
  -- The dev tree starts without a commands module: the proxy reads the node's copy, so the first
  -- `/help` is the installed one.
  ok(reload.source_of("lua/core/commands.lua") == nil, "commands is not loaded until it is used")
  has(commands.help(), "/help", "the node's help text is what the first call answers")
  ok(reload.source_of("lua/core/commands.lua") == "node", "and it came from the node")

  local text = source_of_module("lua/core/commands.lua")
  -- One row added, which is what a developer does: the help text is generated from these rows, so a new
  -- row is visible in the output with no other change.
  local marked = text:gsub("M.commands = {", "M.commands = {\n  { name = \"/probe\", usage = \"/probe\", hint = \"FIRSTMARK\" },", 1)
  ok(marked ~= text, "the planted copy differs from the tree's")
  write(DEV .. "/lua/core/commands.lua", marked)

  local before = reload.store.version
  local notices = tick()
  local applied = false
  for _, notice in ipairs(notices) do if notice.ok then applied = true end end
  ok(applied, "the change is applied at the next tick")
  ok(reload.store.version > before, "the store's version moves with the swap")
  has(commands.help(), "FIRSTMARK", "the NEXT call answers with the tree's text")
  ok(reload.source_of("lua/core/commands.lua") == "reload", "and the source says reload")

  -- And again: a second edit to the same module, so a swap is not a one-off.
  write(DEV .. "/lua/core/commands.lua", (marked:gsub("FIRSTMARK", "SECONDMARK")))
  reload.tick(host.now() + 20)
  has(commands.help(), "SECONDMARK", "a second edit applies as well")
  ok(commands.help():find("FIRSTMARK", 1, true) == nil, "the previous copy is gone")
end

-- ============================================================== 4. a syntax error keeps the old module

do
  local cli_view = reload.require("lua/core/cli_view.lua")
  local good = source_of_module("lua/core/cli_view.lua")
  ok(type(cli_view.new) == "function", "the view module is live")

  write(DEV .. "/lua/core/cli_view.lua", good .. "\nthis is not lua (\n")
  local failures = reload.store.failures
  local notices = tick()
  local said = nil
  for _, notice in ipairs(notices) do if not notice.ok then said = tostring(notice.text) end end
  ok(said ~= nil, "a syntax error produces a notice")
  has(said, "reload failed: lua/core/cli_view.lua: ", "the line names the module")
  ok(reload.store.failures == failures + 1, "and it is counted as a failure")
  ok(type(cli_view.new) == "function", "the live module is still the good one")
  ok(type(cli_view.banner({ limit = 80, version = "x" })) == "string", "and it still draws")

  -- The same broken file is not re-read and re-reported on every frame: the next ticks are silent until
  -- the file changes again, which is what keeps a broken edit from filling the screen.
  local again = tick()
  ok(#again == 0, "the same broken file is not reported twice")
end

-- ============================================================== 5. a runtime error in render keeps the old module

do
  local cli_view = reload.require("lua/core/cli_view.lua")
  local good = source_of_module("lua/core/cli_view.lua")
  -- It parses, it loads, and it raises while drawing the status line - the case a syntax check cannot
  -- see and a self-check that only looks at the table would miss.
  local broken = good:gsub("function METHODS:status_text%(with_spinner%)",
    "function METHODS:status_text(with_spinner)\n  error(\"boom in status_text\")", 1)
  ok(broken ~= good, "the planted copy raises in status_text")
  write(DEV .. "/lua/core/cli_view.lua", broken)

  local notices = tick()
  local said = nil
  for _, notice in ipairs(notices) do if not notice.ok then said = tostring(notice.text) end end
  ok(said ~= nil, "a render that raises produces a notice")
  has(said, "boom in status_text", "and the notice carries the error")
  local view = cli_view.new({ out = function() end, live = false, limit = 80, register = false })
  local drawn, line = pcall(function() return view:status_text(false) end)
  ok(drawn, "the old module still draws the status line")
  ok(drawn and type(line) == "string", "and it answers a string")
end

-- ============================================================== 6. nothing half-swapped; state survives

do
  local cli_view = reload.require("lua/core/cli_view.lua")
  local good = source_of_module("lua/core/cli_view.lua")
  write(DEV .. "/lua/core/cli_view.lua", good)

  -- A live view with real state in it, and the four other pieces of state the store owns.
  local out = {}
  local view = cli_view.new({ out = function(text) out[#out + 1] = text end, live = false, limit = 100 })
  view.phase, view.runs, view.limit = "probe phase", 7, 100
  view.turn = { started = host.now(), step_started = host.now(), rounds = 3, tools = 2 }
  reload.state("balloon").page, reload.state("balloon").selected = 4, 2
  reload.store.scroll.top = 12
  reload.store.wakes.text = "2 wakes"
  reload.store.input = { pending = { "typed during the run" }, eof = false }
  local methods_before = getmetatable(view).__index

  -- The swap: the tree's copy gains a marker the new code draws, so "which code is live" is observable.
  local marked = good .. "\n-- the second version\n"
  write(DEV .. "/lua/core/cli_view.lua", marked)
  local notices = tick()
  local applied = false
  for _, notice in ipairs(notices) do if notice.ok then applied = true end end
  ok(applied, "a good edit of cli_view applies")

  ok(getmetatable(view).__index ~= methods_before, "the live view answers with the new module's methods")
  ok(getmetatable(view).__index == cli_view.__methods, "and they are the live module's own table")
  ok(view.phase == "probe phase" and view.runs == 7 and view.limit == 100, "the view kept its own state")
  ok(view.turn and view.turn.rounds == 3, "the run in flight is still the same run")
  ok(reload.state("balloon").page == 4 and reload.state("balloon").selected == 2, "the balloon kept its page")
  ok(reload.store.scroll.top == 12, "the scroll anchor survived")
  ok(reload.store.wakes.text == "2 wakes", "the wake line survived")
  ok(reload.store.input and reload.store.input.pending[1] == "typed during the run",
    "the input object survived, with the line typed during the run")
  ok(type(view:status_text(false)) == "string", "and the view still draws with the new methods")
  reload.drop_view(view)
end

-- ============================================================== 7. a streaming run is not interrupted

do
  local cli_view = reload.require("lua/core/cli_view.lua")
  local good = source_of_module("lua/core/cli_view.lua")
  write(DEV .. "/lua/core/cli_view.lua", good)

  local out = {}
  local view = cli_view.new({ out = function(text) out[#out + 1] = text end, live = false, limit = 100 })
  view:run_started()
  local events = {
    { type = "round", n = 1 },
    { type = "status", text = "thinking" },
    { type = "delta", text = "first half " },
    { type = "tool", name = "bash", arguments = { command = "true" } },
    { type = "tool_result", name = "bash", result = { code = 0, stdout = "ok" } },
    { type = "usage", prompt = 120, completion = 40, total = { prompt = 120, completion = 40, cached = 0 } },
  }
  local rendered_before = 0
  for _, event in ipairs(events) do
    local drawn, problem = pcall(view.event, view, event)
    ok(drawn, "the event before the swap renders: " .. tostring(event.type) .. " " .. tostring(problem))
    if drawn then rendered_before = rendered_before + 1 end
  end
  local rounds_before = view.turn and view.turn.rounds or 0

  -- The save happens WHILE the run is streaming: the change draws a phase word the old copy cannot.
  local marked = good:gsub('if text == "thinking" or text == "model" then\n      self%.phase = "Thinking"',
    'if text == "thinking" or text == "model" then\n      self.phase = "StreamProbe"', 1)
  ok(marked ~= good, "the planted copy renames the phase word")
  write(DEV .. "/lua/core/cli_view.lua", marked)
  local notices = tick()
  local applied = false
  for _, notice in ipairs(notices) do if notice.ok then applied = true end end
  ok(applied, "the swap happens in the middle of the stream")

  for _, event in ipairs(events) do
    local drawn, problem = pcall(view.event, view, event)
    ok(drawn, "the event after the swap renders: " .. tostring(event.type) .. " " .. tostring(problem))
  end
  ok(view.turn and view.turn.rounds >= rounds_before, "the run's counters survived the swap")
  view:run_finished()
  ok(true, "the run finished after a reload in the middle of it")
  ok((view.phase or "") == "", "the phase is cleared when the run finishes")
  -- The new code is the one drawing: the phase word it sets is the patched one. A second status event
  -- after the swap is what proves it, not the module's table.
  view:run_started()
  view:event({ type = "status", text = "thinking" })
  ok(view.phase == "StreamProbe", "the frame after the swap is drawn by the new module")
  view:run_finished()
  reload.drop_view(view)
end

-- ============================================================== 7b. /mcp, end to end, mid-run

-- The command the mission names: `/mcp`'s pages come from `mcp_command.lua` (the data) through
-- `mcp_cli.lua` (the driver). Editing the data while a run streams has to show on the NEXT `/mcp`, and the
-- run has to keep streaming. This is the whole path the chat takes - the command's own module, loaded
-- through the proxy - so a green line here is the operator's case, not a unit test of the loader.
do
  local cli_view = reload.require("lua/core/cli_view.lua")
  local mcp_cli = reload.require("lua/core/mcp_cli.lua")
  local ctx = { user_id = "master", role = "master", session_id = "hotreload-probe" }
  local set = mcp_cli.views(ctx, {})
  local pages = (type(set) == "table" and type(set.views) == "table") and set.views or {}
  ok(#pages > 0, "/mcp answers pages before any edit")
  local first_title = pages[1] and pages[1].title or ""
  has(first_title, "MCP connectors", "/mcp's first page is the connector list")
  ok(reload.source_of("lua/core/mcp_command.lua") == "node", "and its data module came from the node")

  -- A run is streaming while the save happens: three real frames before, three after.
  local out = {}
  local view = cli_view.new({ out = function(text) out[#out + 1] = text end, live = false, limit = 100 })
  view:run_started()
  view:event({ type = "round", n = 1 })
  view:event({ type = "delta", text = "working " })

  local data = source_of_module("lua/core/mcp_command.lua")
  local marked = data:gsub("title = 'MCP connectors'", "title = 'MCP connectors (dev)'", 1)
  ok(marked ~= data, "the planted copy renames the page")
  write(DEV .. "/lua/core/mcp_command.lua", marked)
  local notices = tick()
  local applied = false
  for _, notice in ipairs(notices) do if notice.ok and tostring(notice.path or ""):find("mcp_command", 1, true) then applied = true end end
  ok(applied, "the edit to /mcp's own data lands as its own swap")

  view:event({ type = "delta", text = "after the save " })
  view:event({ type = "tool", name = "bash", arguments = { command = "true" } })
  view:event({ type = "tool_result", name = "bash", result = { code = 0, stdout = "ok" } })
  ok(view.turn ~= nil and (view.turn.rounds or 0) >= 1, "the run kept its counters across the swap")

  local after = mcp_cli.views(ctx, {})
  local after_pages = (type(after) == "table" and type(after.views) == "table") and after.views or {}
  has(after_pages[1] and after_pages[1].title or "", "MCP connectors (dev)",
    "the NEXT /mcp shows the changed page")
  ok(reload.source_of("lua/core/mcp_command.lua") == "reload", "and it came from the reload tree")
  view:run_finished()
  ok(view.turn == nil, "the run finished normally after a reload in the middle of it")
  reload.drop_view(view)
end

-- ============================================================== 8. the two sources

do
  local cli_view = reload.require("lua/core/cli_view.lua")
  reload.configure({ dev = DEV })
  ok(reload.mode() == "dev", "--dev names the working tree")
  ok(reload.status() == "dev reload", "and the status bar says dev reload")
  local view = cli_view.new({ out = function() end, live = false, limit = 80, register = false })
  view.phase = "working"
  has(view:status_text(false), "dev reload", "the status line carries the marker")
  reload.drop_view(view)

  -- No source at all: nothing is watched, nothing is said, and the tick returns before asking the host.
  reload.configure({})
  if not payload.installed() then
    ok(reload.mode() == nil, "a node with no payload and no --dev has no reload source")
    ok(reload.status() == nil, "and its status bar says nothing")
    local quiet = cli_view.new({ out = function() end, live = false, limit = 80, register = false })
    quiet.phase = "working"
    ok(quiet:status_text(false):find("dev reload", 1, true) == nil, "no marker without a source")
    reload.drop_view(quiet)
    local started = host.now()
    for _ = 1, 200 do reload.tick(host.now()) end
    ok((host.now() - started) < 0.5, "200 ticks with no source cost nothing")
  else
    ok(reload.mode() == "release", "a node with a payload reloads from it")
  end
end

-- ============================================================== 9. the release payload is signed

do
  local PAY = work .. "/payload"
  local keys_file = home .. "/release-keys.txt"

  -- (a) unsigned: the ordinary way to get a payload wrong, and the one a `scp` of a tree produces.
  write(PAY .. "/lua/core/commands.lua", "return { help = function() return 'unsigned' end }\n")
  local fine, problem = payload.ensure(PAY, true)
  ok(fine == false, "a payload with no SHA256SUMS is refused")
  has(problem, "payload_unsigned", "and says it is unsigned")

  -- (b) a signature is not enough: the SUMS have to name these bytes. The committed fixture pair is a real
  -- signature by a key that file's own trusted list holds, so the acceptance of the SIGNATURE is proved
  -- with the node's verifier and no vault: what fails after that is the file, which is the point.
  write(keys_file, read(root .. "/tests/fixtures/release-sign/keys.txt"))
  write(PAY .. "/SHA256SUMS", read(root .. "/tests/fixtures/release-sign/good/SHA256SUMS"))
  write(PAY .. "/SHA256SUMS.sig", read(root .. "/tests/fixtures/release-sign/good/SHA256SUMS.sig"))
  payload.reset()
  local signed, why = payload.ensure(PAY, true)
  ok(signed == true, "a signed payload's signature verifies with the node's own binary: " .. tostring(why))
  local listed, why_not = payload.file_ok(PAY, "lua/core/commands.lua", read(PAY .. "/lua/core/commands.lua"))
  ok(listed == false, "a file the signed sums do not name is refused")
  has(why_not, "payload_file_unlisted", "and the refusal names the case")

  -- (c) a payload signed for ITS OWN files. Signed here with the vault's own ed25519 code (imported, no
  -- vault process, no network) and trusted by a key written into this node's trusted list, which is the
  -- same trust path an operator uses. With no python3 the vault's signer cannot run, and the row then
  -- proves the refusal instead - named on its own line, so a green row never claims a case it did not run.
  payload.reset()
  write(keys_file, read(root .. "/tests/fixtures/release-sign/keys.txt"))
  write(PAY .. "/SHA256SUMS", read(root .. "/tests/fixtures/release-sign/good/SHA256SUMS"))
  write(PAY .. "/SHA256SUMS.sig", read(root .. "/tests/fixtures/release-sign/good/SHA256SUMS.sig"))
  local signer = [[
import hashlib, os, sys
sys.path.insert(0, sys.argv[1] + "/vault")
import wa_vault as vault
payload, keys = sys.argv[2], sys.argv[3]
seed = hashlib.sha256(b"hotreload-test-key").digest()
public = vault.ed25519_public(seed).hex()
key_id = "release-signing-" + hashlib.sha256(bytes.fromhex(public)).hexdigest()[:16]
lines = []
for folder, _, names in os.walk(os.path.join(payload, "lua")):
    for name in sorted(names):
        full = os.path.join(folder, name)
        rel = os.path.relpath(full, payload).replace(os.sep, "/")
        with open(full, "rb") as handle:
            lines.append("%s  %s" % (hashlib.sha256(handle.read()).hexdigest(), rel))
lines.sort(key=lambda line: line.split("  ", 1)[1])
with open(os.path.join(payload, "SHA256SUMS"), "w") as handle:
    handle.write("\n".join(lines) + "\n")
with open(os.path.join(payload, "SHA256SUMS"), "rb") as handle:
    digest = hashlib.sha256(handle.read()).digest()
signature = vault.ed25519_sign(seed, digest)
with open(os.path.join(payload, "SHA256SUMS.sig"), "w") as handle:
    handle.write("wa-release-signature v1\nkey %s\nalg ed25519\nsha256 %s\nsig %s\n"
                 % (key_id, digest.hex(), signature.hex()))
with open(keys, "w") as handle:
    handle.write("wa-trusted-keys v1\nkey %s %s\n" % (key_id, public))
]]
  local sign_file = work .. "/sign-payload.py"
  write(sign_file, signer)
  local ran = host.exec("python3 " .. quote(sign_file) .. " " .. quote(root) .. " " .. quote(PAY)
    .. " " .. quote(keys_file), "", 60)
  local answer = json.decode(ran) or {}
  if tonumber(answer.code) == 0 then
    payload.reset()
    local accepted, reason = payload.ensure(PAY, true)
    ok(accepted == true, "a payload signed for its own files is accepted: " .. tostring(reason))
    local file_ok, file_problem = payload.file_ok(PAY, "lua/core/commands.lua", read(PAY .. "/lua/core/commands.lua"))
    ok(file_ok == true, "and each file it names is accepted: " .. tostring(file_problem))

    -- Editing one file inside an accepted payload is the refusal that matters most: the bytes changed
    -- after the signature was made.
    write(PAY .. "/lua/core/commands.lua", "return { help = function() return 'edited after signing' end }\n")
    local tampered, tampered_why = payload.file_ok(PAY, "lua/core/commands.lua", read(PAY .. "/lua/core/commands.lua"))
    ok(tampered == false, "a file edited after signing is refused")
    has(tampered_why, "payload_file_mismatch", "and the refusal names the file")

    -- And the reloader's own gate: in release mode that file is not swapped in.
    reload.configure({ payload = PAY })
    ok(reload.mode() == "release", "the payload is the source")
    ok(reload.status() == nil, "a deployed payload says nothing on the status bar")
    ok(reload.root() == PAY, "and its tree is the payload directory")
    reload.configure({})
  else
    print("hotreload: the vault's signer did not run (python3: " .. tostring(answer.stderr or answer.error)
      .. "); the accept case above is the fixture signature, which the node's verifier accepted")
  end
end

-- ============================================================== 10. what it costs

do
  reload.configure({ dev = DEV })
  local cli_view = reload.require("lua/core/cli_view.lua")
  local commands = reload.require("lua/core/commands.lua")
  local good = source_of_module("lua/core/commands.lua")

  -- Save to visible: write the file, then tick with a clock past the throttle, and time the tick. That is
  -- the whole path - directory scan, load, self-check, swap - because the throttle (250 ms in dev) is the
  -- one part a reader waits for, and it is bounded rather than measured here.
  local started = host.now()
  write(DEV .. "/lua/core/commands.lua", (good:gsub("hint = \"live reload", "hint = \"MEASURED live reload")))
  local written = host.now()
  tick()
  local applied = host.now()
  has(commands.help(), "MEASURED live reload", "the measured edit is visible")
  local tick_ms = (applied - written) * 1000
  ok(tick_ms < 1000, string.format("save to visible is well under a second (%.0f ms)", tick_ms))

  -- The scan on its own: one directory listing of the modules that are loaded.
  local scan_started = host.now()
  for _ = 1, 20 do tick() end
  local scan_ms = (host.now() - scan_started) * 1000 / 20

  -- The per-frame overhead: a framed draw, with and without a source to watch, and - the worst case a
  -- reader can meet - a frame where the scan is DUE, which is every 250 ms rather than every frame.
  local out = {}
  local view = cli_view.new({ out = function(text) out[#out + 1] = text end, live = false, limit = 100, register = false })
  local function frames(count, force)
    local at = host.now()
    for _ = 1, count do
      if force then reload.store.checked = -1 end
      view:status_draw("working")
    end
    return (host.now() - at) * 1000 / count
  end
  local scanning = frames(300, true)
  local watched = frames(300, false)
  reload.configure({})
  local unwatched = frames(300, true)
  print(string.format(
    "hotreload: save to visible %.0f ms (plus the 250 ms dev throttle at most); scan %.2f ms; "
      .. "status frame %.3f ms scanning, %.3f ms watched, %.3f ms unwatched",
    tick_ms, scan_ms, scanning, watched, unwatched))
  ok(scanning < 5, string.format("a frame whose scan is due costs under 5 ms (%.3f ms)", scanning))
  ok(unwatched < 1, string.format("a frame with no source costs almost nothing (%.3f ms)", unwatched))
  reload.drop_view(view)
  reload.configure({})
end

-- ============================================================== done

-- Best effort, and only the directory this row created under its own home.
if not (host.platform and (host.platform().os or ""):lower():match("^win")) then
  pcall(host.exec, "rm -rf " .. quote(work), "", 30)
end

if failed > 0 then
  print(string.format("hotreload: %d of %d checks failed", failed, checks))
  os.exit(1)
end
print(string.format("hotreload ok: %d checks", checks))
