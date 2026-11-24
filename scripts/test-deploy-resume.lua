-- A worker paused for a deploy is resumed when the deploy ENDS, not when the installer's bound runs out.
--
-- MEASURED (22/11). Every deploy of the night paused every running worker after its current step and
-- scheduled one wake to resume it. The wake was armed from the marker's BOUND - upgrade.sh writes 1800s - so a
-- four-minute deploy left its workers idle for another half hour, the orchestrator read that as "the scheduled
-- resume never fires", and resumed them by hand at 00:26Z. The workers were `wa chat --once` processes, which
-- had already exited by the time the wake was due; nothing about the resume may depend on them staying alive.
--
-- The rule this test holds, in the order real use takes it (schedule -> tick -> release -> dispatch):
--   * while the install is running (the marker is there), a resume wake keeps the time it was armed with;
--   * the moment the marker is gone (upgrade.sh removes it on exit), the NODE's own tick makes exactly those
--     rows due, and dispatches them in that same tick - the node performs the resume, so the paused process
--     can be gone;
--   * only the deploy-resume wakes are touched: another pending wake keeps its time.
--
-- Run from the repo root, in a scratch home (this row writes a ledger and a marker file):
--   WASM_AGENT_HOME=$(mktemp -d) WA_SCRIPT=scripts/test-deploy-resume.lua wa --db <that home>/t.db
local json = dofile("lua/vendor/json.lua")
local function refuse(why) print("REFUSED test-deploy-resume: " .. why); os.exit(2) end
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-deploy-resume")
if why_home then refuse(why_home) end

local pause = dofile("lua/core/deploy_pause.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local selfloop = dofile("lua/core/selfloop.lua")
selfloop.setup()

local checks = 0
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end

local T0 = 1800000000
selfloop.set_test_clock(function() return T0 end)
local session = memory.start_session("local", "chat",
  { id = "deploy-resume-session", user_id = "master", node_id = "test-node", title = "deploy resume" })
local ctx = { user_id = "master", role = "master", session_id = session }

-- The marker the installer writes, in this scratch home.
local marker_path = pause.path()
ok(type(marker_path) == "string" and marker_path ~= "", "the marker has a path in this home")
local function write_marker(since, bound)
  ok(host.write_file(marker_path, json.encode({ state = "deploy_pending", since = since,
    bound_seconds = bound or 1800, by = "upgrade.sh", from = "aaaaaaa", to = "bbbbbbbbbbbb", pid = 4242 })),
    "the marker was written")
end
local function clear_marker()
  -- Exactly what upgrade.sh's trap does on exit (scripts/lib/deploy-signal.sh, wa_deploy_signal_clear).
  host.exec("rm -f '" .. marker_path .. "'", "", 30)
  ok(pause.read(T0 + 6) == nil, "the marker is gone")
end

-- A paused turn schedules ONE wake, armed from the marker's bound (deploy_pause.at_boundary). This is that
-- row: due 1730s after the pause, which is how the half hour of idle work happened.
local resume = selfloop.schedule({ in_seconds = 1730, reason = pause.RESUME_REASON,
  prompt = "[deploy pending] continue the request" }, ctx)
ok(resume.ok, "a deploy-resume wake is scheduled: " .. json.encode(resume))
eq(resume.wake.due_at, T0 + 1730, "armed from the installer's bound, as at_boundary arms it")
-- ...and one unrelated pending wake, which must keep its own time.
local other = selfloop.schedule({ in_seconds = 1730, reason = "check the deploy", prompt = "look again" }, ctx)
ok(other.ok, "an unrelated wake is scheduled")

local dispatched = {}
local resources = dofile("lua/core/resources.lua")
local function fake_dispatch(row)
  dispatched[#dispatched + 1] = tostring(row.reason)
  -- A REAL DISPATCH HOLDS THE SESSION'S RUN CLAIM FOR THE TURN'S DURATION (lua/core/agent.lua takes `session:<id>`
  -- before any model call; rust/wa-capabilities/src/resources.rs). This stub takes it for real, through the same module
  -- and the same store, so a row that is "dispatching" here is shaped like the product's: dispatching WITH its claim,
  -- which nothing may call lost. Without that, the row looked like "dispatched and nothing happened" and the reclaim
  -- (rightly) revived it - the confusion that put main red on 24/11.
  pcall(resources.claim, { user_id = "master", session_id = row.session_id, run_id = "resume-turn-1" },
    { "session:" .. tostring(row.session_id) })
  return { accepted = true, run_id = 1 }
end

-- 1. The install is RUNNING: the marker is live, so nothing is released and nothing is dispatched early.
write_marker(T0 - 10, 1800)
local running = selfloop.tick({ now = T0 + 5, dispatch = fake_dispatch })
eq(running.released, 0, "a live deploy marker releases nothing")
eq(running.dispatched, 0, "and no wake fires early")
eq(#dispatched, 0, "the scheduler was not asked")

-- 2. The install ENDED (the marker is gone): the node's own tick makes the resume due and dispatches it in
-- the same pass - the worker process is not involved and does not have to exist any more.
clear_marker()
local ended = selfloop.tick({ now = T0 + 6, dispatch = fake_dispatch })
eq(ended.released, 1, "the deploy-resume wake is made due when the install ends")
eq(ended.dispatched, 1, "and dispatched by the same tick")
eq(#dispatched, 1, "the scheduler was asked once")
eq(dispatched[1], pause.RESUME_REASON, "and it was the deploy-resume wake, not another one")

-- 3. The unrelated wake kept its time: it is due at T0+1730 and not a moment before.
local later = selfloop.tick({ now = T0 + 1729, dispatch = fake_dispatch })
eq(later.dispatched, 0, "an unrelated wake does not fire when the deploy ends")
eq(#dispatched, 1, "so the scheduler was not asked again")
local due = selfloop.tick({ now = T0 + 1730, dispatch = fake_dispatch })
eq(due.dispatched, 1, "it still fires at its own time")
eq(dispatched[2], "check the deploy", "with its own reason")

-- 4. A marker whose bound has run out is not a live install: the reader already ignores it (decode says
-- `expired`), so a resume is released rather than held for ever by an installer that died before its trap ran.
write_marker(T0 + 1700, 60)
local stranded = selfloop.schedule({ in_seconds = 3600, reason = pause.RESUME_REASON,
  prompt = "[deploy pending] continue the request" }, ctx)
ok(stranded.ok, "a second deploy-resume wake is scheduled")
local expired = selfloop.tick({ now = T0 + 1801, dispatch = fake_dispatch })
eq(expired.released, 1, "an expired marker does not hold a resume for ever")
eq(expired.dispatched, 1, "it is dispatched")
eq(dispatched[#dispatched], pause.RESUME_REASON, "and it is the resume that was dispatched")

-- 5. The release is a no-op when there is nothing to release (and it must not touch the ledger for nothing):
-- no pending resume row, no update.
local quiet = selfloop.tick({ now = T0 + 4000, dispatch = fake_dispatch })
eq(quiet.released, 0, "a release with no pending resume row changes nothing")

-- 6. The wake the pause really schedules names this reason: at_boundary and the release cannot drift apart.
local boundary = pause.at_boundary({ session_id = session, user_id = "master" }, "carry on", {
  now = T0 + 5000,
  read = function()
    return { since = T0 + 5000, bound_seconds = 1800, to = "bbbbbbbbbbbb", by = "upgrade.sh" }
  end,
  notes = function() end,
  schedule = function(args) return { wake = { id = "w-1", reason = args.reason, in_seconds = args.in_seconds } } end,
})
ok(boundary and boundary.wake, "the pause scheduled its one wake")
eq(boundary.wake.reason, pause.RESUME_REASON, "and it is the reason the release matches on")

print("deploy resume ok (" .. checks .. " checks)")
