-- "LAST WORKED" FROM REAL USE, NOT ONLY FROM CANARIES (features-real-traffic-hooks, item 3).
--
-- The parent mission shipped the feature table, and its own report (section 8) admitted the gap: no code path
-- recorded real traffic, so every "last worked" was the last CANARY run - a synthetic loopback that proves the
-- wiring, not that anybody used the thing. A feature whose canary passes nightly and which nobody has really
-- used for a week read as green.
--
-- This row holds the three facts that make the fix real:
--   1. a REAL use records the real field, and leaves the canary field alone;
--   2. a CANARY run records the canary field, and NEVER touches the real one - the whole point of keeping them
--      apart is that a synthetic pass cannot be mistaken for a user's success;
--   3. the page says both ("real 3m ago  canary 12m ago"), and a real use older than the bound is named even
--      while the canary still passes.
--
--   WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-feature-real-traffic.lua wa
--   -> prints "feature-real-traffic ok (N checks)"
--
-- Costs about 1 s: fixture registry, no child process, no network.
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes state: it refuses to run (" .. guard_reason .. ")") end

local json = dofile("lua/vendor/json.lua")
local feature_health = dofile("lua/core/feature_health.lua")
local feature_record = dofile("lua/core/feature_record.lua")

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
    error(what .. ": expected to find '" .. tostring(needle) .. "' in: " .. tostring(text), 2)
  end
end

-- A FIXTURE REGISTRY with a wide bound, so nothing here is about staleness.
local registry = {
  schema = 1,
  features = {
    { name = 'chat', role = 'any', canary = 'chat', last_success = 'fixture', stale_after_s = 86400 },
  },
}
local registry_path = feature_health.installed_registry_path()
check(registry_path:sub(1, #test_home) == test_home, "the registry is inside this test home: " .. registry_path)
host.write_file(registry_path, json.encode(registry))
feature_record.reset()

local function row(name)
  for _, item in ipairs(feature_health.report() or {}) do
    if item.name == name then return item end
  end
  return nil
end

-- 1. A REAL USE.
local written, why = feature_record.real('chat', { at = 1000, detail = 'turn_finished' })
eq(written, true, "a real use is written: " .. tostring(why))
local item = row('chat')
check(item ~= nil, "the feature is in the report")
eq(item.last_real_at, 1000, "the REAL field carries the time")
eq(item.last_canary_at, nil, "and the canary field is still empty")
eq(item.last_ok_source, 'real', "the newest success says it was real")

-- 2. A CANARY RUN MUST NOT PASS FOR REAL USE.
feature_health.record('chat', true, { at = 2000, source = 'canary' })
item = row('chat')
eq(item.last_canary_at, 2000, "the canary field carries the canary's time")
eq(item.last_real_at, 1000, "the REAL field is untouched by a canary run")
eq(item.last_ok_source, 'canary', "the newest success says it was a canary")

-- 3. THE PAGE SAYS BOTH, and it names a real use that is past the bound even while the canary passes.
local lines = table.concat(feature_health.lines(2000), "\n")
contains(lines, 'real ', "the page names real use")
contains(lines, 'canary ', "the page names the canary")
contains(lines, 'real 16m', "the real half carries its own age, not the newest success's") -- 1999 - 1000 = 999 s

-- A feature whose only success is a canary, past the bound of its real use, says which half is green.
local stale_registry = { schema = 1, features = {
  { name = 'chat', role = 'any', canary = 'chat', last_success = 'fixture', stale_after_s = 3600 } } }
host.write_file(registry_path, json.encode(stale_registry))
feature_health.record('chat', true, { at = 5000, source = 'canary' })
local stale_lines = table.concat(feature_health.lines(5000 + 7200), "\n")
-- real at 1000, canary at 5000, read at 12200: the real use is 3h old against a 1h bound.
contains(stale_lines, 'real use 3h ago, past the 1h bound', "a stale REAL use is named against its bound")
contains(stale_lines, 'canary', "while the canary's own time is named beside it")

-- 4. THE DEBOUNCE: one write a minute, so a hook in a hot path costs a comparison, not a file write.
feature_record.reset()
local first = feature_record.real('chat', { at = 10 * 60 })
eq(first, true, "the first real use inside the window is written")
local again, reason = feature_record.real('chat', { at = 10 * 60 + 5 })
eq(again, false, "a second call five seconds later is not")
contains(reason, 'debounced', "and says it was debounced")
local later = feature_record.real('chat', { at = 10 * 60 + 61 })
eq(later, true, "a call past the window is written")

-- 5. A HOOK CANNOT BREAK THE FEATURE: an unknown feature answers false, it does not raise.
local ok_bad, bad = pcall(feature_record.real, 'no such feature', { at = 9999 })
eq(ok_bad, true, "an unknown feature does not raise")
eq(bad, false, "it answers false")

print('feature-real-traffic ok (' .. checks .. ' checks)')
