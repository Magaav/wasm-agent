-- WHEN A PAUSE IS RELEASED, AND HOW MANY PAID RESUME TURNS ONE INSTALL COSTS (r8c, the SECOND part).
--
-- Fable 24/11: the open mechanism. Session 9a7edd49 got resume wakes DELIVERED at 18:18:24, 18:18:45 and 18:19:42
-- around ONE install (42507780), with resume messages in the session at 18:15:43, 18:18:32 and 18:19:00. The question
-- to MEASURE before designing anything: is there a phase of a real install in which nothing is waiting, so
-- release_due fires in the middle of it, and does each delivery cost a model request?
--
-- A real install's signals, in the order the product produces them (lua/core/deploy_wait.lua's own two lanes, then
-- the installer's marker):
--
--   requests/<id>.json   the sentinel's box, before the request is claimed                (lane "requests")
--   claimed/<id>.json    renamed there BY the sentinel before it performs, and kept until
--                        the install ends - the phase in which neither the request nor the
--                        installer's marker exists                                     (lane "claimed")
--   deploy-pending.json  written by scripts/upgrade.sh before its wait, removed on exit
--   done/<id>.json       the install is over: nothing waits, and the release is DUE
--
-- MEASURED here, on the node's own files and the node's own tick: the release fires in NEITHER of the first three
-- phases - the claim alone already says "an install is coming" - so the suspected gap does not exist in this tree and
-- a "two consecutive ticks" rule would change nothing. What it does cost is at the END: one resume turn per paused
-- session per install, no matter how many times that session paused inside the window.
--
-- Everything is the product's: the marker file (its own path and shape), the sentinel's box (its own lanes), the pause
-- (deploy_pause.at_boundary, the call a step boundary makes), the release and the dispatch (selfloop.tick, the call
-- the node's placement thread makes every 2 s, rust/wa-capabilities/src/serve.rs). `dispatch` is a counter, so no turn
-- is paid: here the COUNT is the measurement, and scripts/test-deploy-release-node.sh measures separately that each
-- dispatched resume turn is exactly one model request at the stub.
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
local paths = dofile("lua/core/paths.lua")
local data = paths.data()
local MARKER = data .. "/" .. pause.FILE
local BOX = data .. "/sentinel/requests"
local CLAIMED = data .. "/sentinel/claimed"
local DONE = data .. "/sentinel/done"

local checks = 0
local function check(value, label) checks = checks + 1; if not value then error(label, 2) end end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function decode(raw) if type(raw) == "string" then return json.decode(raw) end return raw end
local function rows(sql, params) return decode(host.sql_query(sql, json.encode(params or {}))) end
local function write(path, body) check(host.write_file(path, body) == true, "written: " .. path) end
local function rm(path) pcall(host.remove_file, path) end

local T0 = 1700000000
selfloop.set_test_clock(function() return T0 end)
local SHA = "deadbeefcafe0000000000000000000000000000"
local REQUEST_ID = "1700000000000000000-4242-1"
local sent = { count = 0, ids = {} }
local function counted(row)
  sent.count = sent.count + 1
  sent.ids[#sent.ids + 1] = tostring(row.id)
  return { accepted = true, run_id = sent.count }
end
local function tick(now)
  sent = { count = 0, ids = {} }
  local out = selfloop.tick({ now = now, dispatch = counted })
  return out, sent.count
end

-- The four files a deploy lives through, written the way their own writers write them.
local request_body = { verb = "deploy", target_commit = SHA, queued_at = T0, reason = "r8c: the install this row is about" }
local function request_waiting() write(BOX .. "/" .. REQUEST_ID .. ".json", json.encode(request_body)) end
local function request_claimed()
  write(CLAIMED .. "/" .. REQUEST_ID .. ".json", json.encode(request_body))
  rm(BOX .. "/" .. REQUEST_ID .. ".json")
end
local function request_done()
  -- The install is over: the request is in done/ and in NEITHER lane.
  rm(CLAIMED .. "/" .. REQUEST_ID .. ".json")
  rm(BOX .. "/" .. REQUEST_ID .. ".json")
  write(DONE .. "/" .. REQUEST_ID .. ".json", json.encode({ verb = "deploy", target_commit = SHA, queued_at = T0, ok = true }))
end
local function marker_up(since)
  write(MARKER, json.encode({ to = SHA:sub(1, 12), state = "deploy_pending", since = since or T0,
    bound_seconds = 900, by = "scripts/test-resume-window.lua" }))
end
local function marker_down() rm(MARKER) end

-- One turn of `session` reaching its step boundary. The product's own call, with a fresh `self` each time (a turn is
-- a run), and the real marker and box on disk.
local function pause_a_turn(session, now)
  local self = { session_id = session, user_id = "master" }
  local answer = pause.at_boundary(self, "finish the install-aware request", { now = now, no_record = true,
    notes = function() return nil end,
    schedule = function(args) return selfloop.schedule(args, { session_id = session, user_id = "master" }) end })
  check(type(answer) == "table" and type(answer.wake) == "table", "the turn paused and armed one resume: " .. json.encode(answer))
  return answer.wake.id
end
local function pending(session)
  return rows([[SELECT id, status, due_at FROM self_wakes WHERE session_id=? AND reason=? AND status='pending'
    ORDER BY created_at]], { session, pause.RESUME_REASON })
end

-- ---- 1. THE PHASES OF ONE REAL INSTALL, and whether the release fires in any of them --------------
local phase_session = memory.start_session("local", "chat", { id = "r8c-phase", user_id = "master", title = "phase" })
request_waiting()
marker_up(T0)
local armed = pause_a_turn(phase_session, T0)
eq(#pending(phase_session), 1, "the paused turn armed exactly one resume")
local armed_row = pending(phase_session)[1]

-- (a) THE REQUEST IS WAITING IN THE SENTINEL'S BOX.
request_waiting()
local out, spent = tick(T0 + 2)
eq(out.released, 0, "(a) a request waiting in the box releases nothing")
eq(spent, 0, "(a) and spends no resume turn")
eq(tostring(pending(phase_session)[1].due_at), tostring(armed_row.due_at), "(a) the armed resume keeps its own time")

-- (b) THE SENTINEL HAS CLAIMED IT AND IS PERFORMING IT - NO MARKER YET. This is the phase Fable asked about: the
-- request has left `requests/`, the installer has not written `deploy-pending.json`, and nothing but the claim says an
-- install is coming. MEASURED: the claim is enough, and the release does NOT fire.
marker_down()
request_claimed()
out, spent = tick(T0 + 4)
eq(out.released, 0, "(b) the CLAIMED phase (request out of the box, no marker yet) releases nothing")
eq(spent, 0, "(b) and spends no resume turn: the gap is not a gap")

-- (c) THE INSTALLER'S MARKER IS UP (the swap).
marker_up(T0 + 4)
out, spent = tick(T0 + 6)
eq(out.released, 0, "(c) a live marker releases nothing")
eq(spent, 0, "(c) and spends no resume turn")

-- (d) THE INSTALL IS OVER: the installer's marker is gone and the sentinel has moved the request to `done/`.
marker_down()
request_done()
out, spent = tick(T0 + 8)
eq(out.released, 1, "(d) an install that is over releases the pause (one row)")
eq(spent, 1, "(d) and spends exactly ONE resume turn")
eq(tostring(sent.ids[1]), tostring(armed), "(d) it is the resume this pause armed")

-- ---- 2. A RESUME THAT IS DUE WHILE A DEPLOY WAITS SPENDS NO MODEL REQUEST --------------------------
-- The other half of "did each of those deliveries make a model request?": a resume row whose time has come while the
-- install waits is offered to the gate and given back without starting a turn - the resume ends BEFORE its first
-- request. MEASURED on the node's own tick: no paid turn, the row still pending, the same row, no duplicate armed.
local due_session = memory.start_session("local", "chat", { id = "r8c-due", user_id = "master", title = "due" })
request_waiting()
marker_down()
local due_wake = pause_a_turn(due_session, T0 + 30)
-- Make it due now: the pause arms it for when the install should be over, and an install that outlasts its own marker
-- is exactly the shape the live incident had. The product's own column, moved the way time moves it.
host.sql_exec([[UPDATE self_wakes SET due_at=? WHERE id=?]], json.encode({ T0 + 31, due_wake }))
out, spent = tick(T0 + 32)
eq(spent, 0, "a due resume starts no turn while the request waits (no model request)")
eq(out.deploy_waiting, 1, "the tick says the deploy is waiting (its gate)")
local after = rows("SELECT id, status, due_at FROM self_wakes WHERE id=?", { due_wake })[1]
eq(tostring(after.status), "pending", "the resume keeps its own row")
eq(#pending(due_session), 1, "and the session still has exactly ONE resume row (the deferral armed no duplicate)")
request_done()
out, spent = tick(T0 + 34)
eq(spent, 1, "and once the install is over that same row runs ONCE")
eq(tostring(sent.ids[1]), tostring(due_wake), "the row that was held, not a second one")

-- ---- 3. ONE PAUSE THAT PAUSED AGAIN: how many PAID resume turns does ONE install cost? -------------
-- THE 9a7edd49 SHAPE: a session whose turn paused, resumed and paused again inside one install's window. Each pause
-- goes through the product's own path (deploy_pause.at_boundary). What the scheduler does with the second and the
-- third is MEASURED here: selfloop.schedule keeps AT MOST ONE pending resume per session (its r6 rule), so the session
-- is owed ONE paid turn, not one per pause.
local multi = memory.start_session("local", "chat", { id = "r8c-multi-turns", user_id = "master", title = "multi" })
request_waiting()
marker_up(T0 + 40)
local three = {}
for i = 1, 3 do three[i] = pause_a_turn(multi, T0 + 40 + i) end
eq(#pending(multi), 1, "three paused turns of ONE session leave ONE pending resume (the scheduler's own rule)")
local multi_row = pending(multi)[1]
eq(tostring(multi_row.id), tostring(three[1]), "and it is the FIRST row armed, not the last one")

-- THE INSTALL ENDS: one release, and the session gets ONE paid resume turn for the whole install.
marker_down()
request_done()
out, spent = tick(T0 + 50)
eq(out.released, 1, "one install releases ONE resume of that session")
eq(spent, 1, "so ONE paid resume turn for the whole install, however many times the session paused in it")
eq(#pending(multi), 0, "and nothing is left pending from that install")
eq(#three, 3, "the shape was three paused turns, as the live session had resume rows")
eq(tostring(three[2]), tostring(three[1]),
  "the SECOND pause was folded into the same row (schedule's one-pending-resume rule), not queued beside it")
eq(tostring(three[3]), tostring(three[1]), "and so was the third")

marker_down()
rm(BOX .. "/" .. REQUEST_ID .. ".json")
rm(CLAIMED .. "/" .. REQUEST_ID .. ".json")
print("resume window ok (" .. checks .. " checks): the release does not fire while an install waits, is claimed or "
  .. "installs; a resume held by a waiting deploy spends no model request; and an install releases ONE resume per "
  .. "paused session, however many times that session paused inside it")

