-- The staleness notice (lua/core/feature_notice.lua): ONE message per incident, with the stage and the
-- time, and a send that failed never counted as sent.
--
-- The sender is the test's own (a function that records what it was given), so nothing here touches a
-- channel, a network or the operator's phone. The registry and the snapshot live in this test's home.
--
--   WA_SCRIPT=scripts/test-feature-notice.lua wa ...   prints "feature-notice ok (N checks)"
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes state: it refuses to run (" .. guard_reason .. ")") end

local json = dofile("lua/vendor/json.lua")
local feature_health = dofile("lua/core/feature_health.lua")
local feature_notice = dofile("lua/core/feature_notice.lua")

local checks = 0
local function check(value, what)
  checks = checks + 1
  if not value then error(what, 2) end
end
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format("%s\n  got:  %s\n  want: %s", what, tostring(got), tostring(want)), 2)
  end
end
local function contains(text, needle, what)
  checks = checks + 1
  if not tostring(text or ""):find(needle, 1, true) then
    error(what .. ": expected to find " .. tostring(needle) .. " in: " .. tostring(text), 2)
  end
end

-- Two features on this node, and one that this node does not run at all (its absence must never be a
-- reason to wake the operator).
local fixture = { schema = 1, features = {
  { name = "first", role = "any", canary = "first", last_success = "fixture: nothing", stale_after_s = 60 },
  { name = "second", role = "any", canary = "second", last_success = "fixture: nothing", stale_after_s = 6000 },
  { name = "elsewhere", role = "component:not-installed-here", canary = "elsewhere", last_success = "fixture: nothing", stale_after_s = 60 },
} }
check(host.write_file(feature_health.installed_registry_path(), json.encode(fixture)), "the fixture registry is written")

local NOW = 1700000000
local sent = {}
local function sender(text) sent[#sent + 1] = text; return true, "test" end

-- A node where both features have worked: 'never' is red too (a feature nobody has proven works), so the
-- healthy baseline has to be recorded before the quiet case can mean anything.
feature_health.record("first", true, { at = NOW - 10 })
feature_health.record("second", true, { at = NOW - 10 })

-- 1. NOTHING HAS STOPPED: no message, and the sender is not asked.
local quiet = feature_notice.notice(NOW, { sender = sender })
eq(quiet.sent, false, "a healthy node sends nothing")
eq(quiet.reason, "all_working", "and says why it was quiet")
eq(#sent, 0, "the sender was not called")

-- 2. A FEATURE STOPS: one message, naming it, its stage and the time.
feature_health.record("first", false, { at = NOW + 5, stage = "post", detail = "the component posted nothing" })
local first = feature_notice.notice(NOW + 10, { sender = sender })
eq(first.sent, true, "a stopped feature raises one notice")
eq(#sent, 1, "and exactly one message")
contains(sent[1], "first failing", "the message names the feature and its verdict")
contains(sent[1], "post", "and the stage it broke in")
contains(sent[1], "2023-11-14T22:13:25Z", "and the time, in UTC, from the record")
contains(sent[1], "1 feature(s) stopped", "and how many stopped")

-- 3. THE SAME INCIDENT AGAIN: silence. This is the 'once, not a stream' rule.
local again = feature_notice.notice(NOW + 70, { sender = sender })
eq(again.sent, false, "the same incident is not announced twice")
eq(again.reason, "already_noticed", "and says it already spoke")
eq(#sent, 1, "the sender was not called again")

-- 4. A SECOND FEATURE STOPS: the set changed, so it speaks again (and now says two).
feature_health.record("second", false, { at = NOW + 75, stage = "lease" })
local second_stop = feature_notice.notice(NOW + 80, { sender = sender })
eq(second_stop.sent, true, "a second feature stopping is new information")
eq(#sent, 2, "and it is one message")
contains(sent[2], "second failing", "the message names the second feature and its verdict")
contains(sent[2], "lease", "and its stage")
contains(sent[2], "2 feature(s) stopped", "and counts both")

-- 5. BACK TO GREEN: nothing is sent, and the incident is closed so the next one speaks.
feature_health.record("first", true, { at = NOW + 100 })
feature_health.record("second", true, { at = NOW + 100 })
local green = feature_notice.notice(NOW + 100, { sender = sender })
eq(green.sent, false, "a node that came back sends nothing")
eq(green.reason, "all_working", "and says it is all working")
eq(#sent, 2, "still no new message")
feature_health.record("first", false, { at = NOW + 110, stage = "decode" })
local reopened = feature_notice.notice(NOW + 120, { sender = sender })
eq(reopened.sent, true, "a new incident after a recovery speaks again")
eq(#sent, 3, "one message")
contains(sent[3], "decode", "with the new stage")

-- 6. A SEND THAT FAILED IS NOT SENT: the next call tries again, and only a real send closes the incident.
feature_health.record("second", false, { at = NOW + 130, stage = "lease" })
local refusing = function() return false, "the channel refused" end
local failed = feature_notice.notice(NOW + 140, { sender = refusing })
eq(failed.sent, false, "a refused send is not recorded as sent")
eq(failed.reason, "sender_failed", "it names the sender failure")
contains(failed.detail, "the channel refused", "with the sender's own words")
local retried = feature_notice.notice(NOW + 150, { sender = sender })
eq(retried.sent, true, "the next call sends it")
eq(#sent, 4, "and the retry is the fourth and last message")

-- 7. A FEATURE THIS NODE DOES NOT RUN NEVER WAKES ANYBODY.
feature_health.record("first", true, { at = NOW + 160 })
feature_health.record("second", true, { at = NOW + 160 })
feature_notice.notice(NOW + 160, { sender = sender })
local elsewhere = feature_health.red(NOW + 160)
eq(#elsewhere, 0, "an off-node feature is not in the red list")

print(string.format("feature-notice ok (%d checks)", checks))
