-- THE DEPLOY THAT IS RUNNING HOLDS A PAUSED SESSION (r8c 21:15-21:27Z, Fable 24/11).
--
-- MEASURED on this node: the sentinel claimed the request for 39e862d6, started scripts/deploy.sh DETACHED and moved the
-- request to `done/` 8 s later; deploy.sh fetched and COMPILED for 430 s and wrote the deploy-pending marker only
-- after the build. In that window there was no request, no claimed request and no marker, so release_due released two
-- paused sessions, each ran a paid resume turn, found installed.txt unchanged and was told "[deploy] the update did not
-- happen" - and the marker then paused them again for a second release. One install, two turns each.
--
-- This row pins the fact that closes it (scripts/lib/deploy-alive.sh writes it, lua/core/deploy_pause.lua reads it):
-- the reader's judgement (a bare pid is not enough - start time, zombie, recycled pid, the record's own bound, and a
-- machine with no /proc), the wait every caller sees, and the release that must NOT happen while the deploy runs and
-- must happen once it is gone.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local guard_reason = home_guard.reason({ home = os.getenv("WASM_AGENT_HOME") or "",
  scratch = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or "" })
if guard_reason then
  error("this test writes a ledger: it refuses to run (" .. guard_reason .. ")")
end

local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()
local pause = dofile("lua/core/deploy_pause.lua")
local wait = dofile("lua/core/deploy_wait.lua")
local paths = dofile("lua/core/paths.lua")
local ALIVE = pause.alive_path()
local MARKER = paths.data() .. "/" .. pause.FILE

local checks, skipped = 0, 0
local function check(value, label) checks = checks + 1; if not value then error(label, 2) end end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function skip(what, why) skipped = skipped + 1; print("SKIP deploy-alive: " .. what .. " (" .. why .. ")") end
local function decode(raw) if type(raw) == "string" then return json.decode(raw) end return raw end
local function rows(sql, params) return decode(host.sql_query(sql, json.encode(params or {}))) end
local function alive_file(fields)
  local body = fields and json.encode(fields) or ""
  check(host.write_file(ALIVE, body) == true, "the deploy-running file is written at " .. ALIVE)
end
local function clear_alive() pcall(host.remove_file, ALIVE) end

local T0 = 1700000000
selfloop.set_test_clock(function() return T0 end)
local me = host.process_identity and host.process_identity() or nil
local my_pid = tonumber(me and me.pid) or 0
local my_start = my_pid > 0 and select(1, pause.pid_start(my_pid)) or nil
check(pause.pid_start(1) ~= nil, "this machine's process table can be read (/proc/1/stat): the pid rules below mean something")

-- ---- 1. THE READER'S JUDGEMENT (constraints a and b) ----------------------------------------------
clear_alive()
local none, why = pause.alive(T0)
eq(none, nil, "no deploy-running file is no deploy")
eq(why, "absent", "and it says so (" .. tostring(why) .. ")")

my_pid = my_pid > 0 and my_pid or 1
my_start = my_start or select(1, pause.pid_start(my_pid))
alive_file({ pid = my_pid, pid_start = my_start, since = T0 - 10, bound_seconds = 1800, commit = "39e862d6", by = "test" })
local live, live_why = pause.alive(T0)
check(type(live) == "table", "a live pid with its own start time IS a running deploy (" .. tostring(live_why) .. ")")
eq(tostring(live.source), "deploy", "and it answers in the shape a marker or a claimed request does")
eq(tostring(live.to), "39e862d6", "naming the commit the deploy is installing")
eq(tonumber(live.pid), my_pid, "and the pid it proved alive")

-- a pid that is not running: the deploy died or was killed, and the release happens at once
local dead
for candidate = 4194000, 4194304 do
  if not host.read_file("/proc/" .. candidate .. "/stat") then dead = candidate; break end
end
if dead then
  alive_file({ pid = dead, pid_start = 1, since = T0 - 10, bound_seconds = 1800 })
  local gone, gone_why = pause.alive(T0)
  eq(gone, nil, "a pid that is not running is not a deploy")
  eq(gone_why, "not_running", "and it says the process is gone (" .. tostring(gone_why) .. ")")
else
  skip("the dead-pid rule", "every pid in the probe range is in use on this host")
end

-- a LIVE pid with the WRONG start time: the same number, a different process - which is why a bare pid is not enough
if my_pid > 0 and my_start then
  alive_file({ pid = my_pid, pid_start = my_start + 7, since = T0 - 10, bound_seconds = 1800 })
  local recycled, recycled_why = pause.alive(T0)
  eq(recycled, nil, "a live pid whose start time does not match is NOT this deploy")
  eq(recycled_why, "pid_recycled", "and it says the pid was recycled (" .. tostring(recycled_why) .. ")")
end

alive_file({ pid = my_pid, pid_start = my_start, since = T0 - 1900, bound_seconds = 1800 })
local expired, expired_why = pause.alive(T0)
eq(expired, nil, "a record past its own bound is not a deploy")
eq(expired_why, "expired", "however alive the pid looks (" .. tostring(expired_why) .. ")")

alive_file({ pid_start = my_start, since = T0 - 10, bound_seconds = 1800 })
eq(pause.alive(T0), nil, "a record with no pid holds nothing")
eq(select(2, pause.alive(T0)), "no_pid", "and says why")

-- A MACHINE WITH NO PROCESS TABLE: the record's bound is the only thing that ends the hold, and the answer says it is
-- unverified instead of pretending.
alive_file({ pid = dead or 4194000, since = T0 - 10, bound_seconds = 1800 })
local unverified, unverified_why = pause.alive(T0, { proc_available = false })
check(type(unverified) == "table" and unverified.unverified == true,
  "with no /proc the deploy is held until the record's own bound, marked unverified (" .. tostring(unverified_why) .. ")")
eq(tostring(unverified.source), "deploy", "and it is still an install in progress for every caller")

-- ---- 2. WHAT EVERY CALLER SEES: waiting, refusing, and NOT releasing -------------------------------
alive_file({ pid = my_pid, pid_start = my_start, since = T0 - 10, bound_seconds = 1800, commit = "39e862d6" })
pcall(host.remove_file, MARKER)
local seen = pause.waiting(T0)
check(type(seen) == "table" and tostring(seen.source) == "deploy",
  "a running deploy is a reason this node starts no new turn: " .. json.encode(seen))
local refused = wait.refusal(seen, T0)
check(type(refused) == "string" and refused:find("^deploy_waiting:") ~= nil, "and the refusal keeps its name: " .. tostring(refused))
check(refused:find("39e862d6", 1, true) ~= nil, "naming the install")
check(refused:find("request withdraw", 1, true) == nil,
  "and NOT telling the caller to withdraw a request that is a detached process: " .. tostring(refused):sub(1, 160))

-- A PAUSED SESSION IS NOT RELEASED WHILE THE DEPLOY RUNS, and is released once it is gone.
local session = memory.start_session("local", "chat", { id = "r8c-alive", user_id = "master", title = "alive" })
local armed = selfloop.schedule({ in_seconds = 60, reason = pause.RESUME_REASON, prompt = "resume" },
  { session_id = session, user_id = "master" })
check(armed and armed.ok, "a resume is owed: " .. json.encode(armed))
-- Armed for later, the way a pause arms it (the release is what makes it due now).
host.sql_exec([[UPDATE self_wakes SET due_at=? WHERE id=?]], json.encode({ T0 + 600, armed.wake.id }))
local sent = { count = 0, ids = {} }
local function counted(row) sent.count = sent.count + 1; sent.ids[#sent.ids + 1] = tostring(row.id); return { accepted = true, run_id = sent.count } end
local released = pause.release_due(T0 + 2, { exec = function(sql, params) return json.decode(host.sql_exec(sql, json.encode(params))) end,
  query = function(sql, params) return json.decode(host.sql_query(sql, json.encode(params))) end })
eq(released, 0, "release_due releases NOTHING while the deploy runs (the 7-minute hole)")
local held = rows("SELECT id, status, due_at FROM self_wakes WHERE id=?", { armed.wake.id })[1]
eq(tostring(held.status), "pending", "the resume keeps its own row and its own time")
eq(tonumber(held.due_at), T0 + 600, "exactly as the pause armed it")

-- THE INSTALL IS OVER: the deploy cleared its state (its exit trap does) and the marker is gone.
clear_alive()
local out, spent = (function()
  sent = { count = 0, ids = {} }
  local answer = selfloop.tick({ now = T0 + 3, dispatch = counted })
  return answer, sent.count
end)()
eq(out.released, 1, "with the deploy gone, the release happens (one row)")
eq(spent, 1, "and exactly ONE resume turn is spent")
eq(tostring(sent.ids[1]), tostring(armed.wake.id), "the row the pause armed")
local done_row = rows("SELECT prompt FROM self_wakes WHERE id=?", { armed.wake.id })[1]
check((done_row.prompt or ""):find(pause.UNKNOWN, 1, true) ~= nil,
  "and the line says what it can (no pause record here, so: the pause ended): " .. tostring(done_row.prompt):sub(1, 120))

print("deploy alive ok (" .. checks .. " checks, " .. skipped .. " skipped): a running deploy holds a paused session, a dead one "
  .. "releases it at once, and the release says what it can")

