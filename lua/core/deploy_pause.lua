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

-- How long after the pause the session asks to continue. Long enough for a swap and a restart, short
-- enough that a deploy that failed still gives the session its turn back; the marker's own bound wins.
function M.resume_seconds(marker, now)
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

-- The hook the turn loop calls at the top of a round. Returns nil when there is nothing to honour, or
-- a table {text=..., wake=..., wake_error=...} that the caller turns into the run's clean ending.
-- `opts` exists for the test (scripts/test-deploy-pause.lua) and for nothing else: a real caller passes
-- nothing, so the marker is the host's file, the schedule is selfloop's, and the clock is os.time().
function M.at_boundary(self, request, opts)
  opts = opts or {}
  if not self or self.subagent then return nil end
  if self.deploy_pause then return nil end -- one pause per run
  local now = opts.now or os.time()
  local marker = (opts.read or M.read)(now)
  if not marker then return nil end
  self.deploy_pause = marker
  local text = M.say(marker)
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
-- Returns how many rows it made due now. `opts.read` and `opts.query`/`opts.exec` are injected by the test
-- (scripts/test-deploy-resume.lua); a real caller passes nothing and gets the host's own file and ledger.
function M.release_due(now, opts)
  opts = opts or {}
  now = tonumber(now) or os.time()
  local exec = opts.exec
  local query = opts.query
  if type(exec) ~= "function" or type(query) ~= "function" then return 0 end
  -- Still installing: the schedule keeps its own time. A marker past its bound is NOT a live install (the
  -- reader ignores it, and a crashed installer must not hold a session for ever), so it releases too.
  if (opts.read or M.read)(now) then return 0 end
  local waiting = query([[SELECT id FROM self_wakes WHERE status='pending' AND reason=? AND due_at>? LIMIT 8]],
    { M.RESUME_REASON, now })
  if type(waiting) ~= "table" or #waiting == 0 then return 0 end
  local changed = exec([[UPDATE self_wakes SET due_at=?, updated_at=?, last_error='deploy ended: resumed now'
    WHERE status='pending' AND reason=? AND due_at>?]], { now, now, M.RESUME_REASON, now })
  return tonumber(type(changed) == "table" and changed.changes or 0) or 0
end

return M
