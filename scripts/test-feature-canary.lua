-- The canary runner (lua/core/feature_canary.lua): a feature's exercise runs, fails at the stage it
-- broke in, and cannot pass by not running.
--
-- Three kinds of proof:
--   * the SHIPPING canaries run for real, through the runner, on this node: chat and self-wake each spawn
--     a child node with its own home and ledger (lua/core/canaries/tasks/*.lua) and the runner reports
--     the answer. A canary that cannot pass here is a canary nobody can trust at release time.
--   * the FAILURES are driven by fixture canaries in this test's own home: one whose child dies at a
--     named stage, one that raises, one that is malformed, one that is not there at all. Each has to be a
--     NAMED failure - 'unknown' rendered as 'fine' is the bug this whole mission is against.
--   * run_all records each verdict in the snapshot, so `wa features` and the release step read what the
--     canary actually answered.
--
--   WA_SCRIPT=scripts/test-feature-canary.lua wa ...   prints "feature-canary ok (N checks)"
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes state: it refuses to run (" .. guard_reason .. ")") end

local json = dofile("lua/vendor/json.lua")
local feature_canary = dofile("lua/core/feature_canary.lua")
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

-- 1. THE SHIPPING CANARIES, through the runner, on this node. These are the two classes a node can
--    exercise with nothing but its own binary: a chat turn (model stubbed at the host's stream boundary)
--    and a self-wake (the module's own schedule/claim/settle path). Each spawns a child with a scratch
--    home, so the operator's ledger is not the thing that passed.
local chat = feature_canary.run("chat")
eq(chat.ok, true, "the chat canary passes on this node (" .. tostring(chat.stage) .. ": " .. tostring(chat.detail) .. ")")
eq(chat.stage, "answered", "the chat canary names its last stage")
local wake = feature_canary.run("self-wake")
eq(wake.ok, true, "the self-wake canary passes on this node (" .. tostring(wake.stage) .. ": " .. tostring(wake.detail) .. ")")
eq(wake.stage, "delivered", "the self-wake canary names its last stage")

-- 2. THE FIXTURES: a registry of their own, and canary modules that fail in the four ways a canary can.
local canary_dir = test_home .. "/canaries"
local task_dir = canary_dir .. "/tasks"
check(host.exec("mkdir -p '" .. task_dir .. "'", "") ~= nil, "the fixture canary directory exists")

-- A task that reaches the turn and then fails there: the stage is the point.
check(host.write_file(task_dir .. "/broken.lua", table.concat({
  "print('stage: setup')",
  "print('stage: turn')",
  "print('FAIL turn: the ledger refused the write')",
  "os.exit(3)",
}, "\n")), "the broken task is written")

local function canary_module(name, body)
  check(host.write_file(canary_dir .. "/" .. name .. ".lua", body), "the fixture canary " .. name .. " is written")
end
canary_module("childfails", table.concat({
  "local runner = dofile('lua/core/feature_canary.lua')",
  "local M = { mode = 'loopback' }",
  "function M.run(ctx)",
  "  local child = runner.child(ctx, {}, { env = { 'WA_SCRIPT=" .. task_dir .. "/broken.lua' } })",
  "  if child.code == 0 then return true, 'done', 'it passed' end",
  "  return false, child.stage or 'unknown', child.fail or child.err or ''",
  "end",
  "return M",
}, "\n"))
canary_module("raiser", table.concat({
  "local M = { mode = 'read' }",
  "function M.run() error('the exercise itself is broken') end",
  "return M",
}, "\n"))
canary_module("unloadable", "error('this module cannot even be loaded')\n")
canary_module("malformed", "return 42\n")
canary_module("passes", "return { mode = 'read', run = function() return true, 'done', 'read-only' end }\n")

local fixture = { schema = 1, features = {
  { name = "passing", role = "any", canary = "passes", last_success = "fixture: nothing", stale_after_s = 600 },
  { name = "broken-child", role = "any", canary = "childfails", last_success = "fixture: nothing", stale_after_s = 600 },
  { name = "raising", role = "any", canary = "raiser", last_success = "fixture: nothing", stale_after_s = 600 },
  { name = "unloadable-one", role = "any", canary = "unloadable", last_success = "fixture: nothing", stale_after_s = 600 },
  { name = "malformed-one", role = "any", canary = "malformed", last_success = "fixture: nothing", stale_after_s = 600 },
  { name = "no-canary", role = "any", canary = "absent", last_success = "fixture: nothing", stale_after_s = 600 },
  { name = "elsewhere", role = "component:not-installed-here", canary = "passes", last_success = "fixture: nothing", stale_after_s = 600 },
} }
check(host.write_file(feature_health.installed_registry_path(), json.encode(fixture)), "the fixture registry is written")

-- 3. EACH FAILURE IS NAMED, WITH ITS STAGE, AND IS NOT A PASS.
local child_result = feature_canary.run("broken-child", { dir = canary_dir })
eq(child_result.ok, false, "a child that dies in the turn is not a pass")
eq(child_result.stage, "turn", "the failing stage is the one the child reached")
contains(child_result.detail, "the ledger refused the write", "the child's own words are kept")

local raising = feature_canary.run("raising", { dir = canary_dir })
eq(raising.ok, false, "a canary whose exercise raises is not a pass")
eq(raising.stage, "canary_raised", "the raise is named")
contains(raising.detail, "the exercise itself is broken", "the raise's own words are kept")

local unloadable = feature_canary.run("unloadable-one", { dir = canary_dir })
eq(unloadable.ok, false, "a canary that cannot be loaded is not a pass")
eq(unloadable.stage, "canary_unloadable", "a module that raises while loading is named unloadable, not missing")
contains(unloadable.detail, "cannot even be loaded", "the load error's own words are kept")

local no_dir = feature_canary.run("raising", { dir = canary_dir .. "/nowhere" })
eq(no_dir.stage, "canary_missing", "a canary directory with no module is named missing")

local malformed = feature_canary.run("malformed-one", { dir = canary_dir })
eq(malformed.ok, false, "a canary module that is not a canary is not a pass")
eq(malformed.stage, "canary_malformed", "the shape fault is named")

local absent = feature_canary.run("no-canary", { dir = canary_dir })
eq(absent.ok, false, "a feature with no canary is not a pass")
eq(absent.stage, "canary_missing", "the missing canary is named")
contains(absent.detail, "no canary module", "the missing canary names where it looked")

local unknown = feature_canary.run("not-a-feature", { dir = canary_dir })
eq(unknown.ok, false, "a feature the registry does not have is not a pass")
eq(unknown.stage, "unknown_feature", "the unknown feature is named")

-- 4. A CHILD THAT CANNOT BE SPAWNED IS A NAMED REFUSAL, never a pass: with no binary there is nothing to
--    prove, and 'unknown' must not read as 'fine'.
local real_getenv, real_on_path = host.getenv, host.executable_on_path
host.getenv = function(key) if key == "WA_BIN" then return nil end return real_getenv(key) end
host.executable_on_path = function() return "" end
local refused = feature_canary.child({ scratch = test_home .. "/nowhere" }, {}, {})
eq(refused.stage, "binary_unknown", "a node with no wa binary refuses to pretend it ran a canary")
host.getenv, host.executable_on_path = real_getenv, real_on_path

-- 5. run_all records what each canary answered, and a node that cannot run a feature says off-node
--    rather than failing the node for a component it never had.
local results = feature_canary.run_all({ dir = canary_dir })
check(type(results) == "table", "run_all answers the rows")
local by_name = {}
for _, result in ipairs(results or {}) do by_name[result.feature] = result end
eq(by_name.passing and by_name.passing.ok, true, "the passing canary passes")
eq(by_name.passing and by_name.passing.recorded, true, "the passing verdict is recorded")
eq(by_name["broken-child"].ok, false, "the broken canary is red in the run")
eq(by_name.elsewhere and by_name.elsewhere.skipped, true, "a feature whose component is absent is skipped, not failed")
eq(by_name.elsewhere and by_name.elsewhere.stage, "off-node", "the skip is named off-node")

local report = feature_health.report()
local reported = {}
for _, item in ipairs(report or {}) do reported[item.name] = item end
eq(reported.passing.verdict, "working", "a canary that passed reads as working in the report")
eq(reported["broken-child"].verdict, "failing", "a canary that failed reads as failing in the report")
eq(reported["broken-child"].last_fail_stage, "turn", "the failing stage reaches the snapshot")
eq(reported.elsewhere.verdict, "off-node", "an absent component reads off-node")

local lines = feature_canary.lines(results)
contains(table.concat(lines, "\n"), "canaries: 1 passed, 5 failed, 1 off-node", "the summary counts every class")
contains(table.concat(lines, "\n"), "FAIL", "a failure is printed, not hidden")

print(string.format("feature-canary ok (%d checks)", checks))
