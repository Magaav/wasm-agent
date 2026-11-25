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


-- ---- 3. THE STAMP IS ONCE PER RELEASE, NOT ONCE PER TICK (Fable 24/11, the blocker on 6ae677dd) ---------------
-- MEASURED in review of that commit: taking the `due_at > now` filter off made EVERY pending resume selectable, and
-- `release_due` runs on every tick (2 s). A released row that stays pending - its session's lane busy with a kept
-- message, the plan's limit, anything - was stamped again every tick: ~300 copies and ~100 KB in a 10-minute lane.
local function release_opts(extra)
  local opts = {
    exec = function(sql, params) return json.decode(host.sql_exec(sql, json.encode(params))) end,
    query = function(sql, params) return json.decode(host.sql_query(sql, json.encode(params))) end,
    install = "/nonexistent-install-r8c",
  }
  for key, value in pairs(extra or {}) do opts[key] = value end
  return opts
end
-- ONE LINE PER RELEASE: every release text starts with the same 9 bytes, so counting those lines counts releases.
local function release_lines(text)
  local n = 0
  for line in tostring(text or ""):gmatch("[^\n]+") do if line:sub(1, 9) == "[deploy] " then n = n + 1 end end
  return n
end
local function released_notes(session)
  local path = pause.log_path()
  if type(path) ~= "string" then return 0 end
  local ok, body = pcall(host.read_file, path)
  if not ok or type(body) ~= "string" then return 0 end
  local n = 0
  for line in body:gmatch("[^\n]+") do
    if line:find('"released"', 1, true) and line:find(session, 1, true) then n = n + 1 end
  end
  return n
end

-- (i) RELEASE, THEN TEN MORE TICKS WITH THE SESSION'S LANE BUSY: the line is stamped ONCE.
local busy = memory.start_session("local", "chat", { id = "r8c-busy", user_id = "master", title = "busy" })
local busy_row = selfloop.schedule({ in_seconds = 60, reason = pause.RESUME_REASON, prompt = "resume" },
  { session_id = busy, user_id = "master" })
check(busy_row and busy_row.ok, "a resume is owed for the busy-lane case: " .. json.encode(busy_row))
host.sql_exec([[UPDATE self_wakes SET due_at=? WHERE id=?]], json.encode({ T0 + 600, busy_row.wake.id }))
local stamped = pause.release_due(T0 + 5, release_opts())
eq(stamped, 1, "the release stamps the one pending resume")
local after_one = rows("SELECT prompt FROM self_wakes WHERE id=?", { busy_row.wake.id })[1]
eq(release_lines(after_one.prompt), 1, "the row carries ONE release line")
local again = 0
for i = 1, 10 do again = again + (tonumber(pause.release_due(T0 + 5 + i, release_opts())) or 0) end
eq(again, 0, "ten further ticks with the lane still busy stamp NOTHING")
local after_ten = rows("SELECT prompt FROM self_wakes WHERE id=?", { busy_row.wake.id })[1]
eq(release_lines(after_ten.prompt), 1, "the prompt still carries the line exactly once, not eleven times")
eq(#after_ten.prompt, #after_one.prompt, "and not one byte more")
eq(released_notes(busy), 1, "the pause log has ONE released for the session")
print(string.format("row (i): one release + 10 ticks with the lane busy -> %d release line(s), %d -> %d bytes, %d 'released' note(s)",
  release_lines(after_ten.prompt), #after_one.prompt, #after_ten.prompt, released_notes(busy)))

-- (ii) PAUSE -> RELEASE -> PAUSE AGAIN -> RELEASE: one line per release, the newest first.
pcall(pause.record_pause, { to = "aaaa1111aaaa1111", source = "install" }, T0 + 20, busy, "master",
  { installed = { commit = "aaaa1111aaaa1111" } })
local rearmed = selfloop.schedule({ in_seconds = 60, reason = pause.RESUME_REASON, prompt = "resume after the second pause" },
  { session_id = busy, user_id = "master" })
check(rearmed and rearmed.ok, "the second pause re-arms the session: " .. json.encode(rearmed))
eq(tostring(rearmed.wake.id), tostring(busy_row.wake.id), "on the SAME row (the pause rewrites it)")
local cleared = rows("SELECT prompt FROM self_wakes WHERE id=?", { busy_row.wake.id })[1]
eq(release_lines(cleared.prompt), 0, "and the pause's own rewrite CLEARS the release mark")
local second = pause.release_due(T0 + 25, release_opts({ record = { commit = "bbbb5555bbbb5555" } }))
eq(second, 1, "the second release stamps again")
local two = tostring(rows("SELECT prompt FROM self_wakes WHERE id=?", { busy_row.wake.id })[1].prompt)
-- ONE RELEASE LINE IN THE ROW, AND IT IS THE NEWEST - not two, and not two of the first. The pause arms a resume by
-- REPLACING the row's prompt (`lua/core/selfloop.lua:592`, "SET status='pending', prompt=?"): the row is ONE
-- continuation document per cycle, so the earlier cycle's line does not survive the re-arm and prompts cannot grow
-- install after install. What must not happen - and does not - is the FIRST cycle's line appearing twice.
eq(release_lines(two), 1, "the second cycle's prompt carries ONE release line, not two")
local first_line = two:match("^([^\n]*)")
check(first_line:find(pause.INSTALLED, 1, true) == 1,
  "and it is the NEWEST release's line (installed: bbbb5555bbbb was aaaa1111aaaa): " .. first_line:sub(1, 120))
check(two:find(pause.UNKNOWN, 1, true) == nil, "not two of the first: the earlier release's line went with the prompt it was part of")
eq(released_notes(busy), 2, "while the pause log keeps one released per release, which is where the audit trail lives")
print(string.format("row (ii): pause -> release -> pause -> release -> %d release line(s), newest first: %s; %d 'released' note(s)",
  release_lines(two), first_line:sub(1, 44), released_notes(busy)))

print("deploy alive ok (" .. checks .. " checks, " .. skipped .. " skipped): a running deploy holds a paused session, a dead one "
  .. "releases it at once, and the release says what it can")

