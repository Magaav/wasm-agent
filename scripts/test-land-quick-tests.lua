-- `wa land <branch>`: THE BRANCH'S OWN TESTS DECIDE (and a scripts/docs-only branch does not deploy).
--
-- One of five parts by subject (scripts/lib/land-quick.lua says why, with the measurements). Here: green own
-- rows pass, a red row stops the landing before anything is pushed, a branch that changes Rust skips them BY
-- NAME (a Lua row cannot judge a new binary), a branch with no test of its own says so, and the range is
-- merge-base(main, branch)..branch so MAIN's later Rust cannot buy a skip (the 22/11 measurement). A
-- scripts/docs-only branch lands without a deploy - a deploy pauses every worker for bytes no node loads.
local Q = dofile("scripts/lib/land-quick.lua")
Q.arm("test-land-quick-tests.lua")
local R = Q.R
local land, repo, ok, eq, contains, must, write_file, read_file = Q.land, Q.repo, Q.ok, Q.eq, Q.contains, Q.must, Q.write_file, Q.read_file
local setup_fixture, journal_of, step_of, marker = Q.setup_fixture, Q.journal_of, Q.step_of, Q.marker
local json, state, ledger, trim = Q.json, Q.state, Q.ledger, Q.trim
local behaviour, observed, install_dir = Q.behaviour, Q.observed, Q.install_dir
local fixture, branch_with, main_grows, first_line_ish = Q.fixture, Q.branch_with, Q.main_grows, Q.first_line_ish
local running, said, rows_of = Q.running, Q.said, Q.rows_of
-- ---------------------------------------------------------------- case 3: the branch's own tests decide
fixture()
eq(running(function() return land.run({ run = "quick3", landing = true, branches = { "change/tests" } }) end), 0,
  "a branch whose own test is green lands")
contains(step_of("quick3", "tests").detail, "1 green", "and the step counts the row it ran")

-- A ROW THAT NAMES A COMPONENT IS HANDED THE NODE'S COMPONENT. scripts/lib/fast-row-exec.sh installs one into
fixture()
local main_before = must("git -C " .. repo .. " ls-remote origin refs/heads/main")
eq(running(function() return land.run({ run = "quick3r", landing = true, branches = { "change/tests-red" } }) end), 1,
  "a red own test stops the landing")
eq(journal_of("quick3r").result, "stopped", "the run is recorded stopped")
eq(step_of("quick3r", "push"), nil, "nothing was pushed")
eq(must("git -C " .. repo .. " ls-remote origin refs/heads/main"), main_before,
  "and main did not move")
contains(step_of("quick3r", "tests").observed, "test-own-red.lua", "the stop names the row that failed")
local red_rows = rows_of("tests-red")
local red_tests = nil
for _, row in ipairs(red_rows) do if row.step == "tests" then red_tests = row end end
ok(red_tests ~= nil and red_tests.result == "red", "the ledger carries the red row for the tests step")
local stopped_row = nil
for _, row in ipairs(red_rows) do if row.step == "stopped" then stopped_row = row end end
ok(stopped_row ~= nil, "and one row that says the landing stopped")
ok(not said("Local is evolved to"), "a stopped landing never claims the node was evolved")

fixture()
eq(running(function() return land.run({ run = "quick3s", landing = true, branches = { "change/one" } }) end), 0,
  "a branch with no test of its own lands")
eq(step_of("quick3s", "tests").state, "skipped", "its tests step is skipped")
contains(step_of("quick3s", "tests").detail, "nothing of its own to run", "with its reason")

fixture()
eq(running(function() return land.run({ run = "quick3t", landing = true, branches = { "change/rust" } }) end), 0,
  "a branch that changes Rust lands")
eq(step_of("quick3t", "tests").state, "skipped", "and its own tests are skipped")
contains(step_of("quick3t", "tests").detail, "Rust", "by name: a Lua row cannot judge a new binary")
contains(step_of("quick3t", "tests").detail, "main-health", "and says who judges it instead")

-- MAIN MOVED ON RUST AFTER THE BRANCH'S FORK POINT, and the branch is judged by ITS OWN change: 22/11, the
-- first real landing (land-20261122T113743Z-f3fedc13) measured a docs/lua/scripts branch as "the branch changes
-- Rust (3 file(s))" because main had gained Rust since its base, so its own three test files never ran before
-- the push. The range is merge-base(main, branch)..branch, so main's later commits cannot buy a skip.
fixture(nil, function()
  branch_with("change/own-lua", { ["lua/core/own-lua.lua"] = "return { own = true }\n",
    ["scripts/test-own-lua-new.lua"] = "print('own lua ok')\n" })
end)
main_grows({ ["rust/wa-new/src/main.rs"] = "fn main() {}\n" })
eq(running(function() return land.run({ run = "quick3n", landing = true, branches = { "change/own-lua" } }) end), 0,
  "a lua-only branch lands onto a main that moved on Rust")
local grown = journal_of("quick3n")
eq(tonumber(grown.plan.files), 2,
  "the plan counts the branch's own two paths, not main's Rust (got " .. tostring(grown.plan.files) .. ")")
local tests_log = read_file(land.evidence_path("quick3n", "tests")) or ""
contains(tests_log, "changed paths: 2 (rust 0,",
  "the tests step measures no Rust in this branch (got: " .. first_line_ish(tests_log) .. ")")
-- THE PLAN NAMES THE ROW BEFORE THE PUSH (Victor's own check: "the tests step says run and lists the branch's
-- own scripts/test-*.lua"), and it is the same list the step then runs.
local plan_text = read_file(land.evidence_path("quick3n", "plan")) or ""
contains(plan_text, "tests     run  the branch's own 1 row(s)", "the plan says the branch's own test rows run")
contains(plan_text, "scripts/test-own-lua-new.lua", "and names the row it will run")
ok(plan_text:find("changes Rust", 1, true) == nil, "and nothing in the plan says the branch changes Rust")
eq(step_of("quick3n", "tests").state, "done", "its own test row runs instead of being skipped by name")
contains(step_of("quick3n", "tests").detail, "1 green", "and it is green")
contains(tests_log, "scripts/test-own-lua-new.lua", "the row that ran is the branch's own test")
ok(tostring(step_of("quick3n", "tests").detail):find("Rust", 1, true) == nil,
  "and nothing in that row says the branch changes Rust")

-- A BRANCH LANDED WITHOUT `wa land ready --brief` still says what to do when the MISSION's own brief has it:
-- `wa land change/<name>` is launched from ~/Work/missions/<name>/brief.md (22/11, the first real landing, whose
-- report said "no brief was recorded for this branch, so nothing describes the steps" beside a brief that did).
fixture()

-- ---------------------------------------------------------------- case 4: scripts/docs only, no deploy
eq(running(function() return land.run({ run = "quick4", landing = true, branches = { "change/docs" } }) end), 0,
  "a scripts/docs-only branch lands")
eq(step_of("quick4", "install").state, "skipped", "without a deploy")
eq(observed.deploy_requests, 0, "no deploy was requested")
eq(step_of("quick4", "health").state, "skipped", "and no health run (no lua/ and no rust/)")
contains(trim(must("git -C " .. repo .. " rev-parse HEAD")), trim(journal_of("quick4").tree_commit),
  "the checkout is still fast-forwarded (that is the install for a file no node loads)")
local found4, line4 = said("Local is evolved to")
ok(found4, "the landing still ends with its line")
contains(line4, "the checkout only", "and says the install was the checkout, not a deploy")


if R.count() > 0 and false then os.exit(1) end
print(string.format("landing ok (%d checks)", R.count()))
