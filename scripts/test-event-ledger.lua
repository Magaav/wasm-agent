-- `wa events`: THE LEDGER - one row, one schema, one feed, and the event wake that reads it.
--
-- What this row proves, and why each check exists:
--
--   * one schema: a fact written by a producer (a landing step, a preflight, a worker that finished) comes
--     back with every field it was given, and the feed's order is the order things happened;
--   * the producer is refused by name when it is wrong: an unknown KIND (the set a subscriber filters on),
--     an empty verdict and a step that is not a slug are refusals, and a refusal writes nothing - a fact log
--     with a hole in it reads as "nothing happened";
--   * the cursor is an id, so --since is exact: a follower never re-prints a row and never skips one;
--   * the subscription is the wake table that already exists (docs/SELF-LOOP.md): a session that asked for
--     `land.*` is woken by a landing fact and NOT by a mission one, and one that asked for `land.installed`
--     is not woken by `land.merged`. No second wake mechanism is built here;
--   * the CLI: a --kind outside the allow-list exits 2, `record` writes one row, `record` without a verdict
--     is refused, and `--follow --seconds 0` answers instead of hanging;
--   * CROSS-PROCESS (the point of the whole file): `wa events --follow --json` is started as a process of its
--     own, this row writes two facts afterwards, and the follower's own output carries both of them. A feed
--     visible only inside the process that wrote it would not be a feed.
--
--   WASM_AGENT_LUA_ROOT=<repo> WA_FAST_BIN=<wa binary> WA_SCRIPT=scripts/test-event-ledger.lua wa --db <scratch>

local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-event-ledger.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local ledger = dofile("lua/core/event_ledger.lua")
ledger.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", want " .. tostring(expected) .. ")")
end
local function contains(text, needle, label)
  ok(tostring(text or ""):find(needle, 1, true) ~= nil,
    label .. " (looked for " .. tostring(needle) .. " in " .. tostring(text):sub(1, 300) .. ")")
end

local function shq(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end

local function sql(statement, params)
  local answer = host.sql_query(statement, json.encode(params or {}))
  local value = type(answer) == "string" and json.decode(answer) or answer
  return type(value) == "table" and value or {}
end
local function count_rows()
  local rows = sql("SELECT COUNT(*) AS n FROM ledger_events", {})
  return tonumber(rows[1] and rows[1].n) or 0
end

-- ---------------------------------------------------------------- case 1: one schema, every field back
local started = ledger.record({ kind = "land", step = "started", result = "green", mission = "land-builtin",
  branch = "change/land-builtin", sha = "8082b42e", detail = "landing started: 1 branch",
  source = "wa land", at = 1795300000 })
ok(type(started) == "table" and tonumber(started.id) and tonumber(started.id) > 0,
  "a fact comes back with the id the feed uses as a cursor")
local rows = ledger.read({ kinds = { "land" }, limit = 5 })
eq(#rows, 1, "the one fact written is the one fact read")
local row = rows[1]
eq(row.kind, "land", "kind is stored")
eq(row.step, "started", "step is stored")
eq(row.result, "green", "result is stored")
eq(row.mission, "land-builtin", "mission is stored")
eq(row.branch, "change/land-builtin", "branch is stored")
eq(row.sha, "8082b42e", "sha is stored")
eq(row.detail, "landing started: 1 branch", "detail is stored")
eq(row.source, "wa land", "source is stored")
eq(tonumber(row.at), 1795300000, "the producer's own clock is kept, not replaced by the host's")
contains(ledger.text(row), "land  started  green", "the text line names kind, step and verdict")
contains(ledger.text(row), "branch=change/land-builtin", "the text line names the branch")
contains(ledger.text(row), "sha=8082b42e", "the text line names the sha")
local as_json = json.decode(ledger.json_line(row))
eq(as_json.step, "started", "the JSON line carries the step")
eq(as_json.result, "green", "the JSON line carries the verdict")
eq(as_json.branch, "change/land-builtin", "the JSON line carries the branch")
eq(as_json.sha, "8082b42e", "the JSON line carries the sha")
eq(as_json.mission, "land-builtin", "the JSON line carries the mission")

-- ---------------------------------------------------------------- case 2: a wrong fact is refused by name
local before = count_rows()
local unknown_kind = ledger.record({ kind = "lande", step = "started", result = "green" })
contains(unknown_kind.error, "kind_unknown: lande",
  "an unknown kind is refused by its own name (the set a subscriber filters on is closed)")
local no_result = ledger.record({ kind = "land", step = "merged", result = "" })
eq(no_result.error, "result_required", "a fact with no verdict is refused")
local bad_step = ledger.record({ kind = "land", step = "not a slug", result = "green" })
contains(bad_step.error, "step_invalid", "a step that is not a slug is refused")
eq(count_rows(), before, "a refusal wrote nothing (a hole in a fact log reads as nothing happened)")

-- ---------------------------------------------------------------- case 3: the cursor and the filters
ledger.record({ kind = "land", step = "merged", result = "green", sha = "aaaa1111", at = 1795300010 })
ledger.record({ kind = "mission", step = "preflight", result = "green", mission = "other", at = 1795300020 })
ledger.record({ kind = "land", step = "installed", result = "green", sha = "aaaa1111", at = 1795300030 })
ledger.record({ kind = "land", step = "main-health", result = "red", sha = "aaaa1111",
  detail = "test-land-plan.lua", at = 1795300040 })
local all = ledger.read({ limit = 50 })
eq(all[#all].step, "main-health", "a page is answered oldest first (a feed reads forwards)")
local land_only = ledger.read({ kinds = { "land" }, limit = 50 })
for _, entry in ipairs(land_only) do eq(entry.kind, "land", "the kind filter keeps only the kinds asked for") end
eq(#land_only, 4, "and keeps every land row (started, merged, installed, main-health)")
local since_cursor = ledger.read({ since = all[3].id, limit = 50 })
eq(#since_cursor, #all - 3, "since <id> answers strictly newer rows, so a follower neither repeats nor skips")
eq(since_cursor[1].id, all[4].id, "the first row after the cursor is the next one written")
local newest_two = ledger.read({ limit = 2 })
eq(#newest_two, 2, "the limit is honoured")
eq(newest_two[2].step, "main-health", "and it is the newest rows, still oldest first")
eq(ledger.newest(), all[#all].id, "newest() is the cursor a follower starts from")
local by_sha = ledger.read({ sha = "aaaa1111", limit = 50 })
eq(#by_sha, 3, "the sha filter answers the rows about one commit")

-- ---------------------------------------------------------------- case 4: the event wake is the wake table
-- A WAKE BELONGS TO A SESSION, so the row makes two real ones (memory.start_session is what the CLI does
-- at a chat's first turn): a subscription that cannot name its session is refused by selfloop and would
-- prove nothing.
local watcher = memory.start_session("local", "chat",
  { id = "ledger-row-session", user_id = "master", node_id = "test-node", title = "the ledger row" })
local ctx = { session_id = watcher, user_id = "master", role = "master" }
local scheduled = selfloop.schedule({ reason = "wait for the landing", on = { "land.*" } }, ctx)
ok(type(scheduled) == "table" and scheduled.error == nil, "the subscription is accepted for a real session")
local wake = sql("SELECT * FROM self_wakes WHERE session_id=? AND status='pending'", { "ledger-row-session" })
eq(#wake, 1, "the subscription is one pending wake row")
eq(tonumber(wake[1].due_at) or 0, 0, "an event wake is not due before its event")
ledger.record({ kind = "mission", step = "preflight", result = "green", mission = "other", at = 1795300050 })
local after_mission = sql("SELECT due_at FROM self_wakes WHERE session_id=?", { "ledger-row-session" })
eq(tonumber(after_mission[1].due_at) or 0, 0, "a mission fact does not wake a land.* subscriber")
ledger.record({ kind = "land", step = "install-verified", result = "green", sha = "bbbb2222", at = 1795300060 })
local after_land = sql("SELECT due_at, event_json FROM self_wakes WHERE session_id=?", { "ledger-row-session" })
ok((tonumber(after_land[1].due_at) or 0) > 0, "a land fact makes the land.* subscriber due")
local identity = json.decode(after_land[1].event_json or "{}")
eq(identity.topic, "land.install-verified", "the wake carries the topic and never the fact's text")
ok(identity.id ~= nil, "and the event's identity")
-- A SECOND subscriber on ONE step is not woken by a different step of the same kind.
local one_step_session = memory.start_session("local", "chat",
  { id = "ledger-row-one-step", user_id = "master", node_id = "test-node", title = "one step" })
selfloop.schedule({ reason = "only the install", on = { "land.installed" } },
  { session_id = one_step_session, user_id = "master", role = "master" })
ledger.record({ kind = "land", step = "merged", result = "green", sha = "cccc3333", at = 1795300070 })
local one_step = sql("SELECT due_at FROM self_wakes WHERE session_id=?", { "ledger-row-one-step" })
eq(tonumber(one_step[1].due_at) or 0, 0, "a land.installed subscriber is not woken by land.merged")

-- ---------------------------------------------------------------- case 5: follow, bounded
local printed = {}
ledger.follow({ kinds = { "land" }, since = 0, polls = 1, limit = 100, sleep = function() end,
  out = function(line) printed[#printed + 1] = line end })
ok(#printed >= 4, "follow with since=0 prints the backlog it was asked for")
local cursor = ledger.newest()
local later = {}
ledger.record({ kind = "land", step = "done", result = "green", sha = "dddd4444", at = 1795300080 })
ledger.follow({ kinds = { "land" }, since = cursor, polls = 1, sleep = function() end,
  out = function(line) later[#later + 1] = line end })
eq(#later, 1, "follow after a cursor prints only the new row")
contains(later[1], "done", "and it is the row that just happened")

-- ---------------------------------------------------------------- case 6: the CLI
eq(ledger.cli({ "events", "--kind", "lande" }), 2, "the CLI refuses a kind outside the allow-list with exit 2")
eq(ledger.cli({ "events", "record", "--kind", "land", "--step", "blocked", "--result", "green",
  "--branch", "change/x", "--sha", "eeee5555" }), 0, "the CLI records a fact")
eq(ledger.cli({ "events", "record", "--kind", "land", "--step", "blocked" }), 2,
  "the CLI refuses a record with no verdict")
local cli_rows = ledger.read({ step = "blocked", limit = 5 })
eq(#cli_rows, 1, "the CLI's fact is in the ledger the feed reads")
eq(ledger.cli({ "events", "--kind", "land", "--follow", "--seconds", "0" }), 0,
  "--follow with a zero budget answers instead of hanging")
eq(ledger.cli({ "events", "nonsense" }), 2, "an unknown flag exits 2")

-- ---------------------------------------------------------------- case 7: another process sees the rows
local binary = host.getenv("WA_FAST_BIN") or ""
if binary == "" then
  print("SKIP test-event-ledger: no WA_FAST_BIN, so the follower cannot run as a process of its own "
    .. "(the feed's cross-process half is UNPROVEN here, not passed)")
else
  local db = host.getenv("WASM_AGENT_DB") or ""
  local home = host.getenv("WASM_AGENT_HOME") or ""
  ok(db ~= "" and home ~= "", "the row knows its own ledger and home (the follower reads the same ledger)")
  local follower = host.paths().home .. "/follower.sh"
  local out = host.paths().home .. "/follower.out"
  local script = table.concat({ "#!/usr/bin/env bash",
    "set -uo pipefail",
    "exec env -u WA_SCRIPT -u WA_FAST_ROW_ENV -u WASM_AGENT_DB \\",
    "  WASM_AGENT_LUA_ROOT=" .. shq(host.getenv("WASM_AGENT_LUA_ROOT") or "") .. " \\",
    "  HOME=" .. shq(host.paths().home) .. " WASM_AGENT_HOME=" .. shq(home) .. " \\",
    "  " .. shq(binary) .. " --db " .. shq(db) .. " events --follow --kind land --json --poll 0.1 --seconds 6",
    "" }, "\n")
  host.write_file(follower, script)
  host.exec("chmod +x " .. shq(follower), "")
  host.exec("nohup bash " .. shq(follower) .. " > " .. shq(out) .. " 2>&1 &", "")
  host.sleep(700)
  ledger.record({ kind = "land", step = "pushed", result = "green", sha = "ffff6666", detail = "from the row", at = 1795300090 })
  ledger.record({ kind = "land", step = "installed", result = "green", sha = "ffff6666", detail = "from the row", at = 1795300091 })
  host.sleep(2000)
  local text = host.read_file(out) or ""
  contains(text, "\"step\":\"pushed\"", "the other process printed the row this one wrote after it started")
  contains(text, "\"step\":\"installed\"", "and the second one")
  contains(text, "\"id\"", "every line is one JSON object with its id")
end

-- ---------------------------------------------------------------- case 8: the two producers of a `mission` row
-- A worker that finished and a preflight that ran are facts the loop used to keep in a file only a reader could
-- find. Both write their own row now, and a preflight's verdict is never green by accident: the script's exit
-- code decides it (0 green, 1 red, anything else refused).
local land_module = dofile("lua/core/land.lua")
land_module.root_dir = host.paths().home .. "/ledger-land"
local marked, mark_why = land_module.ready_mark("change/probe", "abcdef0123", nil)
ok(marked, "the ready line is recorded (" .. tostring(mark_why) .. ")")
local finished = nil
for _, row in ipairs(ledger.read({ kinds = { "mission" }, step = "finished", limit = 20 })) do
  if tostring(row.mission) == "probe" then finished = row end
end
ok(finished ~= nil, "a finished worker is a mission row")
eq(finished and finished.result, "ready", "with the verdict the ready line carries")
eq(finished and finished.branch, "change/probe", "and its branch")
eq(finished and finished.sha, "abcdef0123", "and the sha the worker declared")
contains(finished and finished.detail, "READY change/probe abcdef0123", "the detail is the line itself")

local missions = host.paths().home .. "/missions-probe"
local dir = missions .. "/probe"
host.exec("mkdir -p " .. shq(dir), "")
host.write_file(missions .. "/preflight.sh", [==[#!/usr/bin/env bash
set -uo pipefail
dir="$(cd "$(dirname "$0")" && pwd)/$1"
mode=$(cat "$dir/mode" 2>/dev/null || echo green)
if [ "$mode" = red ]; then
  printf '%s\n' '{"ok":false,"main_sha":"aaaa1111","failed":[{"row":"scripts/test-x.lua"}]}' > "$dir/preflight.json"
  exit 1
fi
printf '%s\n' '{"ok":true,"main_sha":"aaaa1111","tree_sha":"bbbb2222","failed":[]}' > "$dir/preflight.json"
echo '{"ok":true}'
exit 0
]==])
local mission_module = dofile("lua/core/mission.lua")
local green = mission_module.preflight({ name = "probe", root = missions })
eq(green.preflight, "green", "the preflight itself answered green")
local green_row = nil
for _, row in ipairs(ledger.read({ kinds = { "mission" }, step = "preflight", limit = 20 })) do
  if tostring(row.mission) == "probe" and tostring(row.result) == "green" then green_row = row end
end
ok(green_row ~= nil, "a green preflight is a mission row")
eq(green_row and green_row.sha, "bbbb2222", "the row names the tree it judged")
host.write_file(dir .. "/mode", "red\n")
local red = mission_module.preflight({ name = "probe", root = missions })
eq(red.preflight, "red", "the preflight answered red")
local red_row = nil
for _, row in ipairs(ledger.read({ kinds = { "mission" }, step = "preflight", limit = 20 })) do
  if tostring(row.mission) == "probe" and tostring(row.result) == "red" then red_row = row end
end
ok(red_row ~= nil, "a red preflight is a mission row")
contains(red_row and red_row.detail, "scripts/test-x.lua", "and names the row that made it red")

if failed > 0 then
  print(string.format("event ledger: %d of %d checks FAILED", failed, checks))
  os.exit(1)
end
print(string.format("event ledger ok (%d checks)", checks))
