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
