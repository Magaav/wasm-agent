-- The operator switch for transcript posting talks to the COMPONENT, and the removed connector's URL is
-- gone (mission whatsapp-posting-toggle, 23/11).
--
-- WHAT WAS BROKEN. `wa_whatsapp_posting` (lua/core/server.lua) POSTed to `WA_WHATSAPP_POSTING_URL` +
-- `/operator/posting`: the Go connector's HTTP API, removed in `67c78621` (Phase 4, 11/11). With those
-- variables unset it answered `whatsapp_posting_not_configured`, so from 11/11 there was no door at all
-- for the one config key that decides whether a transcript is delivered - while the `wa-whatsapp`
-- component transcribed correctly and said `posting off (allow [])` (measured 23/11 on openclaw: two
-- notes decoded at 12:04Z, zero `kind=posted` lines in 2896 log lines).
--
-- WHAT THIS ROW PROVES, in order:
--   * a scratch component with no posting config reports posting off - the openclaw shape, reproduced;
--   * the verb turns it ON through the services path and the component's own health line says `posting=on`
--     (`posted=<n>` comes from that line, not from the request);
--   * the exact four keys the component reads are what it is started with, and every other config key is
--     left alone;
--   * changing nothing writes nothing and restarts nothing;
--   * the allow list is validated as an allow-list of accepted forms, and a refusal never echoes an entry,
--     never logs one, and never stores one;
--   * a non-operator and a child agent are refused, and the store is untouched;
--   * a health line that cannot be read is a refusal (`..._unverified`), not a success - unknown is not yes;
--   * a component that refuses to start on the new definition gets the OLD definition back and keeps
--     running it;
--   * the removed connector is never called - `host.http` records zero calls even with its five variables
--     set - and a request carrying its API fields is refused BY NAME;
--   * the fields the old door answered are still answered, from the answers recorded on the base commit
--     (tests/fixtures/whatsapp-posting-old-door.json).
--
-- THE FAKE, AND WHY IT IS HAND-WRITTEN. `scripts/lib/contract-host.lua` implements no `service`
-- capability, and this row must not start real components. So `host.service` - and only it - is a stub,
-- with the shapes measured from `rust/wa-kernel-runtime/src/services.rs` (`service()`: start|stop|status|
-- logs, `invalid_service_action` for anything else, `service_unknown` for a log of an instance that is
-- not running). Its `start` answers like the real component because the component's start lines are its
-- own contract (`src/guest.rs` `serve` + `src/health.rs` `line`); the strings below are copied from
-- those two functions, and `cargo test -p wa-whatsapp health::` holds them. The store, the SQL, the
-- registry, the auth and the route are the node's REAL ones: this row runs under `WA_SCRIPT` with its
-- own scratch WASM_AGENT_HOME and its own database.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then
  error("this test writes a services registry and restarts nothing real: it refuses to run (" .. guard_reason .. ")")
end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local users = dofile("lua/core/users.lua")
local services = dofile("lua/core/services.lua")
dofile("lua/core/server.lua")

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error("WHATSAPP POSTING CHECK FAILED: " .. label) end
end
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then
    error(string.format("WHATSAPP POSTING CHECK FAILED: %s\n  got:  %s\n  want: %s", label,
      tostring(got), tostring(want)))
  end
end
local function contains(haystack, needle, label)
  checks = checks + 1
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error("WHATSAPP POSTING CHECK FAILED: " .. label .. " (missing " .. tostring(needle) .. ")")
  end
end
local function absent(haystack, needle, label)
  checks = checks + 1
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    error("WHATSAPP POSTING CHECK FAILED: " .. label .. " (found " .. tostring(needle) .. ")")
  end
end

-- The two modules this row is about, loaded through pcall so that a tree WITHOUT them fails on a
-- NAMED check - the shape scripts/test-discriminates.sh reads as "an assertion failed on the old code" -
-- instead of dying on a raw load error that says nothing about the change.
local function load_module(path)
  local loaded, module = pcall(dofile, path)
  if loaded and type(module) == "table" then return module end
  return nil
end
local posting = load_module("lua/core/whatsapp_posting.lua")
ok(posting ~= nil, "the operator switch exists as a module (lua/core/whatsapp_posting.lua)")
local cli = load_module("lua/core/whatsapp_posting_cli.lua")
ok(cli ~= nil, "and so does its operator CLI (lua/core/whatsapp_posting_cli.lua)")

local SERVICE = "wa-whatsapp"
local MASTER = { role = "master", user_id = "test" }
local GROUP = "120363021234567890@g.us"

-- ---- the runtime this row plays: `host.service`, and only it --------------------------------
local runtime = { instances = {}, starts = {}, requests = {}, posted = 0, fail_next_start = nil, log_override = nil,
  http_calls = {}, logged = {} }

-- The component's own start lines, byte for byte as `src/guest.rs` `serve` and `src/health.rs` `line`
-- print them (the `[  n.nn s] ` prefix is `say!`). A fake that printed something else would let a
-- parser bug pass here and fail on the node.
local function component_log(config)
  config = type(config) == "table" and config or {}
  local mode = config.post_transcripts == true and "on" or "off"
  local language = type(config.language) == "string" and config.language or "pt"
  local allow = {}
  if type(config.post_allow) == "table" then
    for _, entry in ipairs(config.post_allow) do allow[#allow + 1] = '"' .. tostring(entry) .. '"' end
  end
  return table.concat({
    "[    0.00s] clock: 1795447000000 ms since epoch",
    string.format("[    0.01s] transcription: language %s, posting %s (allow [%s]), alerts %s, stream_edits %s"
      .. " (min 15 s, edit every 5 s), held chats 0 (configured 0)", language, mode,
      table.concat(allow, ", "), config.alerts == true and "on" or "off",
      config.stream_edits == true and "true" or "false"),
    "[    0.01s] wa-whatsapp: starting (pairing by QR)",
    string.format("[    0.02s] health: v=1 transcripts ok=0 last=- chars=0 failed=0 last_failure=- reason=-"
      .. " posting=%s posted=%d last_post=- index written=0 last=-", mode, runtime.posted),
    "[    0.02s] wa-whatsapp: starting the protocol task",
  }, "\n") .. "\n"
end

host.service = function(request_json)
  local request = json.decode(request_json) or {}
  runtime.requests[#runtime.requests + 1] = request
  local action = tostring(request.action or "")
  local name = tostring(request.name or "")
  if action == "start" then
    if runtime.fail_next_start then
      local answer = runtime.fail_next_start
      runtime.fail_next_start = nil
      return json.encode(answer)
    end
    runtime.starts[#runtime.starts + 1] = request
    runtime.instances[name] = {
      config = request.config,
      log = runtime.log_override and runtime.log_override(request.config) or component_log(request.config),
    }
    return json.encode({ ok = true, name = name, state = "fresh" })
  elseif action == "stop" then
    local was = runtime.instances[name] ~= nil
    runtime.instances[name] = nil
    return json.encode({ ok = true, name = name, was_running = was, queue_handed_over = 0 })
  elseif action == "status" then
    local list = {}
    for instance_name in pairs(runtime.instances) do
      list[#list + 1] = { name = instance_name, state = "running", sha256 = string.rep("a", 64) }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return json.encode(list)
  elseif action == "logs" then
    local instance = runtime.instances[name]
    if not instance then return json.encode({ ok = false, error = "service_unknown" }) end
    return json.encode({ ok = true, name = name, bytes = #instance.log, log = instance.log })
  end
  return json.encode({ ok = false, error = "invalid_service_action" })
end

-- The only place the allow list could leak into an operator's log.
local real_log = host.log
host.log = function(text)
  runtime.logged[#runtime.logged + 1] = tostring(text or "")
  if real_log then return real_log(text) end
end

-- ---- helpers over the node's real registry --------------------------------------------------
assert(json.decode(host.sql_exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
  "[]")).ok)

local function control(request)
  request.expected_revision = services.inventory().revision
  local answer = services.control(request, MASTER)
  if answer.ok ~= true then error("registry refused " .. tostring(request.action) .. ": " .. tostring(answer.error)) end
  return answer
end

local function stored_definition()
  for _, row in ipairs(services.inventory().services or {}) do
    if row.name == SERVICE then return row.definition, row.enabled end
  end
  return nil, nil
end

local function stored_config()
  local definition = stored_definition()
  return (definition and type(definition.config) == "table") and definition.config or {}
end

local function ask(args)
  return posting.answer(args, MASTER)
end

local function encode(value) return json.encode(value) end

-- ---- A. no component on this node: refused by name, nothing invented -------------------------
local missing = ask({ action = "status" })
eq(missing.ok, false, "status with no component is not ok")
eq(missing.error, "whatsapp_posting_component_missing", "and says which fact is missing")
eq(ask({ action = "set", enabled = true, allow = { "own" } }).error, "whatsapp_posting_component_missing",
  "set with no component is refused by the same name")

-- ---- B. the openclaw shape, reproduced: stored, enabled, no config at all --------------------
control({ action = "put", definition = { name = SERVICE } })
control({ action = "enable", name = SERVICE })
eq(#runtime.starts, 1, "the scratch component started once")
eq(runtime.starts[1].config, nil, "started with no config, exactly as the live definition does")
local initial = ask({ action = "status" })
eq(initial.ok, true, "status answers")
eq(initial.enabled, false, "posting is off: no post_transcripts key")
eq(initial.allow_count, 0, "and the allow list is empty")
eq(initial.posting, "off", "the component's health line says off too")
eq(initial.posted, 0, "posted=0 comes from that line")
eq(initial.connection, "running", "the component is running")
eq(initial.verified, true, "the running instance and the stored definition agree")

-- A switch that posts nowhere is refused by name, not stored.
local nowhere = ask({ action = "set", enabled = true })
eq(nowhere.ok, false, "turning posting on without an allow list is refused")
eq(nowhere.error, "posting_allow_required", "by name")
eq(stored_config().post_transcripts, nil, "and nothing was stored")
eq(#runtime.starts, 1, "and the component was not restarted")

-- ---- C. the switch turns it on, and the COMPONENT says so ----------------------------------
runtime.posted = 3 -- what the component's own counter says when it is asked again
local turned_on = ask({ action = "set", enabled = true, allow = { "own" }, alerts = true, language = "pt" })
eq(turned_on.ok, true, "the switch answers ok: " .. tostring(turned_on.error))
eq(turned_on.enabled, true, "posting is on")
eq(turned_on.posting, "on", "the health line the component printed says posting=on")
eq(turned_on.posted, 3, "and its own posted count is passed through")
eq(turned_on.written, true, "the answer says the definition was written")
eq(turned_on.restarted, true, "and that the component was restarted onto it")
eq(turned_on.allow_count, 1, "one allowed scope")
eq(turned_on.alerts, true, "alerts on")
eq(turned_on.language, "pt", "language pt")
local last_start = runtime.starts[#runtime.starts]
eq(#runtime.starts, 2, "the restart is one more start")
eq(last_start.config.post_transcripts, true, "the component was started with post_transcripts=true")
eq(encode(last_start.config.post_allow), encode({ "own" }), "and with the allow list it was given")
eq(last_start.config.alerts, true, "and with alerts=true")
eq(last_start.config.language, "pt", "and with language=pt")
local after_on = stored_config()
eq(after_on.post_transcripts, true, "the stored definition carries the gate")
eq(encode(after_on.post_allow), encode({ "own" }), "and the list")
local count_after_on = 0
for key in pairs(after_on) do count_after_on = count_after_on + 1 end
eq(count_after_on, 4, "the verb wrote exactly its four keys into a definition that had no config")

-- Asking for what is already true writes nothing and restarts nothing.
local again = ask({ action = "set", enabled = true, allow = { "own" }, alerts = true, language = "pt" })
eq(again.ok, true, "a no-op set is not a refusal")
eq(again.unchanged, true, "and says so")
eq(#runtime.starts, 2, "the component was not restarted for a no-op")

-- ---- D. every other config key is left alone ------------------------------------------------
control({ action = "disable", name = SERVICE })
control({ action = "put", definition = { name = SERVICE, description = "the account's component", config = {
  post_transcripts = true, post_allow = { "own" }, alerts = true, language = "pt",
  stream_edits = true, health_every_seconds = 60, held_chats = { GROUP },
} } })
control({ action = "enable", name = SERVICE })
local narrowed = ask({ action = "set", language = "en" })
eq(narrowed.ok, true, "one key can be changed alone: " .. tostring(narrowed.error))
local kept = stored_config()
eq(kept.language, "en", "the key that was asked for changed")
eq(kept.stream_edits, true, "stream_edits is untouched")
eq(kept.health_every_seconds, 60, "health_every_seconds is untouched")
eq(encode(kept.held_chats), encode({ GROUP }), "held_chats is untouched")
eq(kept.post_transcripts, true, "and so is the gate")
eq(#runtime.starts, 4, "changing a key restarts the component once")

-- ---- E. the allow list is validated as an allow-list ----------------------------------------
eq(#ask({ action = "set", allow = { "*" } }).allow, 1, "the wildcard is an accepted scope")
eq(ask({ action = "set", allow = { "5511999999999@s.whatsapp.net" } }).allow_count, 1, "an exact JID is accepted")
eq(ask({ action = "set", allow = { GROUP } }).allow_count, 1, "a group JID is accepted")
eq(ask({ action = "set", allow = { "5511999999999@lid" } }).allow_count, 1, "a LID is accepted")
eq(ask({ action = "set", allow = { "own", "own" } }).allow_count, 1, "a repeated scope collapses")

local SECRET_JID = "2411@evil.example"
local before_refusals = encode(stored_config())
local bad = ask({ action = "set", allow = { "own", SECRET_JID } })
eq(bad.ok, false, "an entry that is not a chat scope is refused")
eq(bad.error, "posting_allow_invalid", "by name")
eq(bad.index, 2, "and names the position that failed")
absent(encode(bad), "evil.example", "the refused entry is never echoed back")
eq(encode(stored_config()), before_refusals, "and nothing was stored")
eq(ask({ action = "set", allow = {} }).error, "posting_allow_required", "an empty list is refused by name")
local many = {}
for index = 1, posting.ALLOW_MAX + 1 do many[index] = "own" end
eq(ask({ action = "set", allow = many }).error, "posting_allow_too_many", "an oversized list is refused by name")
eq(ask({ action = "set", language = "fr" }).error, "posting_language_invalid", "a language the pipeline cannot decode is refused")
eq(ask({ action = "set", alerts = "yes" }).error, "posting_alerts_boolean_required", "alerts must be a boolean")
eq(ask({ action = "set", enabled = "yes" }).error, "posting_enabled_boolean_required", "enabled must be a boolean (the old door's own code)")
eq(ask({ action = "set" }).error, "posting_change_required", "a set that names nothing is refused")
eq(ask({ action = "frobnicate" }).error, "invalid_posting_action", "an unknown action is refused (the old door's own code)")
eq(encode(stored_config()), before_refusals, "none of those refusals changed the definition")
for _, line in ipairs(runtime.logged) do
  absent(line, "evil.example", "the allow list never reaches the node's log")
  absent(line, "5511999999999", "the allow list never reaches the node's log")
end

-- ---- F. who may change it -------------------------------------------------------------------
eq(posting.answer({ action = "status" }, { role = "guest", user_id = "g" }).error, "forbidden",
  "a guest cannot read the switch")
eq(posting.answer({ action = "set", enabled = false }, { role = "guest", user_id = "g" }).error, "forbidden",
  "nor change it")
eq(posting.answer({ action = "set", enabled = false }, { role = "master", user_id = "m", subagent = {} }).error,
  "forbidden", "nor can a child agent")
eq(posting.answer({ action = "status" }, {}).error, "forbidden", "nor a caller with no role at all")

-- The operator endpoint is the same gate: the route refuses the guest session before it reads anything.
local guest_session = users.login("guest")
local master_session = users.login("master")
local route_guest = wa_whatsapp_posting(json.encode({ action = "status" }), guest_session)
eq(json.decode(route_guest).error, "forbidden", "POST /whatsapp/posting refuses a guest session")
absent(route_guest, "5511999999999", "and its refusal carries no allow-list entry")
local route_master = json.decode(wa_whatsapp_posting(json.encode({ action = "status" }), master_session))
eq(route_master.ok, true, "and answers the master session")
eq(route_master.enabled, true, "with the state the component reports")
eq(json.decode(wa_whatsapp_posting("not json", master_session)).error, "invalid_posting_request",
  "a body that is not a request is refused by name")
eq(json.decode(wa_whatsapp_posting(json.encode({ action = "frobnicate" }), master_session)).error,
  "invalid_posting_action", "an unknown action too")

-- ---- G. unknown is not yes ------------------------------------------------------------------
local good_log = runtime.log_override
runtime.log_override = function() return "[    0.00s] clock: 1795447000000 ms since epoch\n[    0.01s] store: unavailable\n" end
local no_health = ask({ action = "set", alerts = false })
eq(no_health.ok, false, "a restart whose health line cannot be read is not a success")
eq(no_health.error, "whatsapp_posting_unverified", "it refuses by name")
eq(no_health.written, true, "and says the definition WAS written")
local status_blind = ask({ action = "status" })
eq(status_blind.posting, "unknown", "status reports the mode as unknown, not off")
eq(status_blind.unverified, "whatsapp_posting_health_unreadable", "and names why")
runtime.log_override = good_log

-- A log that carries only a PREVIOUS run's health line is not evidence about this one.
runtime.log_override = function()
  return "[    0.00s] clock: 1 ms since epoch\n[    0.02s] health: v=1 transcripts ok=0 last=- chars=0 failed=0"
    .. " last_failure=- reason=- posting=on posted=0 last_post=- index written=0 last=-\n"
    .. "[    0.00s] clock: 2 ms since epoch\n[    0.01s] store: unavailable\n"
end
eq(ask({ action = "status" }).posting, "unknown", "a health line from an earlier run than the last start is not read")
runtime.log_override = nil

-- ---- H. a component that refuses to start on the new definition -----------------------------
local before_restore = encode(stored_config())
local starts_before = #runtime.starts
runtime.fail_next_start = { ok = false, error = "component_start_refused" }
local refused = ask({ action = "set", alerts = true, language = "auto" })
eq(refused.ok, false, "a start that fails is a refusal")
eq(refused.error, "whatsapp_posting_start_refused", "by name")
eq(refused.restored, true, "and the previous definition was put back and started")
eq(#runtime.starts, starts_before + 1, "only the restore's start happened")
eq(encode(stored_config()), before_restore, "the stored definition is the old one again")
eq(encode(runtime.instances[SERVICE].config), before_restore, "and the running component is on it")

-- ---- I. the CLI is the same door ------------------------------------------------------------
eq(cli.run({ "status", "--json" }), 0, "wa whatsapp posting status --json succeeds")
eq(cli.run({ "frobnicate" }), 2, "an unknown verb is a usage refusal")
eq(cli.run({ "allow" }), 2, "allow without a list is a usage refusal")
eq(cli.run({ "alerts", "maybe" }), 2, "alerts needs on or off")
eq(cli.run({ "help" }), 0, "help is a request, never a change")
local init = host.read_file("lua/core/init.lua") or ""
contains(init, "whatsapp_posting_cli", "wa dispatches `whatsapp posting` to the module")
contains(init, "whatsapp posting status|on|off", "and names it in `wa help`")

-- ---- J. the removed connector is never called ------------------------------------------------
local real_getenv = host.getenv
local legacy = {
  WA_WHATSAPP_POSTING_URL = "http://127.0.0.1:1/", WA_WHATSAPP_ACCOUNT = "acct",
  WA_WHATSAPP_GENERATION = "2", WA_WHATSAPP_READ_TOKEN_FILE = "/tmp/read.token",
  WA_WHATSAPP_APPROVAL_TOKEN_FILE = "/tmp/approval.token",
}
host.getenv = function(name)
  if legacy[name] ~= nil then return legacy[name] end
  return real_getenv(name)
end
host.http = function(method, url, headers, body)
  runtime.http_calls[#runtime.http_calls + 1] = tostring(url)
  error("the removed connector must never be called: " .. tostring(url))
end
local with_legacy = ask({ action = "status" })
eq(with_legacy.ok, true, "status still answers with the connector's variables set")
ok(type(with_legacy.connector_removed) == "table", "it names them as stale configuration")
eq(#with_legacy.connector_removed.variables, 5, "all five of them")
eq(#runtime.http_calls, 0, "and nothing called that URL")
eq(ask({ action = "set", enabled = true, account = "acct" }).error, "whatsapp_posting_connector_removed",
  "a request carrying the removed API's fields is refused by name")
eq(#runtime.http_calls, 0, "still nothing called it")
host.getenv = real_getenv
-- The handler's own body, not the whole file: `host.http` is the node's, used by other routes.
local function function_body(source, name)
  local first = source:find("function " .. name .. "(", 1, true)
  if not first then return nil end
  local nextone = source:find("\nfunction ", first + 1, true)
  return source:sub(first, (nextone or #source) - 1)
end
local handler = function_body(host.read_file("lua/core/server.lua") or "", "wa_whatsapp_posting")
ok(type(handler) == "string" and #handler > 0, "the operator endpoint still exists")
absent(handler, "/operator/posting", "the handler no longer names the connector's operator route")
absent(handler, "WA_WHATSAPP_POSTING_URL", "nor reads its URL from the environment")
absent(handler, "host.http", "nor dials anything at all")
absent(handler, "getenv", "nor reads any environment variable")
contains(handler, "whatsapp_posting.lua", "it hands the request to the component's switch")

-- ---- K. parity with the old door, from its recorded answers ----------------------------------
local golden = json.decode(host.read_file("tests/fixtures/whatsapp-posting-old-door.json") or "")
ok(type(golden) == "table" and type(golden.answers) == "table", "the old door's recorded answers are a fixture")
local recorded = {}
for _, entry in ipairs(golden.answers) do recorded[entry.what] = entry.answer end
eq(recorded.forbidden_guest.error, "forbidden", "the fixture records the guest refusal")
eq(recorded.bad_action.error, "invalid_posting_action", "and the unknown action")
eq(recorded.bad_body.error, "invalid_posting_request", "and the unreadable body")
eq(recorded.non_boolean.error, "posting_enabled_boolean_required", "and the non-boolean switch")
eq(ask({ action = "frobnicate" }).error, recorded.bad_action.error, "the new door keeps that refusal word")
eq(ask({ action = "set", enabled = "yes" }).error, recorded.non_boolean.error, "and that one")
eq(json.decode(route_guest).error, recorded.forbidden_guest.error, "and the guest's")
-- Every field the old door answered that still means something is still answered, with its type.
local old_status = recorded.status_with_connector
ok(type(old_status) == "table", "the fixture records a status answer")
for _, field in ipairs({ "ok", "enabled" }) do
  ok(type(old_status[field]) == type(initial[field]), "status keeps the field `" .. field .. "` and its type")
end
ok(type(old_status.connection) == type(initial.connection), "status keeps `connection` (the component's live state)")
for _, field in ipairs({ "ok", "enabled" }) do
  ok(type(recorded.set_on[field]) == type(turned_on[field]), "set keeps the field `" .. field .. "` and its type")
end
eq(recorded.set_on.ok, true, "the recorded set answered ok")
eq(turned_on.ok, true, "and so does this one")

print("whatsapp posting toggle ok (" .. tostring(checks) .. " checks)")
