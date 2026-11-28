-- THE DELETION-NOTICES CANARY JUDGES ITS BOUND (features-real-traffic-hooks, the ADDED item: a row for
-- deletion notices whose canary reads the component's counters and turns red when unmatched passes the daily
-- bound of 5).
--
-- The canary's reading half is a component round trip; its JUDGING half is pure and is what this row holds,
-- with the numbers a component would hand it - so the rule is tested on every node, including one that runs no
-- WhatsApp component at all.
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-deletion-notices-canary.lua wa
--   -> prints "deletion-notices-canary ok (N checks)"
--
-- Costs about 1 s: no component, no network, no child.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local canary = dofile("lua/core/canaries/whatsapp-deletion-notices.lua")
local health_control = dofile("lua/core/feature_health.lua")

local checks = 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format("%s\n  got:  %s\n  want: %s", what, tostring(got), tostring(want)), 2)
  end
end
local function contains(text, needle, what)
  checks = checks + 1
  if not tostring(text or ""):find(needle, 1, true) then
    error(what .. ": expected to find '" .. tostring(needle) .. "' in: " .. tostring(text), 2)
  end
end

-- THE BOUND IS THE COMPONENT'S OWN NUMBER, not a second opinion.
eq(canary.BOUND_PER_DAY, 5, "the canary judges the bound the component states (UNMATCHED_PER_DAY = 5)")

-- 1. Inside the bound is a pass, and the detail names the numbers.
local ok, stage, detail = canary.judge({ notices_matched = 12, notices_unmatched = 3, unmatched_today = 3 })
eq(ok, true, "3 unmatched today is inside the bound")
eq(stage, 'within_bound', "and says so by name")
contains(detail, 'bound 5', "the detail names the bound it judged")

-- 2. Exactly at the bound is still inside it: the rule is "passes 5", not "reaches 5".
ok, stage = canary.judge({ notices_matched = 12, notices_unmatched = 5, unmatched_today = 5 })
eq(ok, true, "5 unmatched today is the last passing day")

-- 3. Past the bound is red, by name, with the day rather than the total in the sentence.
ok, stage, detail = canary.judge({ notices_matched = 40, notices_unmatched = 9, unmatched_today = 6 })
eq(ok, false, "6 unmatched today is red")
eq(stage, 'over_bound', "the stage is over_bound")
contains(detail, '6 unmatched deletion notice(s) today', "the detail names today's count")
contains(detail, 'past the bound of 5', "and the bound it passed")

-- 4. A component that reports no day counter is not a pass: zero would read as "nothing today".
ok, stage, detail = canary.judge({ notices_matched = 1, notices_unmatched = 1 })
eq(ok, false, "a health line without the day counter is not a pass")
eq(stage, 'no_health_line', "it says the counter is not reported")
contains(detail, 'not reported', "and names what is missing")

-- 5. Notices exist and none ever matched: a broken tombstone, not a busy node.
ok, stage, detail = canary.judge({ notices_matched = 0, notices_unmatched = 4, unmatched_today = 1 })
eq(ok, false, "notices that never matched are red")
eq(stage, 'never_matched', "the stage separates 'broken' from 'busy'")
contains(detail, 'not one matched', "the sentence says which")

-- 6. The line is parsed the way the component writes it, day counter included.
local parsed = canary.counters('health: v=1 transcripts ok=0 last=- chars=0 failed=0 last_failure=- reason=- posting=on posted=3 last_post=2026-11-28T10:00:00Z index written=5 last=2026-11-28T10:00:00Z notices matched=7 unmatched=2 last_notice=2026-11-28T09:00:00Z last_unmatched=2026-11-28T09:30:00Z unmatched_today=2 day=20421')
eq(type(parsed), 'table', "the counters parse")
eq(parsed.notices_matched, 7, "matched")
eq(parsed.notices_unmatched, 2, "unmatched")
eq(parsed.unmatched_today, 2, "today")
eq(parsed.day, 20421, "the day the count belongs to")
ok, stage = canary.judge(parsed)
eq(ok, true, "and the parsed line judges the same way")

-- 7. The row is IN THE LIST, or the canary proves nothing: a feature that ships without a line fails the
--    registry check, and this row is the one the ADDED item asked for.
local registry, why = health_control.load()
checks = checks + 1
if type(registry) ~= 'table' then error("the registry is unreadable: " .. tostring(why)) end
local found
for _, entry in ipairs(registry.features) do
  if entry.name == 'whatsapp-deletion-notices' then found = entry end
end
checks = checks + 1
if not found then error("the registry has no whatsapp-deletion-notices row") end
eq(found.canary, 'whatsapp-deletion-notices', "the row names this canary")
eq(found.role, 'component:wa-whatsapp', "and the component that produces the counters")

print('deletion-notices-canary ok (' .. checks .. ' checks)')
