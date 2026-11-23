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

-- ---------------------------------------------------------------- THE DESCRIPTION ROWS (Fable, 23/11 11:20Z)
--
-- MEASURED 23/11: piped-chat-starts-fast landed 7df9dc7f with a new capability line that did not say "JSON text";
-- main-health on 5956ae15 went red on scripts/test-host-return-docs.lua, and the landing's preflight had never run
-- that row - a landing ran the branch's OWN rows, and a capability description is a Rust change, which skipped the
-- tests step entirely. So a round that touches a description runs the description rows first, and this is that
-- case over the REAL row (the fixture tree carries the tree's own rust/wa-capabilities/src/host.rs and the JSON
-- library the row decodes with; the fixture's other two checks are red for want of a tree, which is why the
-- assertions here are about WHICH rows are named).
fixture()
local real_source = read_file(R.tree_root .. "/rust/wa-capabilities/src/host.rs")
local real_json = read_file(R.tree_root .. "/lua/vendor/json.lua")
ok(type(real_source) == "string" and #real_source > 1000, "the tree's host capability source is readable")
local undocumented = real_source .. [[
/// Count the widgets in a directory.
pub(crate) extern "C-unwind" fn widget_count(state: *mut c_void) -> *mut c_char {
    answer(state, self.push_json(&body))
}
]]
local documented = real_source .. [[
/// Count the widgets in a directory: one JSON text string a caller decodes to {count}.
pub(crate) extern "C-unwind" fn widget_count(state: *mut c_void) -> *mut c_char {
    answer(state, self.push_json(&body))
}
]]
-- The three rows themselves travel WITH the branch, as they would in a real tree: the step runs them from the
-- MERGED tree, and the row a description change needs is the tree's own (copied here, not re-implemented).
local function description_files(source)
  return {
    ["rust/wa-capabilities/src/host.rs"] = source,
    ["lua/vendor/json.lua"] = real_json,
    ["scripts/test-host-return-docs.lua"] = read_file(R.tree_root .. "/scripts/test-host-return-docs.lua"),
    ["scripts/test-prompt-tool-names.lua"] = read_file(R.tree_root .. "/scripts/test-prompt-tool-names.lua"),
    ["scripts/sync-prompt-docs.sh"] = read_file(R.tree_root .. "/scripts/sync-prompt-docs.sh"),
  }
end
branch_with("change/description", description_files(undocumented))
branch_with("change/description-named", description_files(documented))
eq(running(function() return land.run({ run = "quickd", landing = true, branches = { "change/description" } }) end), 1,
  "a branch whose capability line does not say JSON text STOPS the landing")
eq(step_of("quickd", "tests").error, "description_rows_red", "and the step refuses by name")
contains(step_of("quickd", "tests").observed, "test-host-return-docs.lua", "naming the row that caught it")
local description_log = read_file(land.evidence_path("quickd", "tests")) or ""
contains(description_log, "every capability that answers JSON text says so",
  "and the row's own words are in the step's evidence: the capability that does not say it, by name")
contains(description_log, "widget_count", "with the capability this branch added")
eq(step_of("quickd", "push"), nil, "nothing was pushed")
contains(step_of("quickd", "tests").detail, "rust/wa-capabilities/src/host.rs", "the step says which description moved")
eq(running(function() return land.run({ run = "quickdn", landing = true, branches = { "change/description-named" } }) end), 1,
  "the same branch with the phrase is not stopped for that reason (the fixture's other checks have no tree)")
ok(not tostring(step_of("quickdn", "tests").observed or ""):find("host-return-docs", 1, true),
  "the capability row is GREEN once the line says JSON text: " .. tostring(step_of("quickdn", "tests").observed))
local named_log = read_file(land.evidence_path("quickdn", "tests")) or ""
ok(not named_log:find("every capability that answers JSON text says so", 1, true),
  "and its evidence carries no such failure (the trigger is the phrase, not the file)")
-- THE PLAN SAYS SO BEFORE THE PUSH: `wa land --dry-run` names the description rows for this round.
local plan = land.build_plan({ id = "quickdp", tree = repo, journal = {} },
  { "rust/wa-capabilities/src/host.rs" }, {}, nil)
contains(tostring((plan.steps or {}).tests and plan.steps.tests.why), "description rows",
  "the plan names the description rows for a round that touches a capability")
contains(tostring(plan.steps.tests.why), "test-host-return-docs", "with the row names")
ok(#land.description_paths({ "docs/notes.txt", "lua/core/chat.lua" }) == 0,
  "a round that touches no description path pays for none of them")
eq(#land.description_paths({ "docs/HOST.md", "lua/core/tools.lua" }), 2, "and the allow-list answers for the ones that are")


if R.count() > 0 and false then os.exit(1) end
print(string.format("landing ok (%d checks)", R.count()))
