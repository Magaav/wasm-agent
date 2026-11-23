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
