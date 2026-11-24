-- A deploy has to replace the node, and a turn runs inside that node: the swap kills it wherever it
-- is. The old answer was an idle gate that waited for every turn to END, which starved deploys behind
-- long sessions (measured on wasm_the_first: 14 min, 37 min, and a 15-minute watchdog calling the
-- deploy "silent" while it was only waiting). The other answer - kill the turn and announce it - is
-- what wave 2b made visible and still loses the turn.
--
-- This module is the third answer, and the one that was chosen by measurement: the installer writes a
-- named `deploy pending` marker BEFORE it waits, the turn loop asks at each step boundary (between
-- decisions, never mid-call), and a session that sees it pauses after the current step, writes a
-- checkpoint to its notes, schedules ONE wake to resume the same request, and ends the turn cleanly -
-- a paused turn, not a failed one. The node then reaches idle within one step instead of one turn's
-- lifetime, the swap happens inside its bound, and the session continues from its own transcript when
-- the node is back.
--
-- What makes it safe:
--   * the marker carries its writer, its time and a BOUND; a marker older than the bound is ignored, so
--     a crashed installer cannot freeze every session on the node;
--   * a subagent never pauses (its parent owns the continuation), so a child cannot strand itself;
--   * the pause schedules at most one wake per run (`self.deploy_pause`), and a wake it cannot schedule
--     is said out loud, never swallowed;
--   * the request is replayed from the transcript and the notes checkpoint, not invented: the wake's
--     prompt is the session's own request, marked as an automated continuation.
local json = dofile("lua/vendor/json.lua")

local M = {}

M.FILE = "deploy-pending.json"
M.DEFAULT_BOUND = 900
-- How soon a turn paused for a WAITING REQUEST asks to be looked at again (see resume_seconds).
M.WAIT_RESUME_SECONDS = 60
M.WAKE_MARK = "[deploy pending]"
-- The reason a paused turn gives the one wake it schedules. It is a constant because it is also the KEY a
-- later reader matches on: `selfloop.tick` releases exactly these rows when the install ends (release_due).
M.RESUME_REASON = "deploy pending: resume after the node swap"

function M.path()
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if not ok then return nil end
  return paths.data() .. "/" .. M.FILE
end

-- Decode and judge a marker. Pure: `now` and `read` are arguments so a test needs no filesystem.
-- Returns nil, reason when there is nothing to honour; the marker table when there is.
function M.decode(text, now, bound_default)
  if type(text) ~= "string" or text == "" then return nil, "absent" end
  local ok, marker = pcall(json.decode, text)
  if not ok or type(marker) ~= "table" then return nil, "unreadable" end
  local since = tonumber(marker.since) or 0
  if since <= 0 then return nil, "no_since" end
  local bound = tonumber(marker.bound_seconds) or tonumber(bound_default) or M.DEFAULT_BOUND
  if bound <= 0 then return nil, "no_bound" end
  if now > since + bound then return nil, "expired" end
  if marker.state ~= nil and marker.state ~= "deploy_pending" then return nil, "not_a_deploy" end
  marker.since = since
  marker.bound_seconds = bound
  return marker
end

function M.read(now, read)
  local path = M.path()
  if not path then return nil, "no_path" end
  local reader = read or (host and host.read_file)
  if type(reader) ~= "function" then return nil, "unreadable" end
  local ok, text = pcall(reader, path)
  if not ok then return nil, "unreadable" end
  return M.decode(text, now or os.time(), M.DEFAULT_BOUND)
end

-- THE OTHER HALF OF THE SIGNAL: A REQUEST THAT IS STILL WAITING (22/11).
--
-- The marker above is written by the INSTALLER, and the installer only runs after the sentinel has
-- performed the request - so it covers the swap and never the wait. Measured twice on this laptop (22/11
-- 09:43Z and 10:01Z, ~/.wasm-agent/sentinel/sentinel.log): a deploy request waited 34 and 30 minutes with
-- "held: node busy" while three workers ran, because while a request is merely held there is no marker, so
-- no running turn was asked to pause, and every resume wake was released at once ("the marker is gone").
-- lua/core/deploy_wait.lua reads the sentinel's own request box, which is there for the whole wait.
--
-- One predicate, so no caller can honour half of it: an install and a waiting request are the same answer
-- to "must this node start a turn?".
local request_module
local function request_reader()
  if request_module == nil then
    local loaded, module = pcall(dofile, "lua/core/deploy_wait.lua")
    request_module = (loaded and type(module) == "table") and module or false
  end
  return request_module or nil
end

function M.waiting(now, opts)
  opts = opts or {}
  now = tonumber(now) or os.time()
  local marker = (opts.read or M.read)(now)
  if marker then return marker end
  local module = request_reader()
  if not module then return nil end
  local read = opts.read_request or module.read
  local found = read(now, opts.request)
  if found then return found end
  return nil
end

-- How long after the pause the session asks to continue. Long enough for a swap and a restart, short
-- enough that a deploy that failed still gives the session its turn back; the marker's own bound wins.
function M.resume_seconds(marker, now)
  -- A pause for a REQUEST is not a pause for a swap that is already under way: the install has not started,
  -- so the honest arm is the shortest one - the node looks again in a minute. It does not lose the promise:
  -- while the deploy is still waiting or claimed or installing, lua/core/selfloop.lua's tick starts no turn
  -- and run_wake gives the row back with a new time, so the wait is a poll of one row a minute, not a
  -- half-hour of idle work (the 22/11 measurement that made release_due exist).
  if marker.source == "request" or marker.source == "claimed" then return M.WAIT_RESUME_SECONDS end
  local left = (tonumber(marker.since) or 0) + (tonumber(marker.bound_seconds) or M.DEFAULT_BOUND) - (now or os.time())
  return math.max(60, math.min(math.floor(left) + 30, 1800))
end

function M.prompt(request, marker)
  local asked = tostring(request or ""):sub(1, 7000)
  return table.concat({
    M.WAKE_MARK .. " The node is installing a new build (" .. tostring(marker.to or marker.commit or "a new commit")
      .. "), so this turn paused after its current step - nothing was cut mid-call.",
    "This is an automated continuation of the same request, not a new one. Re-establish the real state",
    "from the machine first (files, `git status`, processes), then continue the request below and say",
    "plainly what had already been done before the pause.",
    "",
    asked,
  }, "\n")
end

function M.say(marker)
  local left = math.max(0, (tonumber(marker.since) or 0) + (tonumber(marker.bound_seconds) or M.DEFAULT_BOUND) - os.time())
  return "deploy pending: the node is installing a new build; paused after this step and scheduled a resume"
    .. (marker.to and (" (target commit " .. tostring(marker.to):sub(1, 12) .. ")") or "")
    .. string.format("; the install bound is %ds, %ds left", tonumber(marker.bound_seconds) or M.DEFAULT_BOUND, left)
end

-- What a paused turn says. An INSTALL keeps the sentence it always had (an operator and a test both read
-- it); a WAITING request says the thing a reader has to be told - "waiting for the install of <sha>" -
-- because nothing is being installed yet: the node is waiting to be allowed to.
function M.say_wait(marker, now)
  now = tonumber(now) or os.time()
  if marker.source ~= "request" and marker.source ~= "claimed" then return M.say(marker) end
  local module = request_reader()
  local described = module and module.say(marker, now)
    or ("waiting for the install of " .. tostring(marker.to or "an unnamed commit"))
  return "deploy waiting: " .. described .. "; this turn paused after its step and scheduled a resume, so the"
    .. " node can go idle and the install can start"
    .. string.format(" (the wait is bounded: %ds from the request)", tonumber(marker.bound_seconds) or M.DEFAULT_BOUND)
end

-- The hook the turn loop calls at the top of a round. Returns nil when there is nothing to honour, or
-- a table {text=..., wake=..., wake_error=...} that the caller turns into the run's clean ending.
-- `opts` exists for the test (scripts/test-deploy-pause.lua) and for nothing else: a real caller passes
-- nothing, so the marker is the host's file, the schedule is selfloop's, and the clock is os.time().
function M.at_boundary(self, request, opts)
  opts = opts or {}
  if not self or self.subagent then return nil end
  if self.deploy_pause then return nil end -- one pause per run
  local now = opts.now or os.time()
  -- AN OPERATOR'S TURN IS PAUSED ONLY FOR THE REAL SWAP (22/11, review MUST 2).
  --
  -- The two signals are not the same emergency. A REQUEST that is only waiting needs the node to stop starting
  -- turns - not to cut the turn a person is in the middle of: their multi-step work would be ended after every
  -- step for as long as the wait lasts (minutes), and a person who is present can finish a step and let go.
  -- The INSTALLER's marker is the launch sequence itself, and that pauses everybody, as it always did. So an
  -- `operator_present` run asks the marker alone here, and everything automatic asks both.
  local marker
  if self.operator_present then
    marker = (opts.read or M.read)(now)
  else
    marker = M.waiting(now, opts)
  end
  if not marker then return nil end
  self.deploy_pause = marker
  local text = M.say_wait(marker, now)
  -- WHERE THIS SESSION SAID IT PAUSED (22/11). A pause ends the turn, so the node's own health cannot say
  -- afterwards which sessions paused and which simply kept working - and the sentinel's status has to name
  -- the holders that keep the node busy AND tell a paused holder from a working one, because the sentinel's
  -- 3-minute bound may only pass over sessions that are already paused. One file per session, written where
  -- the pause is decided: <data>/deploy-paused/<session>.json (read by rust/wa-sentinel/src/main.rs).
  if not opts.no_record then pcall(M.record_pause, marker, now, self.session_id, self.user) end
  -- The checkpoint the resumed turn reads: the goal, where it stopped and what it had already done.
  local notes = opts.notes or function()
    local selfloop = dofile("lua/core/selfloop.lua")
    return selfloop.notes_append({ text = table.concat({
      "## Deploy pause " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
      "- paused after a step boundary for a node install (marker " .. tostring(marker.by or "upgrade.sh")
        .. ", target " .. tostring(marker.to or "unknown") .. ")",
      "- the turn ended cleanly and one wake was scheduled to resume the same request",
      "- goal (the user's request): " .. tostring(request or ""):gsub("%s+", " "):sub(1, 400),
    }, "\n") }, { session_id = self.session_id, user_id = self.user })
  end
  pcall(notes)
  local wake, wake_error
  local schedule = opts.schedule or function(args)
    local selfloop = dofile("lua/core/selfloop.lua")
    return selfloop.schedule(args, { session_id = self.session_id, user_id = self.user })
  end
  local ok, answer = pcall(schedule, {
      in_seconds = M.resume_seconds(marker, now),
      reason = M.RESUME_REASON,
      prompt = M.prompt(request, marker),
    })
  if ok and type(answer) == "table" and type(answer.wake) == "table" then wake = answer.wake
  else wake_error = tostring(ok and (type(answer) == "table" and (answer.error or json.encode(answer)) or answer) or answer) end
  M.last_wake = wake
  if wake_error then text = text .. "; the resume wake could NOT be scheduled: " .. wake_error:sub(1, 200) end
  return { text = text, wake = wake, wake_error = wake_error, marker = marker }
end

-- WHEN THE RESUME HAPPENS. A pause is a promise to continue when the INSTALL ends, not when the installer's
-- own idle BOUND runs out - and those are different numbers by a factor of a deploy. `resume_seconds` has to
-- guess before it knows (it arms one wake with a clock, because a paused turn is about to end), so the wake is
-- armed for `left + 30` where `left` comes from the marker's bound: upgrade.sh writes 1800s, and on 22/11 that
-- meant every worker paused by a four-minute deploy sat idle for another half hour - which the orchestrator
-- read as "the scheduled resume never fires" and fixed by hand (00:26Z). The honest moment is observable, so
-- it is read instead of guessed: the installer removes the marker on exit (upgrade.sh's trap), and the node's
-- own tick - not the paused process, which is gone under `wa chat --once` - makes those rows due the moment
-- the marker is no longer there. Whatever shape the paused run had, the resume is performed by the node.
--
-- The sentence a turn that did NOT start returns, or nil when nothing is waiting. One function, so the chat
-- refusal, the wake deferral and the run-time gate cannot say different things: the words are
-- lua/core/deploy_wait.lua's `refusal`, and this is only where they are found from.
function M.refuse(now, opts)
  local wait = M.waiting(now, opts)
  if not wait then return nil end
  local module = request_reader()
  local text = module and module.refusal and module.refusal(wait, now) or nil
  if not text then
    text = "deploy_waiting: waiting for the install of "
      .. tostring(wait.to and tostring(wait.to):sub(1, 12) or "an unnamed commit")
      .. ". This node starts no new turn while a build is waiting for it or being installed - a turn in"
      .. " flight is exactly what keeps the node from going idle - and this turn did not start. Nothing was"
      .. " lost: this is a wait, not a failure. "
      .. ((request_reader() and request_reader().RETRY) or "retry when idle")
  end
  return text, wait
end

-- A RUN WHOSE SESSION CLAIM IS BUSY WHILE A BUILD WAITS OR IS BEING INSTALLED (23/11).
--
-- MEASURED (avell, 23/11 ~14:2xZ): the pause ENDED the workers components-calls-cheap (d2d69ff3) and
-- release-linux-reads-the-receipt (0b8c9d78), and both ended rc=1 with
-- `run_resource_refused: {"error":"resource_busy", "key":"session:0b8c9d78-..."}` while the node held each
-- session after the pause. The harness's auto-continues hit that claim until they ran out, so a worker that had
-- paused to let the install happen was DEAD when it ended - the opposite of what the pause promised it.
--
-- The claim belongs to the turn the deploy paused, and the install is what ends it. So this is the same answer
-- the pre-run gate gives: a wait, not a failure. The caller decides what to do with it (nothing ran, so nothing
-- is lost and the same request runs again after the swap); it is here, in the one module that knows what
-- "a build is waiting" means, so no caller can invent a second spelling of it.
--
-- `opts` exists for the test (scripts/test-deploy-pause.lua) and for nothing else.
function M.claim_wait(claimed, now, opts)
  opts = opts or {}
  -- ONLY A BUSY CLAIM: every other refusal (`resource_store_failed`, a claim the host could not grant) is a
  -- different fact and stays the caller's failure. unknown is not yes, and a wrong claim is not a wait.
  if type(claimed) ~= "table" or claimed.error ~= "resource_busy" then return nil end
  local refused = M.refuse(now, opts)
  if not refused then return nil end
  return refused
end

-- THE ONE TEST FOR "the node refused this run because a build is waiting for it or being installed".
--
-- Both sentences start with the same two words spelled two ways: `deploy_waiting:` is lua/core/deploy_wait.lua's
-- (the pre-run gate, the scripted CLI's exit 2) and `deploy waiting:` is M.say_wait's (a turn that paused at its
-- own step). The CLI's exit code and the wake's deferral have to agree about which refusals are a WAIT, so the
-- test is here and both of them ask it - a second spelling of it is how the two would drift.
function M.is_refusal(text)
  if type(text) ~= "string" then return false end
  return text:match("^deploy[_ ]wait") ~= nil
end

-- WHERE THE SESSION SAID IT PAUSED, for the sentinel's own bound.
--
-- The node's `/health` says which sessions are BUSY; it cannot say which of them stopped on purpose, because a
-- paused turn has ended. The sentinel needs exactly that distinction: after its bound (3 minutes) it may pass
-- over holders that are already paused, and it must not pass over a holder that is still working. One small
-- file per session, written at the moment the pause is decided and named after the session, so two sessions
-- pausing at once never write the same file. The reader is `wa-sentinel status` and its dispatcher
-- (rust/wa-sentinel/src/main.rs), and both only trust a record at or after the request they are holding - a
-- record left by an earlier deploy says nothing about this one.
function M.paused_dir()
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if not ok then return nil end
  return paths.data() .. "/" .. (request_reader() and request_reader().PAUSE_SUBDIR or "deploy-paused")
end

function M.record_pause(marker, now, session_id, user)
  if type(session_id) ~= "string" or session_id == "" then return nil end
  local dir = M.paused_dir()
  if not dir then return nil end
  if type(host) ~= "table" or type(host.write_file) ~= "function" then return nil end
  local safe = session_id:gsub("[^%w%-_]", "")
  if safe == "" then return nil end
  local path = dir .. "/" .. safe .. ".json"
  local ok = pcall(host.write_file, path, json.encode({
    session = session_id,
    since = tonumber(now) or os.time(),
    to = marker.to,
    source = marker.source or "install",
    request = marker.id,
    by = tostring(user or marker.owner or ""),
  }))
  if ok then return path end
  return nil
end

-- A RESUME THAT IS NOT PENDING IS A DEBT THE NODE PAYS (23/11).
--
-- MEASURED on avell, three times in one evening: session 603425eb paused for the install of 7e38abe9 at
-- 19:29:43Z and sat TWO HOURS; 66c0d5c1 paused at 20:19:38Z and sat the same; this mission's own session paused
-- at ~22:0xZ and was resumed by the orchestrator and no node. Each had scheduled its resume, the request it
-- paused for reached the sentinel's `done/`, and `wa session status` then answered `0 wakes pending`: the resume
-- row was cut by the very install it paused for and left `unknown` ("dispatch interrupted; not replayed"), which
-- is by design never replayed.
--
-- The debt is read from the ledger once nothing waits, and paid under FOUR rules, each of which was a defect
-- Fable found in the first version (23/11 ~22:35Z) and each of which is tested:
--
--   1. A WINDOW (M.RESUME_WINDOW_SECONDS, 6 h) on the row's own `created_at`, and only for a session that still
--      exists and is not parked. Without it the first tick after an install on EVERY node at G would wake every
--      session that ever lost a resume - paid model turns, days later, acting on stale requests. Rows older than
--      the window are retired ONCE by a migration that says how many it retired;
--   2. A CHAIN of at most M.RESUME_MAX_REARMS (2) re-arms per pause, counted on the row's own `attempts` and
--      spaced by a backoff. The re-armed wake is itself a resume row, so without the cap a session that can
--      never run (gone, provider down) is re-armed every tick for ever; after the cap the row is
--      `resume_abandoned`, its pause record says so, and the health line counts it;
--   3. AN OPERATOR'S CANCEL IS FINAL. `cancelled` is re-armed only when the NODE cancelled it - the run's own
--      'cancelled before execution' (lua/core/selfloop.lua, the dispatch cut before it started) - and never a
--      bare 'cancelled', which is what `wa wake cancel` and an escalation write (lua/core/selfloop.lua:612, :822).
--      Re-arming over a person's decision would override them, which no repair may do;
--   4. NOTHING IS RE-ARMED WHILE A BUILD WAITS OR INSTALLS: that is the phase the pause is for.
M.RESUME_WINDOW_SECONDS = 6 * 3600

-- HOW LONG A `dispatching` ROW MAY STAY WITHOUT A TURN (24/11, Fable's review of r5). `selfloop.M.stale_seconds()`
-- is `max(60, WA_SELF_WAKE_STALE_SECONDS or 1800)` - 1800 s, i.e. the same knob reconcile uses; r5 hardcoded 300,
-- which was both the wrong number and the wrong owner. Read here through the same variable, because this module
-- cannot load selfloop (selfloop loads this one).
function M.wait_stale_seconds()
  local raw
  if type(host) == "table" and type(host.getenv) == "function" then
    local ok, value = pcall(host.getenv, "WA_SELF_WAKE_STALE_SECONDS")
    if ok then raw = value end
  end
  if raw == nil and os and os.getenv then raw = os.getenv("WA_SELF_WAKE_STALE_SECONDS") end
  return math.max(60, tonumber(raw) or 1800)
end
M.RESUME_MAX_REARMS = 2
M.RESUME_BACKOFF_SECONDS = 30
M.MIGRATION_MARKER = "resume-migration-1"

-- The lost rows this module is allowed to act on: `unknown` and `failed` always, and `cancelled` only when the
-- NODE cancelled the dispatch. The predicate is here, in one place, because the migration and the per-tick pass
-- must agree about which rows are debts.
local LOST_WHERE = "reason=? AND (status IN ('unknown','failed') OR (status='cancelled' AND last_error LIKE 'cancelled before execution%'))"

local function sweep_stamp_path()
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if not ok then return nil end
  return paths.data() .. "/pause-sweep.last"
end

local function marker_path()
  local ok, paths = pcall(dofile, "lua/core/paths.lua")
  if not ok then return nil end
  return paths.data() .. "/" .. M.MIGRATION_MARKER
end

local function migrated(opts)
  if type(opts.migrated) == "function" then return opts.migrated() end
  local path = marker_path()
  if not path then return true end -- no path: nothing to migrate against, and never migrate twice-blind
  local reader = host and host.read_file
  if type(reader) ~= "function" then return true end
  local ok, text = pcall(reader, path)
  return ok and type(text) == "string" and text ~= ""
end

local function record_migrated(opts, count)
  if type(opts.migrate) == "function" then return opts.migrate(count) end
  local path = marker_path()
  if not path then return end
  local writer = host and host.write_file
  if type(writer) ~= "function" then return end
  pcall(writer, path, json.encode({ at = os.time(), retired = count }))
end

-- Every pause record the node owes, abandoned ones included, for the health line's `abandoned: n`.
function M.mark_abandoned(session, reason, opts)
  opts = opts or {}
  local dir = M.paused_dir()
  if not dir then return nil end
  local reader = opts.read_file or (host and host.read_file)
  local writer = opts.write_file or (host and host.write_file)
  if type(reader) ~= "function" or type(writer) ~= "function" then return nil end
  local safe = tostring(session or ""):gsub("[^%w%-_]", "")
  if safe == "" then return nil end
  local path = dir .. "/" .. safe .. ".json"
  local ok, text = pcall(reader, path)
  local record = {}
  if ok and type(text) == "string" then
    local decoded_ok, decoded = pcall(json.decode, text)
    if decoded_ok and type(decoded) == "table" then record = decoded end
  end
  record.session = session
  record.abandoned = true
  record.abandoned_reason = tostring(reason or ""):sub(1, 300)
  record.abandoned_at = os.time()
  pcall(writer, path, json.encode(record))
  return path
end

-- `opts` exists for the test (scripts/test-deploy-pause.lua): exec, query, schedule, the session check, the
-- migration marker and the clock are injected; a real caller passes nothing and gets the host's ledger,
-- selfloop's scheduler and os.time().
function M.ensure_resumes(now, opts)
  opts = opts or {}
  now = tonumber(now) or os.time()
  local exec = opts.exec or host.sql_exec
  local query = opts.query or host.sql_rows
  if type(exec) ~= "function" or type(query) ~= "function" then
    return { error = "no_ledger", rearmed = 0 }
  end
  local cutoff = now - M.RESUME_WINDOW_SECONDS
  -- 1. THE ONE-TIME MIGRATION: rows older than the window are retired, and it says how many.
  local migration = 0
  if not migrated(opts) then
    local retired = exec([[UPDATE self_wakes SET status='superseded', last_error='superseded: too old to resume',
      updated_at=? WHERE ]] .. LOST_WHERE .. [[ AND created_at<?]], { now, M.RESUME_REASON, cutoff })
    migration = tonumber(type(retired) == "table" and retired.changes or 0) or 0
    record_migrated(opts, migration)
    if type(host) == "table" and type(host.log) == "function" then
      pcall(host.log, string.format(
        "deploy pause: migration: %d lost resume row(s) older than %ds marked superseded (too old to resume)",
        migration, M.RESUME_WINDOW_SECONDS))
    end
  end
  -- THE ONE INVARIANT (r5, 24/11): EVERY RESUME ROW REACHES A TERMINAL STATE INSIDE THE WINDOW.
  --
  -- A row that is not terminal and is past its own bound is LOST, not waiting: inside the window it is re-armed
  -- (under the chain rule below); outside it, it is retired. Two states can be lost without anything else noticing:
  --
  --   * `dispatching` with no turn started: reconcile is the owner of that answer (`selfloop.lua`, `stale_seconds`,
  --     300 s by default), but it lives in the tick's inline path while the seam's plan owns the other one, so a node
  --     whose component bytes are older than that code never reconciles. MEASURED: ae2a9231 held `dispatching`,
  --     attempts 1, chain 0, last_error `deploy ended: resumed now`, and never ran a turn.
  --   * `pending` long past its due time: while a deploy waits the tick re-stamps every overdue row and dispatches
  --     none (`selfloop.lua:1386-1391`). MEASURED: a 22/11 row, due 2026-11-22 10:45Z, attempts 1, last_error
  --     `deploy_waiting: ...`, rewritten by every install since.
  local stale_secs = tonumber(opts.stale_seconds) or M.wait_stale_seconds()
  local reclaimed = 0
  -- RECLAIM ONLY "DISPATCHED AND NOTHING HAPPENED" (24/11, Fable's review of r5). A resume row leaves
  -- `dispatching` at the END of its turn, not at the start (`selfloop.lua:1200`/`:1509` claim it, `:1214`/`:1355`
  -- finish it), so a row may legitimately be `dispatching` for the whole turn - and most worker turns are longer
  -- than any stale bound. Reclaiming on age alone would declare such a turn lost and pay a SECOND resume turn
  -- beside it. So the age is only a filter; the decision needs the session to show no activity since the row was
  -- dispatched: no message at or after its `updated_at`, which is ae2a9231's exact shape (dispatched, and
  -- `last_error = 'deploy ended: resumed now'` with nothing written afterwards).
  local stale_rows = query([[SELECT id, session_id, updated_at FROM self_wakes
    WHERE reason=? AND status='dispatching' AND updated_at<?]], { M.RESUME_REASON, now - stale_secs }) or {}
  for _, row in ipairs(stale_rows) do
    local session = tostring(row.session_id or "")
    local dispatched_at = tonumber(row.updated_at) or 0
    local quiet = false
    if session ~= "" then
      local seen = query([[SELECT COUNT(*) AS n FROM messages WHERE session_id=? AND created_at>=?]],
        { session, dispatched_at }) or {}
      quiet = (tonumber(seen[1] and seen[1].n) or 0) == 0
    end
    if quiet then
      local changed = exec([[UPDATE self_wakes SET status='unknown',
        last_error='dispatch interrupted; not replayed', updated_at=? WHERE id=? AND status='dispatching']],
        { now, row.id })
      reclaimed = reclaimed + tonumber(type(changed) == "table" and changed.changes or 0)
    end
  end
  pcall(exec, [[UPDATE self_wakes SET status='superseded', due_at=NULL, last_error='superseded: too old to fire',
    updated_at=? WHERE reason=? AND status='pending' AND created_at<?]], { now, M.RESUME_REASON, cutoff })
  if M.waiting(now, opts) then return { waiting = true, rearmed = 0, migration = migration, stale = reclaimed } end
  -- THE CHAIN IS `resume_chain`, NOT `attempts` (24/11): `attempts` counts dispatch attempts and reaches the
  -- hundreds on a real ledger, so reading it here abandoned 46 live resumes on the first tick after an install.
  local lost = query([[SELECT id, session_id, owner, resume_chain FROM self_wakes WHERE ]] .. LOST_WHERE
    .. [[ AND created_at>=?]], { M.RESUME_REASON, cutoff }) or {}
  local schedule = opts.schedule
  if type(schedule) ~= "function" then
    schedule = function(args, session, user)
      return dofile("lua/core/selfloop.lua").schedule(args, { session_id = session, user_id = user })
    end
  end
  local exists = opts.session_exists
  if type(exists) ~= "function" then
    exists = function(session)
      local ok, row = pcall(function() return dofile("lua/core/memory.lua").session(session) end)
      return ok and type(row) == "table"
    end
  end
  local rearmed, abandoned = 0, 0
  for _, row in ipairs(lost) do
    local session = tostring(row.session_id or "")
    if session ~= "" and exists(session) then
      -- A PARKED session is one nobody may resume: the operator held it (lua/core/session_park.lua), and the
      -- tick skips its rows for the same reason.
      local parked = query("SELECT session_id FROM self_wake_pauses WHERE session_id=? LIMIT 1", { session }) or {}
      local live = query([[SELECT id FROM self_wakes WHERE session_id=? AND reason=?
        AND status IN ('pending','dispatching') LIMIT 1]], { session, M.RESUME_REASON }) or {}
      if #parked == 0 and #live == 0 then
        local chain = (tonumber(row.resume_chain) or 0) + 1
        if chain > M.RESUME_MAX_REARMS then
          -- 2. THE CHAIN IS SPENT: this pause is over, and it says so instead of trying for ever.
          pcall(exec, [[UPDATE self_wakes SET status='resume_abandoned', last_error=?, updated_at=? WHERE id=?]],
            { string.format("resume_abandoned: %d re-arm(s) and no turn", chain - 1), now, row.id })
          pcall(M.mark_abandoned, session, "the resume could not run after " .. tostring(chain - 1) .. " re-arm(s)", opts)
          if type(host) == "table" and type(host.log) == "function" then
            pcall(host.log, string.format(
              "deploy pause: ABANDONED the resume of session %s after %d re-arm(s) (wake %s); the pause record says so",
              session, chain - 1, tostring(row.id)))
          end
          abandoned = abandoned + 1
        else
          local armed = schedule({
            in_seconds = M.RESUME_BACKOFF_SECONDS * chain,
            reason = M.RESUME_REASON,
            prompt = M.resume_prompt(),
          }, session, tostring(row.owner or "master"))
          local wake = type(armed) == "table" and armed.wake or nil
          if wake and wake.id then
            -- The chain is carried on the new row, so the next tick counts THIS attempt.
            -- The chain is carried on the new row's OWN column, so the next tick counts THIS attempt and nothing
            -- about the dispatch counter.
            pcall(exec, "UPDATE self_wakes SET resume_chain=? WHERE id=?", { chain, wake.id })
            pcall(exec, [[UPDATE self_wakes SET status='superseded', last_error=?, updated_at=? WHERE id=?]],
              { "a newer resume was armed: " .. tostring(wake.id), now, row.id })
            rearmed = rearmed + 1
            pcall(M.say_rearmed, session, row.id, wake.id)
          end
        end
      end
    end
  end
  return { rearmed = rearmed, abandoned = abandoned, migration = migration }
end

-- A PAUSE RECORD THAT CAN NEVER BE RESUMED IS CLOSED (24/11). The records are written at the moment a session
-- pauses and nothing ever deleted one: `wa-sentinel status` counted 53 and said "oldest 1d", so the line that
-- exists to show a promise in flight showed a graveyard. A record is CLOSED when it cannot describe a live pause:
--
--   * its `since` is older than M.RESUME_WINDOW_SECONDS (six hours) - no deploy waits that long, and the sentinel
--     only reads a record at or after the request it is holding;
--   * or its session no longer exists (ended, closed, deleted), so there is nobody to resume.
--
-- A record that is younger and whose session is live is LEFT ALONE, whatever else is happening: it is the proof the
-- bound uses. `host.list_dir` is the host capability this needs (rust/wa-capabilities/src/host.rs), and `opts`
-- carries an injected listing for the test.
function M.sweep_records(now, opts)
  opts = opts or {}
  now = tonumber(now) or os.time()
  local dir = M.paused_dir()
  if not dir then return 0 end
  local listing = opts.list or (host and host.list_dir)
  if type(listing) ~= "function" then return 0 end
  local ok, raw = pcall(listing, dir)
  if not ok or type(raw) ~= "string" then return 0 end
  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then return 0 end
  -- THREE ANSWERS, because two were not enough (24/11, Fable's review of r4): true = live, false = POSITIVELY gone,
  -- nil = the lookup itself failed (a locked ledger, a module error). A failed lookup is not a fact, and a record is
  -- only deleted on a fact.
  local exists = opts.session_exists
  if type(exists) ~= "function" then
    exists = function(session)
      local loaded, row = pcall(function() return dofile("lua/core/memory.lua").session(session) end)
      if not loaded then return nil end
      return type(row) == "table"
    end
  end
  -- THE CAPABILITY THAT EXISTS (r5, 24/11). This asked for `host.delete_file`, which the host does not have (the
  -- name is `host.remove_file`, rust/wa-capabilities/src/host.rs:1690), so `remover` was nil on every live tick and
  -- the sweep silently closed nothing, for nine minutes and 39 stale records. A sweep that cannot remove is a
  -- fact an operator must read once, not a silent 0.
  local remover = opts.remove or (host and host.remove_file)
  if type(remover) ~= "function" then
    if type(host) == "table" and type(host.log) == "function" then
      pcall(host.log, "deploy pause: the sweep has no host.remove_file, so no pause record can be closed")
    end
    return 0
  end
  local closed = 0
  for _, entry in ipairs(decoded.entries or {}) do
    local name = tostring(entry.name or "")
    if name:sub(-5) == ".json" then
      local path = dir .. "/" .. name
      local reader = opts.read_file or (host and host.read_file)
      local record = nil
      if type(reader) == "function" then
        local read_ok, text = pcall(reader, path)
        if read_ok and type(text) == "string" then
          local parsed_ok, parsed = pcall(json.decode, text)
          if parsed_ok and type(parsed) == "table" then record = parsed end
        end
      end
      local since = tonumber(record and record.since) or 0
      local session = tostring((record and record.session) or name:sub(1, -6))
      -- A RECORD IS CLOSED ONLY ON A POSITIVE FACT (24/11, Fable's review of r4):
      --   * dated and older than the window: closed;
      --   * undated or unreadable (a record caught mid-write): judged by the FILE's own age, so a young one is kept;
      --   * its session is provably gone: closed. A lookup that raised is not a fact and keeps the record.
      local by_age
      if since > 0 then
        by_age = (now - since) > M.RESUME_WINDOW_SECONDS
      else
        local modified = tonumber(entry.modified) or 0
        by_age = modified > 0 and ((now - modified) > M.RESUME_WINDOW_SECONDS) or false
      end
      -- A RECORD THAT CANNOT BE DATED IS JUDGED ONLY BY ITS FILE (24/11, Fable's rule): with no `since` there is no
      -- session to be sure of either - the name may belong to a file caught mid-write - so "gone" may not close it.
      local looked, verdict = pcall(exists, session)
      local gone = since > 0 and looked and verdict == false
      if (by_age or gone) and type(remover) == "function" then
        if pcall(remover, path) then closed = closed + 1 end
      end
    end
  end
  -- A SWEEP THAT RAN MUST BE VISIBLE (r5, Fable's Q1): `closed 0` and `never ran` were the same output for nine
  -- minutes on the live node. One line a day even when it closes nothing, so `/health`'s counts and the log can be
  -- compared with a fact.
  local day = math.floor(now / 86400)
  local stamp_reader = opts.read_file or (host and host.read_file)
  local stamp_writer = opts.write_file or (host and host.write_file)
  local last_day = opts.last_sweep_day
  if last_day == nil and type(stamp_reader) == "function" then
    local ok, text = pcall(stamp_reader, sweep_stamp_path())
    last_day = ok and tonumber(text) or nil
  end
  if tonumber(last_day) ~= day and type(stamp_writer) == "function" then
    pcall(stamp_writer, sweep_stamp_path(), tostring(day))
    if type(host) == "table" and type(host.log) == "function" then
      pcall(host.log, string.format("deploy pause: sweep ran: %d record(s) seen, %d closed", #(decoded.entries or {}), closed))
    end
  end
  if closed > 0 and type(host) == "table" and type(host.log) == "function" then
    pcall(host.log, string.format(
      "deploy pause: closed %d pause record(s) that can never be resumed (older than %ds, or their session is gone)",
      closed, M.RESUME_WINDOW_SECONDS))
  end
  return closed
end

-- Said once, on the log an operator reads, every time a lost resume is re-armed. Cheap on purpose: the fact is
-- rare (twice in one evening, 23/11) and it is the only trace a re-arm leaves besides its ledger row.
function M.say_rearmed(session, lost_id, new_id)
  if type(host) ~= "table" or type(host.log) ~= "function" then return end
  pcall(host.log, string.format(
    "deploy pause: re-armed the LOST resume of session %s (wake %s had no outcome, new wake %s)",
    tostring(session), tostring(lost_id), tostring(new_id)))
end

-- What the re-armed resume says. A NEW sentence (it goes to a model, so it is listed for approval): the session's
-- own checkpoint is where the request it was doing is kept, and this wake carries no request text of its own.
function M.resume_prompt()
  return table.concat({
    M.WAKE_MARK .. " The deploy this session paused for is OVER, and the resume that was armed for it was lost",
    "(a dispatch cut by the install it was waiting for). Nothing was replayed and nothing was cut mid-call.",
    "Re-establish the real state from the machine first (files, `git status`, processes, and this session's own",
    'notes checkpoint under "Deploy pause"), then continue the request you were already working on and say',
    "plainly what had already been done before the pause.",
  }, "\n")
end

-- Returns how many rows it made due now. `opts.read` and `opts.query`/`opts.exec` are injected by the test
-- (scripts/test-deploy-resume.lua); a real caller passes nothing and gets the host's own file and ledger.
function M.release_due(now, opts)
  opts = opts or {}
  now = tonumber(now) or os.time()
  local exec = opts.exec
  local query = opts.query
  if type(exec) ~= "function" or type(query) ~= "function" then return 0 end
  -- Still installing OR still only waiting: the schedule keeps its own time. A marker past its bound is NOT a
  -- live install (the reader ignores it, and a crashed installer must not hold a session for ever), so it
  -- releases too. A waiting REQUEST counts here as well (22/11): releasing a paused session's resume while
  -- the deploy has not even started is what let a turn run again, keep the node busy, and starve the install
  -- for half an hour. The request is in the box until the swap is done, so its absence is the end.
  if M.waiting(now, opts) then return 0 end
  local waiting = query([[SELECT id FROM self_wakes WHERE status='pending' AND reason=? AND due_at>? LIMIT 8]],
    { M.RESUME_REASON, now })
  if type(waiting) ~= "table" or #waiting == 0 then return 0 end
  local changed = exec([[UPDATE self_wakes SET due_at=?, updated_at=?, last_error='deploy ended: resumed now'
    WHERE status='pending' AND reason=? AND due_at>?]], { now, now, M.RESUME_REASON, now })
  return tonumber(type(changed) == "table" and changed.changes or 0) or 0
end

return M
