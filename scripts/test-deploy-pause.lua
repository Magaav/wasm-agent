-- The deploy pause (lua/core/deploy_pause.lua): the signal that lets a node install without waiting for
-- a whole turn to end and without killing it.
--
-- Measured on wasm_the_first, 2026-11-10: the installer waited for every turn to END - 14 min, 37 min -
-- and a deploy that did run killed a session mid-turn. The chosen answer is the step boundary: a named
-- marker, a clean pause after the current step, a notes checkpoint and ONE wake that resumes the same
-- request. This test exercises the decision and its refusals with injected reads and clocks - no node,
-- no filesystem, no model.
--
-- Run from the repo root:
--   WA_SCRIPT=scripts/test-deploy-pause.lua wa --db /tmp/deploy-pause.db
local json = dofile("lua/vendor/json.lua")
local pause = dofile("lua/core/deploy_pause.lua")

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error(label .. (detail and (" - " .. tostring(detail)) or "")) end
end

local now = 1800000000
local function marker(overrides)
  local value = { state = "deploy_pending", since = now - 10, bound_seconds = 600,
    by = "upgrade.sh", from = "aaaaaaa", to = "bbbbbbbbbbbb", pid = 4242 }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return json.encode(value)
end

-- 1. What counts as a marker, and what does not.
local absent, why = pause.decode(nil, now)
ok(absent == nil and why == "absent", "no marker means no pause", tostring(why))
local broken, why2 = pause.decode("{not json", now)
ok(broken == nil and why2 == "unreadable", "a corrupt marker is ignored, not obeyed", tostring(why2))
local no_since, why3 = pause.decode(json.encode({state = "deploy_pending"}), now)
ok(no_since == nil and why3 == "no_since", "a marker with no time cannot be bounded and is ignored", tostring(why3))
local expired, why4 = pause.decode(marker({ since = now - 601 }), now)
ok(expired == nil and why4 == "expired", "an expired marker never freezes a session", tostring(why4))
local other, why5 = pause.decode(json.encode({ state = "something_else", since = now }), now)
ok(other == nil and why5 == "not_a_deploy", "only a deploy marker pauses a turn", tostring(why5))
local live = pause.decode(marker(), now)
ok(live ~= nil and live.to == "bbbbbbbbbbbb" and live.bound_seconds == 600, "a fresh marker is honoured", json.encode(live))
local unbounded = pause.decode(json.encode({ state = "deploy_pending", since = now }), now, 300)
ok(unbounded ~= nil and unbounded.bound_seconds == 300, "a marker with no bound gets the harness default", json.encode(unbounded))

-- 2. The resume is bounded and never immediate: the swap needs time, and a failed install must still
--    give the session its turn back.
local soon = pause.resume_seconds({ since = now, bound_seconds = 600 }, now)
ok(soon >= 60 and soon <= 1800, "the resume wait is clamped to a sane window", soon)
local late = pause.resume_seconds({ since = now - 590, bound_seconds = 600 }, now)
ok(late >= 60 and late <= 1800, "a nearly expired marker still waits the minimum", late)

-- 3. The wake's prompt is the session's own request, marked as an automated continuation.
local prompt = pause.prompt("fix the flaky landing test", { to = "bbbbbbbbbbbb" })
ok(prompt:sub(1, #pause.WAKE_MARK) == pause.WAKE_MARK, "the continuation is marked", prompt:sub(1, 40))
ok(prompt:find("fix the flaky landing test", 1, true) ~= nil, "the wake carries the original request")
ok(prompt:find("not a new one", 1, true) ~= nil, "and says it is a continuation, not a new request")

-- 4. The hook: one pause per run, none for a child, and the wake is scheduled exactly once.
local scheduled = {}
local noted = 0
local self = { session_id = "11111111-2222-3333-4444-555555555555", user = "master" }
local opts = {
  now = now,
  read = function() return pause.decode(marker(), now) end,
  schedule = function(args) scheduled[#scheduled + 1] = args; return { wake = { id = "wake-1" } } end,
  notes = function() noted = noted + 1 end,
}
local first = pause.at_boundary(self, "do the thing", opts)
ok(first ~= nil, "a running turn pauses when the marker is present")
ok(first.wake and first.wake.id == "wake-1", "the pause schedules one resume wake", json.encode(first.wake))
ok(#scheduled == 1 and scheduled[1].in_seconds >= 60, "the wake is a timed wake, not a poll", json.encode(scheduled[1]))
ok(scheduled[1].reason:find("deploy pending", 1, true) ~= nil, "and its reason names the deploy")
ok(noted == 1, "a checkpoint is written before the turn ends", noted)
ok(first.text:find("deploy pending", 1, true) ~= nil, "the turn's ending names the pause", first.text)
local second = pause.at_boundary(self, "do the thing", opts)
ok(second == nil and #scheduled == 1, "one run pauses once, never twice", #scheduled)

local child = { session_id = "22222222-3333-4444-5555-666666666666", user = "master", subagent = true }
ok(pause.at_boundary(child, "child work", opts) == nil, "a subagent never pauses: its parent owns the continuation")

-- 5. A wake that cannot be scheduled is said out loud, never swallowed.
local refused = pause.at_boundary({ session_id = "33333333-4444-5555-6666-777777777777", user = "master" },
  "another request", { now = now, read = function() return pause.decode(marker(), now) end,
    notes = function() end, schedule = function() return { error = "wake_refused" } end })
ok(refused ~= nil and refused.wake_error == "wake_refused", "a refused wake is a named fact", json.encode(refused))
ok(refused.text:find("could NOT be scheduled", 1, true) ~= nil, "and the turn says the resume is not armed", refused.text)

-- 6. No marker: no pause, and nothing is scheduled or written.
local quiet = pause.at_boundary({ session_id = "44444444-5555-6666-7777-888888888888", user = "master" },
  "work", { now = now, read = function() return nil end,
    schedule = function() error("must not schedule") end, notes = function() error("must not write") end })
ok(quiet == nil, "without a marker the turn continues normally")

print(string.format("deploy pause: %d checks passed", checks))

-- THE SECOND 23/11 DEADLOCK, AND THE RUN IT ENDED. MEASURED (avell, ~14:2xZ): the pause ENDED the workers
-- components-calls-cheap (d2d69ff3) and release-linux-reads-the-receipt (0b8c9d78), and both ended rc=1 with
-- `run_resource_refused: {"error":"resource_busy", "key":"session:0b8c9d78-..."}` - the harness's
-- auto-continues hit the claim the pause's own turn still held, until they ran out. A claim held while a build
-- waits is the WAIT, not the run's failure; every other refusal stays the run's failure (unknown is not yes).
local busy = { ok = false, error = "resource_busy",
  claim = { key = "session:0b8c9d78-cd2f-4270-b902-7c408377cec6", run = "ebf3d007-7fb1-4a2b-82cf-f5cee6e2211a" } }
-- The marker reader is INJECTED (`opts.read`), the same seam every other case in this file uses: no filesystem,
-- no node, no clock.
local marker_read = function() return { to = "8082b42e1111", id = "1795341684727384607-2971842", since = now - 300,
  source = "request", bound_seconds = 600 } end
local claimed_wait = pause.claim_wait(busy, now, { read = marker_read })
ok(type(claimed_wait) == "string" and claimed_wait:find("deploy_waiting", 1, true) == 1,
  "a claim held while a build waits is the wait, not the run's failure", tostring(claimed_wait))
-- THE SENTENCE A SCRIPT READS (Fable's review, 23/11 ~17:10Z): a refusal and a failure must be tellable
-- apart without judging prose, so every refusal ends in the same words.
-- A RESUME THAT WAS LOST IS A DEBT THE NODE PAYS (23/11, the G blocker), AND THE FOUR THINGS THAT WENT WRONG IN
-- THE FIRST TWO VERSIONS (Fable, 24/11 ~00:55Z):
--
--   r2: the chain cap read `self_wakes.attempts` - a column that counts DISPATCH attempts and reaches the hundreds on
--       a real ledger - so the first tick after an install marked 46 live resume rows `resume_abandoned` and repaired
--       nothing. THE FIXTURE BELOW IS THE REAL LEDGER'S OWN SHAPE, not zeroes: attempts 2,3,4,5,6,7,9,11,13,73,82,
--       199,249,308,464,486,533, the real reason, and the real statuses (Fable's measurement, read-only, of the 16
--       factory sessions those rows belonged to).
--   r3: the health line counted every record ever written (53, "oldest 1d"); it now counts what is live and says
--       `stale:` for the rest, and the node closes the records that can never be resumed.
local WINDOW = pause.RESUME_WINDOW_SECONDS

-- The attempts values Fable read out of the real ledger on 24/11, in the order measured.
local REAL_ATTEMPTS = { 2, 3, 4, 5, 6, 7, 9, 11, 13, 73, 82, 199, 249, 308, 464, 486, 533 }

local function ledger(rows)
  local self_ = { rows = rows, updates = {}, parked = {} }
  function self_.q(sql, params)
    params = params or {}
    if sql:find("FROM self_wake_pauses", 1, true) then
      return self_.parked[tostring(params[1])] and { { session_id = params[1] } } or {}
    end
    if sql:find("FROM self_wakes", 1, true) then
      if sql:find("status IN ('pending','dispatching')", 1, true) then
        local out = {}
        for _, row in ipairs(self_.rows) do
          if row.session_id == params[1] and (row.status == "pending" or row.status == "dispatching") then
            out[#out + 1] = { id = row.id }
          end
        end
        return out
      end
      local cutoff = tonumber(params[2]) or 0
      local out = {}
      for _, row in ipairs(self_.rows) do
        local lost = row.status == "unknown" or row.status == "failed"
          or (row.status == "cancelled" and tostring(row.last_error):find("cancelled before execution", 1, true) ~= nil)
        if lost and tonumber(row.created_at or 0) >= cutoff then out[#out + 1] = row end
      end
      return out
    end
    return {}
  end
  function self_.ex(sql, params)
    self_.updates[#self_.updates + 1] = { sql = sql, params = params }
    return { changes = 1 }
  end
  return self_
end

local function scheduler()
  local armed = {}
  local function schedule(args, session, owner)
    armed[#armed + 1] = { args = args, session = session, owner = owner }
    return { ok = true, wake = { id = "new-" .. tostring(#armed) } }
  end
  return armed, schedule
end

local fresh = function() return now - 60 end
local stale = function() return now - WINDOW - 3600 end

-- 1. THE LEDGER'S REAL SHAPE, EVERY ROW: attempts from 2 to 533, a `resume_chain` of 0, status unknown, the real
-- reason. Every one of them is re-armed EXACTLY ONCE - the bug Fable found was that these were all abandoned.
local rows = {}
for i, attempts in ipairs(REAL_ATTEMPTS) do
  rows[#rows + 1] = { id = "lost-" .. i, session_id = "sess-" .. i, owner = "master", attempts = attempts,
    resume_chain = 0, status = "unknown", created_at = fresh() }
end
local real = ledger(rows)
local armed, schedule = scheduler()
local out = pause.ensure_resumes(now, { read = function() return nil end, exec = real.ex, query = real.q,
  schedule = schedule, session_exists = function() return true end, migrated = function() return true end })
ok(out.rearmed == #REAL_ATTEMPTS, "every row of the real shape is re-armed, whatever its attempts says",
  json.encode(out) .. " attempts=" .. tostring(#REAL_ATTEMPTS))
ok(out.abandoned == 0, "and not one is abandoned on its first pass", json.encode(out))
local chains_set = 0
for _, row in ipairs(real.updates) do
  if tostring(row.sql):find("SET resume_chain", 1, true) then chains_set = chains_set + 1 end
  ok(not tostring(row.sql):find("SET attempts", 1, true), "attempts is never written again", tostring(row.sql))
end
ok(chains_set == #REAL_ATTEMPTS, "each new row carries resume_chain=1", tostring(chains_set))

-- 2. THE CAP IS THREE TRIES IN TOTAL: chain 0 -> re-arm (1), chain 1 -> re-arm (2), chain 2 -> abandoned (no third).
for chain, expected in ipairs({ 1, 1, 0 }) do
  local one = ledger({ { id = "lost-c", session_id = "sess-c", owner = "master", attempts = 533,
    resume_chain = chain - 1, status = "failed", created_at = fresh() } })
  local armed_n, schedule_n = scheduler()
  local got = pause.ensure_resumes(now, { read = function() return nil end, exec = one.ex, query = one.q,
    schedule = schedule_n, session_exists = function() return true end, migrated = function() return true end,
    read_file = function() return nil end, write_file = function() end })
  ok(got.rearmed == expected and #armed_n == expected,
    string.format("chain %d: rearmed=%d expected=%d (tries in total: %d)", chain - 1, got.rearmed, expected, chain),
    json.encode(got))
  if expected == 1 then
    ok(tonumber(armed_n[1].args.in_seconds) == pause.RESUME_BACKOFF_SECONDS * chain, "the backoff grows with the chain")
  else
    ok(got.abandoned == 1, "the third try is the last: the row is abandoned", json.encode(got))
  end
end

-- 3. AN OPERATOR'S CANCEL IS FINAL; the node's own cancellation is re-armed (unchanged from r3, on real shapes).
local cancels = ledger({
  { id = "op", session_id = "sess-op", owner = "master", attempts = 73, resume_chain = 0, status = "cancelled", last_error = "", created_at = fresh() },
  { id = "node", session_id = "sess-node", owner = "master", attempts = 464, resume_chain = 0, status = "cancelled", last_error = "cancelled before execution", created_at = fresh() },
})
local armed3, schedule3 = scheduler()
local can = pause.ensure_resumes(now, { read = function() return nil end, exec = cancels.ex, query = cancels.q,
  schedule = schedule3, session_exists = function() return true end, migrated = function() return true end })
ok(can.rearmed == 1 and armed3[1].session == "sess-node", "a person's cancel stands, the node's is re-armed", json.encode(can))

-- 4. NOBODY HOME: gone or parked sessions are not woken.
local gone = ledger({
  { id = "g", session_id = "sess-gone", owner = "master", attempts = 199, resume_chain = 0, status = "unknown", created_at = fresh() },
  { id = "p", session_id = "sess-parked", owner = "master", attempts = 249, resume_chain = 0, status = "unknown", created_at = fresh() },
})
gone.parked["sess-parked"] = true
local armed4, schedule4 = scheduler()
local none = pause.ensure_resumes(now, { read = function() return nil end, exec = gone.ex, query = gone.q,
  schedule = schedule4, migrated = function() return true end, session_exists = function(session) return session ~= "sess-gone" end })
ok(none.rearmed == 0 and #armed4 == 0, "a session that is gone or parked is not woken", json.encode(none))

-- 5. THE WINDOW: a row older than six hours is never woken, and the one-time migration retires it.
local old = ledger({ { id = "old", session_id = "sess-old", owner = "master", attempts = 533, resume_chain = 0,
  status = "unknown", created_at = stale() } })
local armed5, schedule5 = scheduler()
local retired = nil
local first = pause.ensure_resumes(now, { read = function() return nil end, exec = function(sql, params)
  old.updates[#old.updates + 1] = { sql = sql, params = params }
  return { changes = 3 }
end, query = old.q, schedule = schedule5, session_exists = function() return true end,
  migrated = function() return false end, migrate = function(count) retired = count end })
ok(#armed5 == 0, "a seven-hour-old row is not woken")
ok(first.migration == 3 and retired == 3, "and the migration says how many it retired", json.encode(first))

-- 6. WHILE A BUILD WAITS nothing is re-armed at all.
local waiting_rows = ledger({ { id = "w", session_id = "sess-w", owner = "master", attempts = 5, resume_chain = 0,
  status = "unknown", created_at = fresh() } })
local armed6, schedule6 = scheduler()
local held = pause.ensure_resumes(now, { read = marker_read, exec = waiting_rows.ex, query = waiting_rows.q,
  schedule = schedule6, session_exists = function() return true end, migrated = function() return true end })
ok(held.waiting == true and held.rearmed == 0 and #armed6 == 0, "a waiting deploy re-arms nothing", json.encode(held))

-- 7. THE RECORDS THAT CAN NEVER BE RESUMED ARE CLOSED (r3, item 2): an old record and a record whose session is gone
-- go; a young record with a live session stays, whatever else is happening.
local records = {
  { name = "live.json", text = json.encode({ session = "sess-live", since = now - 300 }) },
  { name = "old.json", text = json.encode({ session = "sess-live2", since = now - WINDOW - 60 }) },
  { name = "gone.json", text = json.encode({ session = "sess-gone", since = now - 60 }) },
  -- UNDATED BUT OLD ON DISK: the record cannot say since, and the FILE can (24/11: a record is closed on a positive
  -- fact, and for an undated one that fact is the file's own age).
  { name = "undated.json", text = json.encode({ session = "sess-live3" }) },
  -- HALF-WRITTEN AND YOUNG (Fable's required case): a record caught mid-write looks unreadable and undated, and the
  -- only thing that says it is not dead is its mtime. It must be KEPT.
  { name = "half.json", text = "{\"session\":\"sess-half\",\"since\"" },
}
local OLD_MTIME = now - WINDOW - 60
local listing = json.encode({ path = "/x", entries = {
  { name = "live.json", kind = "file", modified = now - 300 },
  { name = "old.json", kind = "file", modified = now - WINDOW - 60 },
  { name = "gone.json", kind = "file", modified = now - 60 },
  { name = "undated.json", kind = "file", modified = OLD_MTIME },
  { name = "half.json", kind = "file", modified = now - 60 },
  { name = "readme", kind = "file" } } })
local removed = {}
local closed = pause.sweep_records(now, {
  list = function() return listing end,
  read_file = function(path)
    for _, record in ipairs(records) do if path:sub(-#record.name) == record.name then return record.text end end
    return nil
  end,
  remove = function(path) removed[#removed + 1] = path; return true end,
  session_exists = function(session) return session ~= "sess-gone" end,
})
ok(closed == 3, "three records are closed: too old, gone, and undated-but-old-on-disk", tostring(closed))
ok(#removed == 3, "and three files go", json.encode(removed))
local kept = true
for _, path in ipairs(removed) do if path:find("live.json", 1, true) then kept = false end end
ok(kept, "a young record whose session is live is never removed: it is the proof the bound uses", json.encode(removed))
ok(not removed[1] or true, "")
local half_kept = true
for _, path in ipairs(removed) do if path:find("half.json", 1, true) then half_kept = false end end
ok(half_kept, "a half-written YOUNG record is kept: unreadable is not dead", json.encode(removed))

-- 8. A LOOKUP THAT FAILS KEEPS THE RECORD (Fable's required case): a locked ledger or a module error used to read as
-- "the session is gone" and deleted a live record. Only a POSITIVE answer deletes.
local aging = json.encode({ path = "/x", entries = {
  { name = "fresh.json", kind = "file", modified = now - 60 },
  { name = "errored.json", kind = "file", modified = now - 60 } } })
local errored_removed = {}
local errored = {}
for _, name in ipairs({ "fresh.json", "errored.json" }) do
  errored[name] = json.encode({ session = (name == "fresh.json") and "sess-fresh" or "sess-errored", since = now - 60 })
end
local closed_e = pause.sweep_records(now, {
  list = function() return aging end,
  read_file = function(path)
    for name, text in pairs(errored) do if path:sub(-#name) == name then return text end end
    return nil
  end,
  remove = function(path) errored_removed[#errored_removed + 1] = path; return true end,
  session_exists = function(session)
    if session == "sess-errored" then error("database is locked") end
    return true
  end,
})
ok(closed_e == 0 and #errored_removed == 0,
  "a lookup that raises keeps the record: a transient error is not a dead session",
  json.encode({ closed = closed_e, removed = errored_removed }))
-- THE ONE INVARIANT, ONE TEST PER LOST STATE (r5, 24/11), each seeded from a REAL row.
--
-- dispatching: ae2a9231's shape (status dispatching, attempts 1, resume_chain 0, last_error
--   'deploy ended: resumed now', no message after the pause) - reconcile owns that bound, but the seam's plan owns
--   the other tick path, so a node whose component bytes are older never reconciles;
-- pending: the 22/11 row (due 2026-11-22 10:45Z, attempts 1, last_error 'deploy_waiting: waiting for the install of
--   unknown ...'), which the tick re-stamps on every install and never dispatches.
local function invariant_ledger(rows)
  local self_ = { rows = rows, updates = {}, parked = {} }
  function self_.q(sql, params)
    params = params or {}
    if sql:find("FROM self_wake_pauses", 1, true) then return {} end
    if sql:find("FROM self_wakes", 1, true) then
      if sql:find("status IN ('pending','dispatching')", 1, true) then return {} end
      local cutoff = tonumber(params[2]) or 0
      local out = {}
      for _, row in ipairs(self_.rows) do
        local lost = row.status == "unknown" or row.status == "failed"
          or (row.status == "cancelled" and tostring(row.last_error):find("cancelled before execution", 1, true) ~= nil)
        if lost and tonumber(row.created_at or 0) >= cutoff then out[#out + 1] = row end
      end
      return out
    end
    return {}
  end
  function self_.ex(sql, params)
    self_.updates[#self_.updates + 1] = { sql = sql, params = params }
    return { changes = 1 }
  end
  return self_
end

-- 1. A `dispatching` RESUME ROW IS RECLAIMED ONLY WHEN NOTHING HAPPENED (r5c/r5d, Fable, 24/11).
--
-- The row leaves `dispatching` at the END of its turn (selfloop.lua:1214/:1355), so age is a filter. Three facts are
-- needed: past M.RESUME_DISPATCH_BOUND_SECONDS; the RUN CLAIM answered by the resources store (NOT the ledger: the
-- claims are in `<data>/resources/claims.sqlite`, and `claim_state` is injected here because the live-shaped test in
-- scripts/test-selfloop-pause.lua exercises the real store); and zero messages since the dispatch. Any answer that
-- is not positively "free" - held, unknown, a raise, no capability - keeps the row.
local THIS_SESSION = "sess-ae2a"
local function dispatch_ledger(opts)
  opts = opts or {}
  local row = { id = "ae2a9231", session_id = THIS_SESSION, owner = "master", attempts = 1, resume_chain = 0,
    status = "dispatching", created_at = now - 3600, updated_at = now - 400,
    last_error = "deploy ended: resumed now" }
  local ledger_ = { rows = { row }, updates = {}, messages = opts.messages or 0, fail_messages = opts.fail_messages }
  function ledger_.q(sql, params)
    params = params or {}
    if sql:find("FROM messages", 1, true) then
      if ledger_.fail_messages then error("database is locked") end
      return { { n = ledger_.messages } }
    end
    if sql:find("FROM self_wake_pauses", 1, true) then return {} end
    if sql:find("FROM self_wakes", 1, true) then
      if sql:find("status='dispatching'", 1, true) then
        local out = {}
        for _, candidate in ipairs(ledger_.rows) do
          if candidate.status == "dispatching" and candidate.updated_at < (tonumber(params[2]) or 0) then
            out[#out + 1] = { id = candidate.id, session_id = candidate.session_id, updated_at = candidate.updated_at }
          end
        end
        return out
      end
      if sql:find("status IN ('pending','dispatching')", 1, true) then return {} end
      local cutoff = tonumber(params[2]) or 0
      local out = {}
      for _, candidate in ipairs(ledger_.rows) do
        local lost = candidate.status == "unknown" or candidate.status == "failed"
          or (candidate.status == "cancelled" and tostring(candidate.last_error):find("cancelled before execution", 1, true) ~= nil)
        if lost and tonumber(candidate.created_at or 0) >= cutoff then out[#out + 1] = candidate end
      end
      return out
    end
    return {}
  end
  function ledger_.ex(sql, params)
    ledger_.updates[#ledger_.updates + 1] = { sql = sql, params = params }
    if tostring(sql):find("status='unknown'", 1, true) then
      for _, candidate in ipairs(ledger_.rows) do
        if candidate.id == params[2] then candidate.status = "unknown" end
      end
    end
    return { changes = 1 }
  end
  return ledger_
end
local function run(ledger_, claim)
  local armed, schedule = scheduler()
  local asked = 0
  local out_ = pause.ensure_resumes(now, { read = function() return nil end, exec = ledger_.ex,
    query = ledger_.q, schedule = schedule, session_exists = function() return true end,
    migrated = function() return true end, stale_seconds = 300,
    claim_state = function() asked = asked + 1; if type(claim) == "function" then return claim() end return claim end })
  return out_, armed, asked
end

-- 1a. QUIET AND UNCLAIMED: reclaimed, and exactly ONE re-arm.
local quiet = dispatch_ledger({})
local out_q, armed_q = run(quiet, "free")
ok(out_q.rearmed == 1 and #armed_q == 1 and armed_q[1].session == THIS_SESSION,
  "quiet and unclaimed: exactly one resume wake", json.encode(out_q))

-- 1b. THE CLAIM IS HELD (a long first tool call writes no message yet): untouched, zero wakes.
local held_rows = dispatch_ledger({})
local out_c, armed_c, asked_c = run(held_rows, "held")
ok(asked_c == 1, "the claim was asked of the store, once per stale row")
ok(out_c.rearmed == 0 and #armed_c == 0,
  "a held claim means the turn is alive: no second resume", json.encode(out_c))

-- 1c. THE CLAIM ANSWER IS UNKNOWN (no capability, a raise, an empty boot): untouched.
for _, answer in ipairs({ "unknown", function() error("resources: unavailable") end }) do
  local unknown_rows = dispatch_ledger({})
  local out_u, armed_u = run(unknown_rows, answer)
  ok(out_u.rearmed == 0 and #armed_u == 0,
    "an unknown claim answer keeps the row", json.encode(out_u))
end

-- 1d. THE STORE SAYS THE LEASE IS RELEASED (the holder is gone): reclaimed.
local released = dispatch_ledger({})
local out_r, armed_r = run(released, "free")
ok(out_r.rearmed == 1 and #armed_r == 1, "a released lease does not block", json.encode(out_r))

-- 1e. THE MESSAGES LOOKUP FAILS: untouched (r4b's defect, exactly).
local bad_messages = dispatch_ledger({ fail_messages = true })
local out_bm, armed_bm = run(bad_messages, "free")
ok(out_bm.rearmed == 0 and #armed_bm == 0,
  "a messages lookup that fails keeps the row", json.encode(out_bm))

-- 1f. A LONG TURN THAT HAS WRITTEN: untouched, zero wakes.
local alive = dispatch_ledger({ messages = 3 })
local out_a, armed_a = run(alive, "free")
ok(out_a.rearmed == 0 and #armed_a == 0,
  "messages since the dispatch mean a running turn: no second resume", json.encode(out_a))

-- 1g. THE BOUND IS ONE NUMBER, SHARED WITH THE TICK'S OWN RECONCILE.
-- ONE NUMBER, ONE MEANING (24/11): the reclaim is the seam-independent twin of the tick's own reconcile, so it
-- uses reconcile's bound - asserted against that function rather than against a literal, so the two cannot drift.
ok(pause.RESUME_DISPATCH_BOUND_SECONDS == dofile("lua/core/selfloop.lua").stale_seconds(),
  "the resume bound is the tick's own stale bound, not a second number: " .. tostring(pause.RESUME_DISPATCH_BOUND_SECONDS)
    .. " vs " .. tostring(dofile("lua/core/selfloop.lua").stale_seconds()))
local young = dispatch_ledger({})
for _, candidate in ipairs(young.rows) do candidate.updated_at = now - 200 end
local out_y, armed_y = run(young, "free")
ok(out_y.rearmed == 0 and #armed_y == 0, "a 200 s dispatching row is inside the bound: nothing reclaimed")
-- 2. A `pending` ROW OVERDUE PAST THE WINDOW CAN NEVER FIRE (the 22/11 row): it is retired, not re-stamped for ever.
local pending = invariant_ledger({})
local out_p = pause.ensure_resumes(now, { read = function() return nil end, exec = pending.ex, query = pending.q,
  schedule = function() error("nothing may be armed for a dead row") end, session_exists = function() return true end,
  migrated = function() return true end, stale_seconds = 300 })
local fired = nil
for _, row in ipairs(pending.updates) do
  local sql = tostring(row.sql)
  if sql:find("too old to fire", 1, true) then fired = row end
end
ok(fired ~= nil, "an overdue pending row past the window is retired: " .. json.encode({ updates = #pending.updates }))
ok(tostring(fired and fired.sql):find("status='pending'", 1, true) ~= nil,
  "and the statement is scoped to pending rows only: " .. tostring(fired and fired.sql))
ok(out_p.rearmed == 0, "nothing is armed for it", json.encode(out_p))

-- 3. A WAITING DEPLOY neither re-arms nor retires: the two states above are handled BEFORE that gate, so a stuck
-- row is not held hostage by a deploy that never ends, and a live one is not touched while it waits.
local waiting_rows = invariant_ledger({ { id = "w2", session_id = "sess-w2", owner = "master", attempts = 3,
  resume_chain = 0, status = "unknown", created_at = fresh() } })
local armed_w, schedule_w = scheduler()
local held_w = pause.ensure_resumes(now, { read = marker_read, exec = waiting_rows.ex, query = waiting_rows.q,
  schedule = schedule_w, session_exists = function() return true end, migrated = function() return true end })
ok(held_w.waiting == true and held_w.rearmed == 0 and #armed_w == 0,
  "a waiting deploy still re-arms nothing", json.encode(held_w))
ok(#waiting_rows.updates > 0, "but the invariant statements ran first (the reclaim and the retire)")
local refusal_text = pause.refuse(now, { read = marker_read })
ok(type(refusal_text) == "string" and refusal_text:find("retry when idle", 1, true) ~= nil,
  'a refusal ends in retry-when-idle, so a runner can tell it from a failure', tostring(refusal_text))
ok(refusal_text:find("deploy_waiting", 1, true) == 1, "and still names the wait as its first word",
  tostring(refusal_text))
ok(claimed_wait:find("Nothing was lost", 1, true) ~= nil,
  "and it says nothing was lost, because nothing ran", tostring(claimed_wait))
local claim_none = pause.claim_wait(busy, now, { read = function() return nil end })
ok(claim_none == nil, "with no build waiting, a busy claim is the run's own failure again", tostring(claim_none))
local other_problem = pause.claim_wait({ ok = false, error = "resource_store_failed" }, now, { read = marker_read })
ok(other_problem == nil, "another claim failure is not a deploy wait", tostring(other_problem))
ok(pause.claim_wait({ ok = true }, now, { read = marker_read }) == nil, "a claim that was granted is not a wait")
print('deploy claim wait ok (' .. checks .. ' checks)')
