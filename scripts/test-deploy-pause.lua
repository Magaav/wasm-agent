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
-- A RESUME THAT WAS LOST IS A DEBT THE NODE PAYS (23/11, the G blocker). MEASURED on this laptop: two sessions
-- paused for a deploy, each had scheduled its resume, the request they paused for was installed - and each resume
-- row had been cut by that same install and left `unknown`, which is never replayed. Their sessions sat two hours
-- until a factory watchdog existed. Fable's review of the first fix found three more ways it could go wrong, and
-- each is asserted here against a fake ledger, scheduler and clock: no age bound, no cap on re-arming, and an
-- operator's cancel being overridden.
local WINDOW = pause.RESUME_WINDOW_SECONDS
local function ledger(rows)
  local self_ = { rows = rows, updates = {}, queries = 0 }
  function self_.q(sql, params)
    self_.queries = self_.queries + 1
    params = params or {}
    if sql:find("FROM self_wake_pauses", 1, true) then
      return self_.parked[tostring(params[1])] and { { id = "pause-1" } } or {}
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
      -- the lost-row query: the window is applied here, exactly as SQL applies it
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
  self_.parked = {}
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

-- 1. THE WINDOW (Fable's item 1). A row older than six hours is NOT re-armed: at G every node's first tick would
-- otherwise wake every session that ever lost a resume - paid model turns, days later, on stale requests.
local L = ledger({
  { id = "lost-old", session_id = "sess-old", owner = "master", attempts = 0, status = "unknown", created_at = stale() },
  { id = "lost-now", session_id = "sess-now", owner = "master", attempts = 0, status = "unknown", created_at = fresh() },
})
local armed, schedule = scheduler()
local out = pause.ensure_resumes(now, { read = function() return nil end, exec = L.ex, query = L.q,
  schedule = schedule, session_exists = function() return true end, migrated = function() return true end })
ok(out.rearmed == 1, "only the row inside the six-hour window is re-armed", json.encode(out))
ok(armed[1].session == "sess-now", "and it is the recent one: " .. tostring(armed[1].session))

-- 1b. AND THE MIGRATION RETIRES THE OLD ONES ONCE, saying how many: `superseded: too old to resume`.
local M2 = ledger({
  { id = "lost-old", session_id = "sess-old", owner = "master", attempts = 0, status = "unknown", created_at = stale() },
})
local retired_calls, migrated_marks = {}, nil
M2.ex = function(sql, params)
  retired_calls[#retired_calls + 1] = { sql = sql, params = params }
  return { changes = 7 }
end
local armed2, schedule2 = scheduler()
local first = pause.ensure_resumes(now, { read = function() return nil end, exec = M2.ex, query = M2.q,
  schedule = schedule2, session_exists = function() return true end,
  migrated = function() return false end, migrate = function(count) migrated_marks = count end })
ok(first.migration == 7, "the migration reports how many rows it retired", json.encode(first))
ok(migrated_marks == 7, "and the marker is written with that count", tostring(migrated_marks))
ok(retired_calls[1] and retired_calls[1].sql:find("too old to resume", 1, true) ~= nil,
  "the retired rows say why: " .. tostring(retired_calls[1] and retired_calls[1].sql))
ok(#armed2 == 0, "an old row is never woken, migration or not")

-- 2. THE CHAIN (Fable's item 2). A resume that always fails is tried a bounded number of times and then stops; without
-- the cap the next tick would re-arm it for ever.
local chain = ledger({
  { id = "lost-1", session_id = "sess-a", owner = "master", attempts = 2, status = "unknown", created_at = fresh() },
})
local armed3, schedule3 = scheduler()
local abandoned_paths = {}
local capped = pause.ensure_resumes(now, { read = function() return nil end, exec = chain.ex, query = chain.q,
  schedule = schedule3, session_exists = function() return true end, migrated = function() return true end,
  read_file = function() return nil end, write_file = function(path) abandoned_paths[#abandoned_paths + 1] = path end })
ok(capped.rearmed == 0 and capped.abandoned == 1, "a row at the cap is abandoned, not re-armed", json.encode(capped))
ok(#armed3 == 0, "no wake is scheduled for it")
local abandoned_update = nil
for _, row in ipairs(chain.updates) do
  if tostring(row.params[1]):find("resume_abandoned", 1, true) then abandoned_update = row end
end
ok(abandoned_update ~= nil, "and its row says resume_abandoned")
ok(#abandoned_paths == 1, "the pause record is marked, so the health line can count it", tostring(#abandoned_paths))

-- 2b. THE BACKOFF grows with the chain: the first re-arm waits RESUME_BACKOFF_SECONDS, the second twice that.
local backoff = ledger({
  { id = "lost-b1", session_id = "sess-b1", owner = "master", attempts = 0, status = "unknown", created_at = fresh() },
  { id = "lost-b2", session_id = "sess-b2", owner = "master", attempts = 1, status = "failed", created_at = fresh() },
})
local armed4, schedule4 = scheduler()
pause.ensure_resumes(now, { read = function() return nil end, exec = backoff.ex, query = backoff.q,
  schedule = schedule4, session_exists = function() return true end, migrated = function() return true end })
ok(#armed4 == 2, "both are inside the window and under the cap")
ok(tonumber(armed4[1].args.in_seconds) == pause.RESUME_BACKOFF_SECONDS, "the first re-arm waits the backoff")
ok(tonumber(armed4[2].args.in_seconds) == pause.RESUME_BACKOFF_SECONDS * 2, "the second waits twice as long")
local attempts_set = 0
for _, row in ipairs(backoff.updates) do
  if tostring(row.sql):find("SET attempts", 1, true) then attempts_set = attempts_set + 1 end
end
ok(attempts_set == 2, "and each new row carries its place in the chain", tostring(attempts_set))

-- 3. AN OPERATOR'S CANCEL IS FINAL (Fable's item 3). Only the node's own cancellation is re-armed.
local cancels = ledger({
  { id = "op-cancel", session_id = "sess-op", owner = "master", attempts = 0, status = "cancelled",
    last_error = "", created_at = fresh() },
  { id = "node-cancel", session_id = "sess-node", owner = "master", attempts = 0, status = "cancelled",
    last_error = "cancelled before execution", created_at = fresh() },
})
local armed5, schedule5 = scheduler()
local cancelled = pause.ensure_resumes(now, { read = function() return nil end, exec = cancels.ex, query = cancels.q,
  schedule = schedule5, session_exists = function() return true end, migrated = function() return true end })
ok(cancelled.rearmed == 1, "only the node's own cancellation is re-armed", json.encode(cancelled))
ok(#armed5 == 1 and armed5[1].session == "sess-node",
  "a person's cancel stands: " .. json.encode({ armed5[1] and armed5[1].session }))

-- 4. NOBODY HOME (Fable's item 4): a session that no longer exists, or one the operator PARKED, is not woken.
local gone = ledger({
  { id = "lost-gone", session_id = "sess-gone", owner = "master", attempts = 0, status = "unknown", created_at = fresh() },
  { id = "lost-parked", session_id = "sess-parked", owner = "master", attempts = 0, status = "unknown", created_at = fresh() },
})
gone.parked["sess-parked"] = true
local armed6, schedule6 = scheduler()
local nobody = pause.ensure_resumes(now, { read = function() return nil end, exec = gone.ex, query = gone.q,
  schedule = schedule6, migrated = function() return true end,
  session_exists = function(session) return session ~= "sess-gone" end })
ok(nobody.rearmed == 0, "nothing is woken into a session that is gone or parked", json.encode(nobody))
ok(#armed6 == 0, "and no wake was scheduled for either")

-- 5. WHILE A BUILD WAITS nothing is re-armed at all: that is the phase the pause is for.
local waiting_ledger = ledger({
  { id = "lost-w", session_id = "sess-w", owner = "master", attempts = 0, status = "unknown", created_at = fresh() },
})
local armed7, schedule7 = scheduler()
local held = pause.ensure_resumes(now, { read = marker_read, exec = waiting_ledger.ex, query = waiting_ledger.q,
  schedule = schedule7, session_exists = function() return true end, migrated = function() return true end })
ok(held.waiting == true and held.rearmed == 0 and #armed7 == 0, "a waiting deploy re-arms nothing", json.encode(held))

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
