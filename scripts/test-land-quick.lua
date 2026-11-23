-- `wa land <branch>`: THE LANDING ITSELF, AND THE LINE VICTOR READS (FACTORY.md rule 10).
--
-- One of five parts by subject (scripts/lib/land-quick.lua says why the row is in parts, with the
-- measurements: 178 checks and ~3,200 host.exec calls in one row, 112 s alone at load 12.8, 145 s when eight
-- copies run at once). This part proves, as one landing does:
--
--   * a landing runs NO gate and makes NO release: merge -> tests -> push -> main -> install -> health, one
--     ledger row per step, and the counters prove nothing was built, signed, shipped or published;
--   * the line the operator reads: "Local is evolved to <sha>" plus what to test;
--   * the brief is where the "how" comes from - from the ready box, or from the mission's own brief.md when
--     the branch was landed without `wa land ready --brief`.
local Q = dofile("scripts/lib/land-quick.lua")
Q.arm("test-land-quick.lua")
local R = Q.R
local land, repo, ok, eq, contains, must, write_file, read_file = Q.land, Q.repo, Q.ok, Q.eq, Q.contains, Q.must, Q.write_file, Q.read_file
local setup_fixture, journal_of, step_of, marker = Q.setup_fixture, Q.journal_of, Q.step_of, Q.marker
local json, state, ledger, trim = Q.json, Q.state, Q.ledger, Q.trim
local behaviour, observed, install_dir = Q.behaviour, Q.observed, Q.install_dir
local fixture, branch_with, main_grows, first_line_ish = Q.fixture, Q.branch_with, Q.main_grows, Q.first_line_ish
local running, said, rows_of = Q.running, Q.said, Q.rows_of
-- ---------------------------------------------------------------- case 1: the landing itself
fixture()
local code = running(function() return land.run({ run = "quick1", landing = true, branches = { "change/lua" } }) end)
eq(code, 0, "the landing is green")
local journal = journal_of("quick1")
ok(journal ~= nil, "the run has a journal")
eq(journal.landing, true, "the journal says this round is a landing")
eq(journal.result, "done", "the run is recorded done")
for _, name in ipairs({ "collect", "plan", "merge", "tests", "push", "main", "install", "health", "report" }) do
  ok(step_of("quick1", name) ~= nil, "the landing ran " .. name)
end
for _, name in ipairs({ "review", "gate", "artifacts", "sign", "ship", "publish", "deploy" }) do
  eq(step_of("quick1", name), nil, "a landing runs no " .. name .. " (the gate and the release are the release's)")
end
eq(R.observed.builds, 0, "nothing was built")
eq(R.observed.signs, 0, "nothing was signed")
eq(R.observed.ships, 0, "nothing was shipped")
eq(R.observed.publish, 0, "nothing was published")
local tip = journal.tree_commit
ok(tostring(tip):match("^%x+$") ~= nil, "the journal names the landed tip")
eq(journal.main_sha, tip, "main was moved to the landed tip")
contains(must("git -C " .. repo .. " ls-remote origin refs/heads/main"), tip, "main is the tip on the source of truth (read back)")
eq(trim(must("git -C " .. repo .. " rev-parse HEAD")), tip, "the checkout is fast-forwarded to the tip (the deploy builds it)")
eq(observed.deploy_requests, 1, "exactly one deploy was requested")
contains(read_file(install_dir .. "/installed.txt") or "", "commit=" .. tip, "the install record names the landed tip")
contains(step_of("quick1", "install").detail, "installed.txt names", "the step says what it read")
contains(step_of("quick1", "install").detail, "lua/core equals main's", "and that the installed Lua is this landing's")
-- the health step: NOT the measurement itself (that is minutes), the operation that owns it.
eq(step_of("quick1", "health").state, "done", "the health step started")
local operation = state.health_operation or {}
contains(table.concat(operation.args or {}, " "), "land health-run", "the health step starts `wa land health-run` as its own operation")
contains(table.concat(operation.args or {}, " "), "--sha " .. tip, "and names the tip it measures")
-- the ledger: one row per step, in the order they happened
local rows = rows_of("lua")
local steps = {}
for _, row in ipairs(rows) do steps[#steps + 1] = tostring(row.step) end
contains(table.concat(steps, " "), "started collected planned merged", "the first rows are the landing's start and its plan and merge")
contains(table.concat(steps, " "), "pushed main installed install-verified", "the push, main, the install and the verified record come next, in that order")
ok(table.concat(steps, " "):find("reported done$", 1) ~= nil, "and the round ends with the report and its own done row (got " .. table.concat(steps, " ") .. ")")
for _, row in ipairs(rows) do
  eq(row.kind, "land", "every row of the landing is kind=land")
  eq(row.branch, "change/lua", "every row names the branch")
end
local merged = nil
for _, row in ipairs(rows) do if row.step == "merged" then merged = row end end
ok(merged ~= nil, "the merge is a row")
eq(merged.sha, tip, "the merged row carries the landed sha")
eq(merged.result, "green", "and its verdict")
ok(merged.id ~= nil and tonumber(merged.id) > 0, "every row carries the id the feed follows")
-- THE LINE VICTOR READS, and what it does not claim.
local found, line = said("Local is evolved to " .. tip:sub(1, 12))
ok(found, "the landing ends with `Local is evolved to <sha>` (got: " .. table.concat(Q.captured_lines(), " / "):sub(1, 300) .. ")")
contains(line, "You can now test: lua", "and says what to test (the mission's name)")
contains(line, "no brief was recorded", "and says so when nothing describes the steps instead of inventing them")
-- the report reads the landing's own steps
local report = read_file(land.report_path("quick1")) or ""
contains(report, "| tests |", "the report lists the branch's own tests step")
ok(report:find("| deploy |", 1, true) == nil, "and does not list the release's steps the landing never ran")

-- ---------------------------------------------------------------- case 2: the brief is where the "how" comes from
fixture()
local brief = R.fixture .. "/brief.md"
write_file(brief, "# a brief\n\n## How Victor tests it\n`wa land change/lua` in one terminal, and the steps appear.\n\n## Not this section\nignored\n")
local head_lua = trim(must("git -C " .. repo .. " rev-parse refs/heads/change/lua"))
ok(land.ready_mark("change/lua", head_lua, brief), "the ready line records the branch WITH its brief")
local code2 = running(function() return land.run({ run = "quick2", landing = true, ready = true }) end)
eq(code2, 0, "the landing from the ready box is green")
local found2, line2 = said("Local is evolved to")
ok(found2, "the landing still ends with its line")
contains(line2, "wa land change/lua` in one terminal", "and repeats the brief's `How Victor tests it` section")
ok(tostring(line2):find("Not this section", 1, true) == nil, "and nothing past the next heading")

fixture()
local missions_root = type(land.missions_root) == "function" and land.missions_root() or nil
ok(missions_root ~= nil and missions_root:find(host.paths().home, 1, true) == 1,
  "the missions root is this node's own home (got " .. tostring(missions_root) .. ")")
write_file(missions_root .. "/own-brief/brief.md",
  "# the mission\n\n## How Victor tests it\n\nrun `wa land change/own-brief --dry-run` and read the tests step\n\n## Not this\nignored\n")
branch_with("change/own-brief", { ["lua/core/own-brief.lua"] = "return true\n" })
eq(running(function() return land.run({ run = "quick2m", landing = true, branches = { "change/own-brief" } }) end), 0,
  "the branch lands with no ready brief at all")
local found2m, line2m = said("Local is evolved to")
ok(found2m, "the landing ends with its line")
contains(line2m, "run `wa land change/own-brief --dry-run` and read the tests step",
  "and quotes the mission's own `How Victor tests it` instead of saying nothing describes the steps")
ok(tostring(line2m):find("ignored", 1, true) == nil and tostring(line2m):find("no brief was recorded", 1, true) == nil,
  "and neither the text past the next heading nor the old \"no brief\" line")

if R.count() > 0 and false then os.exit(1) end
print(string.format("landing ok (%d checks)", R.count()))
