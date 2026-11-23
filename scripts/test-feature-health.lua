-- The feature-health rules (lua/core/feature_health.lua): what counts as working, what counts as
-- stopped, and what a reader is told when the answer is not a yes.
--
-- Everything here runs against a FIXTURE registry in this test's own home, never the tree's real list:
-- the rules are what is on trial, and a new feature added to the real list must not change this test's
-- verdicts. The real list is checked separately (it must parse, and every row must carry its canary and
-- its provenance) so a broken shipped list is still caught here.
--
--   WA_SCRIPT=scripts/test-feature-health.lua wa ...   prints "feature-health ok (N checks)"
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
-- The rule a test that writes state must pass (scripts/lib/test-home-guard.lua): its home sits under the
-- suite's scratch root and carries none of a live node's own markers.
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes state: it refuses to run (" .. guard_reason .. ")") end

local json = dofile("lua/vendor/json.lua")
local feature_health = dofile("lua/core/feature_health.lua")

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
local function fails(fn, needle, what)
  checks = checks + 1
  local ok, why = fn()
  if ok then error(what .. ": it answered instead of refusing", 2) end
  if needle and not tostring(why or ""):find(needle, 1, true) then
    error(what .. ": the refusal does not name " .. tostring(needle) .. ": " .. tostring(why), 2)
  end
end

-- WHERE IT WRITES: this test's own home, proved before the first write.
local store = feature_health.store_path()
check(store:sub(1, #test_home) == test_home, "the store is inside this test's home: " .. store)

-- 1. THE SHIPPED LIST IS VALID. Parsed straight from the tree, whatever the override says, so a list
--    that stops parsing - or a row that loses its canary - fails here and not at release time.
local tree_path = feature_health.REGISTRY_IN_TREE
local tree_text = host.read_file(tree_path)
check(type(tree_text) == "string" and #tree_text > 0, "the tree registry is readable: " .. tree_path)
local shipped, shipped_why = feature_health.parse_registry(tree_text, tree_path)
check(shipped ~= nil, "the shipped registry parses: " .. tostring(shipped_why))
local required = { "chat", "run-blocks", "remote-calls", "undo", "self-wake", "scheduled-jobs", "mail",
  "whatsapp-receive", "whatsapp-send", "whatsapp-transcription", "whatsapp-copilot-reply", "whatsapp-index",
  "release-update" }
local named = {}
for _, row in ipairs(shipped.features) do
  named[row.name] = row
  check(row.canary ~= nil and row.canary ~= "", "the shipped feature " .. row.name .. " names a canary")
  check(row.last_success ~= nil and row.last_success ~= "", "the shipped feature " .. row.name .. " names its last-success source")
end
for _, name in ipairs(required) do
  check(named[name] ~= nil, "the shipped registry lists " .. name)
end

-- 2. A ROW THAT IS BROKEN IS A REFUSAL THAT NAMES IT, never a row that disappears: a feature silently
--    dropped from the list is the silence this whole module exists to end.
local function registry_error(document, needle, what)
  fails(function() return feature_health.parse_registry(json.encode(document), "fixture") end, needle, what)
end
registry_error({ schema = 2, features = {} }, "schema", "a registry of another schema")
registry_error({ schema = 1, features = {} }, "empty", "a registry with no features")
registry_error({ schema = 1, features = { { name = "a", role = "any", canary = "c", last_success = "x: y" } } },
  "stale_after_s", "a row with no bound")
registry_error({ schema = 1, features = { { name = "a", role = "any", canary = "", last_success = "x", stale_after_s = 60 } } },
  "canary", "a row with no canary")
registry_error({ schema = 1, features = {
  { name = "a", role = "any", canary = "c", last_success = "x", stale_after_s = 60 },
  { name = "a", role = "any", canary = "d", last_success = "y", stale_after_s = 60 } } }, "twice", "a duplicate feature")
registry_error({ schema = 1, features = { { name = "a", role = "any", canary = "c", last_success = "x", stale_after_s = 0 } } },
  "positive", "a bound of zero")
registry_error({ schema = 1, features = { { name = "a", role = "any", canary = "c", last_success = "x", stale_after_s = 400 * 86400 } } },
  "ceiling", "a bound past the ceiling")
fails(function() return feature_health.parse_registry("not json", "fixture") end, "not parse", "a document that is not JSON")

-- 3. A REGISTRY THAT CANNOT BE READ IS AN ANSWER, NOT AN EMPTY LIST; and the fallback order is stated:
--    the state root's copy wins, and with no copy there the tree's list is read and NAMED as the tree's.
host.remove_file(feature_health.installed_registry_path())
local no_registry, no_registry_why = feature_health.load(test_home .. "/nowhere/features.json")
check(no_registry == nil, "a registry that is not readable answers nil")
contains(no_registry_why, "not readable", "the unreadable registry is named")
local fallback, fallback_why = feature_health.load()
check(fallback ~= nil, "the tree list is the fallback: " .. tostring(fallback_why))
eq(fallback.kind, "tree", "the fallback says it is the tree's copy")

-- The fixture the rest of this test runs on: one plain feature, one bound of 60 s, one component-backed
-- feature whose component this node does not have.
local fixture = {
  schema = 1,
  features = {
    { name = "plain", role = "any", canary = "plain", last_success = "fixture: nothing", stale_after_s = 60 },
    { name = "slow", role = "any", canary = "slow", last_success = "fixture: nothing", stale_after_s = 600 },
    { name = "component-backed", role = "component:not-installed-here", canary = "cb", last_success = "fixture: nothing", stale_after_s = 600 },
  },
}
check(host.write_file(feature_health.installed_registry_path(), json.encode(fixture)), "the fixture registry is written to the state root, never to the tree")
local loaded, where = feature_health.load()
check(loaded ~= nil, "the fixture registry loads: " .. tostring(where))
eq(loaded.kind, "installed", "the state root's copy is preferred over the tree's")
eq(#loaded.features, 3, "the fixture lists three features")

-- 4. APPLICABILITY: a component this node does not have makes the feature off-node, named.
local cb = feature_health.row("component-backed")
local applies, why_not = feature_health.applies(cb)
eq(applies, false, "a feature whose component is absent does not apply here")
contains(why_not, "not-installed-here", "the absent component is named")
eq((feature_health.applies(feature_health.row("plain"))), true, "a role of 'any' applies everywhere")

-- 5. THE FIVE VERDICTS, at the boundary as well as inside it.
local row = feature_health.row("plain")
local verdict, detail = feature_health.verdict(row, nil, 1000)
eq(verdict, "never", "nothing recorded is 'never', not 'working'")
contains(detail, "nothing has been recorded", "'never' says why")
verdict = feature_health.verdict(row, { last_ok_at = 1000 }, 1060)
eq(verdict, "working", "exactly at the bound is still inside it")
verdict, detail = feature_health.verdict(row, { last_ok_at = 1000 }, 1061)
eq(verdict, "stale", "one second past the bound is stale")
contains(detail, "past its bound of 1m", "'stale' names the bound and the age")
verdict, detail = feature_health.verdict(row, { last_ok_at = 1000, last_fail_at = 1030, last_fail_stage = "post" }, 1040)
eq(verdict, "failing", "a failure after the last success is 'failing'")
contains(detail, "stage post", "'failing' names the stage")
contains(detail, "last worked", "'failing' keeps the success before it")
verdict = feature_health.verdict(row, { last_ok_at = 1030, last_fail_at = 1020, last_fail_stage = "post" }, 1040)
eq(verdict, "working", "a success after the failure puts it back to working")
verdict = feature_health.verdict(row, { last_fail_at = 1030, last_fail_stage = "lease" }, 1040)
eq(verdict, "failing", "a feature that only ever failed is failing, not never")

-- 6. RECORDING: a failure never erases the success before it, and an unknown name is refused.
local entry = feature_health.record("plain", true, { at = 5000, source = "test", detail = "the turn answered" })
check(entry ~= nil, "a success is recorded")
entry = feature_health.record("plain", false, { at = 5030, stage = "transport", detail = "the socket closed" })
eq(tonumber(entry.last_ok_at), 5000, "the success is still there after a failure")
eq(tonumber(entry.last_fail_at), 5030, "the failure is recorded beside it")
eq(entry.last_fail_stage, "transport", "the failing stage is kept")
local snapshot = feature_health.snapshot()
eq(tonumber(snapshot.features.plain.last_ok_at), 5000, "the failure reached the snapshot on disk")
fails(function() return feature_health.record("no-such-feature", true) end, "not in the registry", "recording a feature the list does not have")

-- A snapshot that does not parse is not a crash: it reads as empty, and the next record repairs it.
check(host.write_file(feature_health.store_path(), "{ this is not json"), "the store is corrupted on purpose")
local repaired, state = feature_health.snapshot()
eq(state, "unreadable", "a corrupted store is named, not trusted")
eq(next(repaired.features), nil, "a corrupted store reads as empty")
feature_health.record("plain", true, { at = 6000, source = "test" })
eq(tonumber(feature_health.snapshot().features.plain.last_ok_at), 6000, "the next record repairs the store")

-- 7. THE REPORT AND THE LINES: every feature appears, with the time it last worked.
feature_health.record("slow", true, { at = 6000 - 5000, source = "test" })
local report, report_why = feature_health.report(6000)
check(report ~= nil, "the report renders: " .. tostring(report_why))
eq(#report, 3, "every registry row is in the report")
local by_name = {}
for _, item in ipairs(report) do by_name[item.name] = item end
eq(by_name.plain.verdict, "working", "plain is working at 6000")
eq(by_name.slow.verdict, "stale", "slow is stale at 6000")
eq(by_name["component-backed"].verdict, "off-node", "the absent component reads off-node, not working")
eq(by_name["component-backed"].applies, false, "off-node is reported as not applying")
local lines = feature_health.lines(6000)
local text = table.concat(lines, "\n")
contains(text, "features: 3 listed", "the summary counts the list")
contains(text, "last worked: 1970-01-01T01:40:00Z", "each line names when it last worked")
-- A CANARY'S TIME SAYS SO (Fable's review, item 4): until real-traffic hooks land, a synthetic pass must not
-- read as a user's use. The source travels with the row and the renderer marks it.
feature_health.record("plain", true, { at = 6000, source = "canary" })
local canary_lines = table.concat(feature_health.lines(6000), "\n")
contains(canary_lines, "[canary]", "a canary-sourced success is labelled in the row")
feature_health.record("plain", true, { at = 6000, source = "turn" })
local hook_lines = table.concat(feature_health.lines(6000), "\n")
check(hook_lines:find("[canary]", 1, true) == nil, "a real code path's success is not labelled")
contains(text, "last worked: 1970-01-01T01:40:00Z", "each line names when it last worked")
contains(text, "plain", "every feature is named")
contains(text, "component-backed", "an off-node feature is named too")
contains(text, "off-node", "the verdict word is printed")

-- 8. RED: what the release step and the notice act on.
local red = feature_health.red(6000)
local red_names = {}
for _, item in ipairs(red) do red_names[item.name] = item.verdict end
eq(red_names.plain, nil, "a working feature is not red")
eq(red_names.slow, "stale", "a stale feature is red")
eq(red_names["component-backed"], nil, "an off-node feature is not a failure of this node")
red = feature_health.red(6000 + 3600)
eq(#red, 2, "a feature that also goes stale joins the red list")

print(string.format("feature-health ok (%d checks)", checks))
