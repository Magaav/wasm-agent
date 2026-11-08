-- seamless update: the row that says `updating…`, and the two mechanisms underneath it.
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-seamless.lua wa --db <scratch>/t.db
--
-- Three surfaces have to agree for an update to be seamless, and this is the test that they do:
--
--   * the **CLI** says `updating…` on the session-status-content row while it is waiting to re-exec into
--     a new build (`lua/core/cli_restart.lua` + `lua/core/chat.lua`), and the row it writes is the row
--     the renderer draws (`lua/core/cli_view.lua`);
--   * the **window** says the same sentence on its own session-status-content row while its node is away
--     being replaced, and clears it on the recovery edge (`ui/app.js`);
--   * the mechanisms under both: a component hot-swap hands the retired instance's queue leases to the
--     instance that replaced it before anything is revoked, and the sentinel delegates start/stop/restart
--     to the watchdog when `WA_WATCHDOG` says the watchdog owns the node's pid.
--
-- The Lua and JavaScript halves are read out of the shipping files (not re-implemented), the way
-- `scripts/test-update-banner.lua` and `tests/update-banner.js` do: a source that drifts fails here.
local cli_restart = dofile("lua/core/cli_restart.lua")
local cli_view = dofile("lua/core/cli_view.lua")

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
local function read(path)
  local text = host.read_file(path)
  ok(type(text) == "string" and text ~= "", path .. " is readable")
  return text or ""
end

-- ---- 1. the sentence, and when it is said -----------------------------------

eq(cli_restart.UPDATING, "updating…", "the CLI's sentence is `updating…`")
local line = cli_restart.line("a new wa build is installed (binary changed)")
eq(type(line), "table", "a pending restart has a line")
eq(line.text, "updating…", "whose text is the sentence, never the reason")
eq(line.kind, "notice", "of the notice kind, which is the kind both renderers draw on that row")
ok(not tostring(line.text):find("binary changed", 1, true), "the reason is not shown: it can name a path")
eq(cli_restart.line(nil), nil, "nothing pending is no line at all, not a blank row")
eq(cli_restart.line(nil, true), nil, "and a refusal is still nothing pending")
eq(cli_restart.line("a new build", true), nil, "a restart the loop guard refused does not claim it is updating")

-- ---- 2. the CLI view really draws it on the session-status-content row ------

local writes = {}
local function framed(extra)
  writes = {}
  local options = { live = true, limit = 120, now = function() return 100 end,
    rows = function() return 21 end, out = function(text) writes[#writes + 1] = text end }
  for key, value in pairs(extra or {}) do options[key] = value end
  local view = cli_view.new(options)
  view.screen = { top = 1, bottom = 19, status = 20, content = 19, input = 21 }
  view.region_row = 19
  return view
end
local function drawn() return table.concat(writes, "") end

local view = framed({ session_status = function() return cli_restart.line("a new build") end })
view:session_draw()
local out = drawn()
ok(out:find("\27[19;1H", 1, true) ~= nil, "`updating…` is drawn on row 19, directly above the status bar on 20")
ok(out:find(cli_view.paint("updating…", "warning", true), 1, true) ~= nil, "in the notice's own yellow")
eq(view:region_bottom(), 18, "and the row is reserved: output ends one row higher while it shows")

-- The row goes back to the chat when the restart stops being pending: no gap, no leftover text.
local after = framed({ session_status = function() return cli_restart.line(nil) end })
after.session_shown = "updating…"
after.session_shown_cols = 9
after:session_draw()
eq(after.session_shown, nil, "a cleared line forgets what it drew")
ok(drawn():find("\27[2K", 1, true) ~= nil, "and blanks that row rather than leaving the old sentence behind")
eq(after:region_bottom(), 19, "the output region takes the row back")

-- ---- 3. the CLI's wiring: one row, two producers, and the draw before the exec ------

local chat = read("lua/core/chat.lua")
ok(chat:find("local restart_pending = nil", 1, true) ~= nil, "chat.lua keeps the pending restart's reason")
ok(chat:find("cli_restart.line(restart_pending)", 1, true) ~= nil, "and resolves the row through cli_restart.line")
ok(chat:find("view.session_status = function()", 1, true) ~= nil, "the row is one function, set once")
ok(chat:find("if banner then return banner.session_content({ notice = seen and seen.line }) end", 1, true) ~= nil,
  "the update notice is the standing text underneath a pending restart")
ok(chat:find("restart_pending = reason", 1, true) ~= nil, "the line is set when a restart is due")
ok(chat:find("restart_pending = nil", 1, true) ~= nil, "and cleared when the restart does not happen")
local due = chat:find("restart_pending = reason", 1, true) or 0
local draw = chat:find("view:session_draw()", due, true) or 0
local exec = chat:find("restart(reason)", due, true) or 0
ok(draw > due and exec > draw, "the row is drawn before the exec, so the reader sees it while the screen comes down")
ok(chat:find("view.session_status = function() return banner.session_content", 1, true) == nil,
  "the old single-producer assignment is gone (two producers on one row is how one of them goes missing)")

-- ---- 4. the window's half ---------------------------------------------------------

local app = read("ui/app.js")
ok(app:find('const UPDATING_TEXT = "updating…";', 1, true) ~= nil, "app.js pins the same sentence")
ok(app:find("function paintSessionContent()", 1, true) ~= nil, "one resolver owns the row")
-- One resolver, and the same precedence as before: `updating…` replaces the standing notice, and
-- both outrank the third claimant (a long tool call's row, docs/TOOL-PROGRESS.md) that was added
-- underneath them. The call's own half is pinned by tests/tool-progress.js.
ok(app:find("const standing = sessionUpdating || sessionStandingNotice;", 1, true) ~= nil
  and app:find("if (standing) return paintSessionNotice(standing);", 1, true) ~= nil,
  "`updating…` replaces the standing notice on that row instead of competing with it")
ok(app:find("if (upgradeState) paintUpdating(true);", 1, true) ~= nil,
  "the line appears when the node stops answering during an install")
ok(app:find("paintUpdating(false)", 1, true) ~= nil, "and is cleared on the recovery edge")
local cleared = app:find("paintUpdating(false)", app:find("function clearNodeRestartStatus()", 1, true) or 1, true)
ok(cleared ~= nil, "the clearing lives on the one recovery path (clearNodeRestartStatus)")
ok(app:find("sessionStandingNotice = text;", 1, true) ~= nil, "the banner keeps feeding the row while it is not updating")

-- ---- 5. the component hot swap hands the queue over ----------------------------------

local services = read("rust/wa-kernel-runtime/src/services.rs")
local replace_at = services:find("pub(crate) fn replace(name: &str, candidate: Spawned)", 1, true) or 0
ok(replace_at > 0, "services.rs has the switch")
local handover_at = services:find("handover_instance(&token)", replace_at, true) or 0
local revoke_at = services:find("revoke_generation(name, old.generation)", replace_at, true) or 0
local unregister_at = services:find("unregister_instance(&format!(\"{name}#{}\", old.generation))", replace_at, true) or 0
ok(handover_at > 0, "the retired instance's leases are handed over")
ok(handover_at < revoke_at, "before its registrations are revoked")
ok(handover_at < unregister_at, "and before its queue rights are revoked (the grants are needed to find them)")
local queue_host = read("rust/wa-kernel-runtime/src/queue_host.rs")
ok(queue_host:find("pub fn handover_instance(&self, token: &str) -> usize", 1, true) ~= nil,
  "queue_host has the handover")
ok(queue_host:find("pub(crate) fn scoped_worker(", 1, true) ~= nil,
  "a lease names the instance that holds it, not just the guest's worker string")
ok(queue_host:find("scoped_worker(&owner, &worker)", 1, true) ~= nil,
  "take/done/fail/heartbeat share one scoping rule")
local queue = read("rust/wa-queue/src/queue.rs")
ok(queue:find("pub fn handover(&self, queue: &str, prefix: &str) -> Result<usize> {", 1, true) ~= nil,
  "the library has the primitive: return the lease, spend no attempt")
ok(queue:find("if job.fresh_until.is_some_and(|fresh| fresh <= now) {", 1, true) ~= nil,
  "and it still refuses to hand stale work to the next instance")

-- ---- 6. the sentinel addresses the watchdog -----------------------------------------

local sentinel = read("rust/wa-sentinel/src/main.rs")
ok(sentinel:find("mod watchdog;", 1, true) ~= nil, "the sentinel carries the delegation module")
ok(sentinel:find("watchdog::plan(watchdog::Verb::Restart", 1, true) ~= nil, "restart asks the plan first")
ok(sentinel:find("watchdog::plan(watchdog::Verb::Restart, watchdog::enabled(), &watchdog::ownership(&watchdog::home_dir(), pid_alive))", 1, true) ~= nil,
  "and `recover` shares it: an interrupting restart is a swap of the same bytes")
ok(sentinel:find("fn verb_stop(reason: &str)", 1, true) ~= nil, "stop is a verb")
ok(sentinel:find('"stop" => verb_stop(reason),', 1, true) ~= nil, "and is dispatched")
ok(sentinel:find('const REQUEST_VERBS: [&str; 7] = ["restart", "recover", "wake", "deploy", "run", "spell", "stop"];', 1, true) ~= nil,
  "a `request stop` is recognised, so it writes no durable state it cannot carry out")
ok(sentinel:find('for verb in ["restart", "spell", "deploy", "stop"] {', 1, true) ~= nil,
  "stop waits for idle, like every verb that replaces the node")
ok(sentinel:find("watchdog::start_supervisor(", 1, true) ~= nil, "a start (and autostart) starts the supervisor")
local watchdog = read("rust/wa-sentinel/src/watchdog.rs")
ok(watchdog:find("pub(crate) fn plan(verb: Verb, enabled: bool, ownership: &Ownership) -> Plan {", 1, true) ~= nil,
  "the decision is a pure function of the verb, the switch and what the supervisor recorded")
ok(watchdog:find('"swap", Some((binary, pin.as_str(), no_args)), wait', 1, true) ~= nil,
  "a restart is the watchdog's swap of the installed bytes, with their own digest as the pin")
ok(watchdog:find("pub(crate) fn sha256_file(", 1, true) ~= nil, "and the pin is computed here, never taken on trust")
ok(read("rust/wa-watchdog/src/swap.rs"):find("pub fn wait_result(", 1, true) ~= nil,
  "the watchdog keeps the answer file a caller reads a verdict from")

-- ---- 7. the documentation says the same thing ----------------------------------------

local sentinel_doc = read("docs/SENTINEL.md")
ok(sentinel_doc:find("### The verbs address the watchdog", 1, true) ~= nil,
  "SENTINEL.md has the section on the three verbs addressing the watchdog")
local update_doc = read("docs/RELEASE-UPDATE.md")
ok(update_doc:find("updating…", 1, true) ~= nil, "RELEASE-UPDATE.md documents the `updating…` line")
for _, path in ipairs({ "lua/core/cli_restart.lua", "ui/app.js", "docs/RELEASE-UPDATE.md" }) do
  ok(read(path):find("updating…", 1, true) ~= nil, path .. " names the sentence `updating…`")
end

print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
