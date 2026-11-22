-- `wa land` -- THE REST OF A PLAN: the ready box, the classifier run on the REAL scripts, the gate rows,
-- the wave order, the cost estimate and the report.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-rows.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-rows.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local json, land, tree_root, fixture, repo, incoming, origin, ok, eq, contains, shell = R.json, R.land, R.tree_root, R.fixture, R.repo, R.incoming, R.origin, R.ok, R.eq, R.contains, R.shell
local must, write_file, read_file, setup_fixture, marker, advance_main, journal_of = R.must, R.write_file, R.read_file, R.setup_fixture, R.marker, R.advance_main, R.journal_of
local step_of, SOLO_RING, standard_checks = R.step_of, R.SOLO_RING, R.standard_checks

R.start_vault()

setup_fixture()
must("rm -f " .. land.ready_file(), "an empty ready box")
local tip_one = must("git -C " .. repo .. " rev-parse change/one")
eq(land.cli({ "land", "ready", "change/one", tip_one }), 0, "a READY line is recorded")
contains(read_file(land.ready_file()) or "", "READY change/one " .. tip_one, "the box holds the line")
local ready_code = land.run({ run = "case15", signer = "local", ring = SOLO_RING, ready = true, no_deploy = true, checks = standard_checks() })
eq(ready_code, 0, "the ready box is enough to land")
local ready_journal = journal_of("case15")
eq(#ready_journal.branches, 1, "one branch was collected from the box")
eq(ready_journal.branches[1].name, "change/one", "the branch named in the line")
eq(step_of("case15", "deploy").state, "skipped", "--no-deploy skips the deploy, by name")
contains(step_of("case15", "deploy").detail, "--no-deploy", "the skip says why")
advance_main(ready_journal.tree_commit)

-- A recorded sha that no longer matches the branch is a refusal, not a silent upgrade.
must("rm -f " .. land.ready_file(), "an empty ready box")
land.ready_mark("change/one", string.rep("0", 40))
local moved_code = land.run({ run = "case16", signer = "local", ring = SOLO_RING, ready = true, no_deploy = true, checks = standard_checks() })
eq(moved_code, 1, "a moved branch is refused")
eq(step_of("case16", "collect").error, "ready_sha_moved", "the refusal is named")
contains(step_of("case16", "collect").next, "moved", "the refusal says what to do")

-- ---------------------------------------------------------------- case 18: the fastlane plan
--
-- The mission's rule: the round takes the CHEAPEST safe path, decided from what changed before anything runs.
-- These cases stand the REAL classifier and the REAL record script in a fixture and assert the decisions - the
-- categories, the steps each one skips, the gate's narrowing with its never-dropped core, the deploy's waves
-- (canary first, the middle together, the account node last, stop at the first failure) and the cost report
-- against the journal's own history.

-- The classifier is the tree's own (`scripts/lib/land-classify.sh` + `scripts/lib/node-binaries.sh`): a fork
-- of the rule would be a plan that disagrees with the deploy about the same file.
for _, relative in ipairs({ "scripts/lib/land-classify.sh", "scripts/lib/node-binaries.sh", "scripts/publish-lua-tree.sh", "scripts/lib/lua-tree.sh" }) do
  must("mkdir -p " .. repo .. "/" .. (relative:match("^(.*)/[^/]+$") or "."), "mkdir for " .. relative)
  must("cp -f " .. tree_root .. "/" .. relative .. " " .. repo .. "/" .. relative, "copy " .. relative)
end
must("git add -A && git commit -q -m fastlane-fixtures", "commit the fastlane fixtures", repo)

local function classify(paths)
  local command = "bash scripts/lib/land-classify.sh --repo " .. repo
  for _, path in ipairs(paths) do command = command .. " " .. path end
  return must(command, "classify", repo)
end
local function category_of(paths)
  local command = "bash scripts/lib/land-classify.sh --category --repo " .. repo
  for _, path in ipairs(paths) do command = command .. " " .. path end
  return (must(command, "category", repo):gsub("%s+$", ""))
end

-- 18a. The four classes, on paths whose answer is not a guess.
eq(category_of({ "docs/LAND.md", "skills/x/SKILL.md" }), "docs-only", "markdown is the docs path")
eq(category_of({ "lua/core/agent.lua", "ui/app.js", "scripts/fast.sh" }), "lua-scripts-only",
  "the Lua tree, the UI and the scripts are the lua path")
eq(category_of({ "rust/components/wa-whatsapp/src/lib.rs", "components.lock" }), "components",
  "a component's own crate and its pins are the components path")
eq(category_of({ "lua/core/agent.lua", "rust/wa-host/src/main.rs" }), "compiled", "the strongest class wins")
eq(category_of({ "rust/components/graph/src/lib.rs", "rust/wa-whatsapp-outbox/src/lib.rs" }), "compiled",
  "a crate the NODE also compiles is compiled even though a component uses it")
contains(classify({ "rust/components/graph/src/lib.rs" }), "component\trust/components/graph/src/lib.rs",
  "one line per path, class then path")
-- The classification IS `wa_compiled_input`, not a second opinion about it: the same function the deploy's Lua
-- fast path and the release digest use decides here.
contains(classify({ "rust/wa-host/src/main.rs" }), "compiled\trust/wa-host/src/main.rs", "rust/ is compiled")
contains(classify({ "docs/LAND.md" }), "docs\tdocs/LAND.md", "a document is not compiled")

-- 18b. The steps each path skips, and the artifact each one builds.
local function steps_of(category) return land.plan_steps(category) end
eq(steps_of("docs-only").artifacts.action, "skip", "docs-only builds nothing")
eq(steps_of("docs-only").deploy.action, "skip", "docs-only deploys nothing")
eq(steps_of("docs-only").sign.action, "skip", "docs-only signs nothing")
contains(steps_of("docs-only").deploy.why, "docs-only", "the skip says why")
eq(steps_of("lua-scripts-only").artifacts.kind, "lua-tree", "the lua path writes a tree record")
eq(steps_of("lua-scripts-only").ship.action, "skip", "the lua path ships no node release")
eq(steps_of("lua-scripts-only").deploy.action, "run", "the lua path deploys the tree to every node")
eq(steps_of("components").artifacts.kind, "components", "the components path rebuilds the bundle")
eq(steps_of("components").deploy.action, "run", "and deploys the repinned components")
for _, name in ipairs({ "artifacts", "sign", "ship", "publish", "deploy" }) do
  eq(steps_of("compiled")[name].action, "run", "the compiled path runs " .. name)
end

-- 18c. The gate: the always-on checks are never dropped, a path adds only what it touches, and a changed Lua
-- module maps to the rows that mention it (proved by grep on the fixture, not by a naming convention alone).
local function gate_for(paths)
  local wanted = land.gate_checks_for(paths)
  local names = {}
  for _, name in ipairs({ "fast", "prompt-docs", "codemode-component", "cargo-codemode", "cargo-wa-whatsapp" }) do
    if wanted[name] then names[#names + 1] = name end
  end
  return table.concat(names, ",")
end
eq(gate_for({ "docs/LAND.md" }), "fast,prompt-docs", "a document runs the fast path and the prompt-docs check only")
eq(gate_for({ "rust/components/wa-whatsapp/src/lib.rs" }), "fast,prompt-docs,cargo-wa-whatsapp",
  "the WhatsApp component's crate brings its own check")
eq(gate_for({ "lua/core/codemode.lua" }), "fast,prompt-docs,codemode-component,cargo-codemode",
  "a code-mode path brings its two checks")

-- A changed module maps to rows: the fixture carries one row that names `lua/core/agent.lua` and one that does
-- not, and only the first may be planned.
-- The fixture carries the REAL row inventory (scripts/lib/fast-rows.sh): the planner reads the rows a round may
-- request from it (the function scripts/fast.sh builds its lua.list with), so a fixture without it can prove
-- nothing about narrowing.
must("mkdir -p scripts/lib", "fixture lib dir", repo)
write_file(repo .. "/scripts/lib/fast-rows.sh", read_file(tree_root .. "/scripts/lib/fast-rows.sh") or "")
must("mkdir -p scripts lua/core", "fixture dirs", repo)
write_file(repo .. "/lua/core/agent.lua", "return {}\n")
write_file(repo .. "/scripts/test-agent-thing.lua", "-- mentions lua/core/agent.lua\n")
write_file(repo .. "/scripts/test-unrelated-thing.lua", "-- mentions nothing\n")
write_file(repo .. "/scripts/test-fast-row-environment.lua", "-- the core row\n")
must("git add -A && git commit -q -m rows", "commit the rows", repo)
local row_run = { id = "rows", journal = { repo = repo, base = "HEAD~1", branches = { { name = "x", sha = "HEAD" } } } }
local rows = land.gate_rows(row_run, { "lua/core/agent.lua" })
eq(#rows, 1, "one row mentions the changed module")
eq(rows[1], "scripts/test-agent-thing.lua", "and it is the one the grep found")
eq(#land.gate_rows(row_run, { "lua/core/agent.lua", "scripts/test-unrelated-thing.lua" }), 2,
  "a changed row is planned too")
eq(#land.gate_rows(row_run, { "docs/LAND.md" }), 0, "no row maps to a document, which makes the run whole")
-- 18c-2. ONE row inventory. The planner requests only rows this fast path would run, and a row the ledger
-- declares not run is REPORTED with its reason, never requested - requesting it is `fast_narrow:unknown_row`
-- and a round gated on zero tests (measured twice: land-20261118T172243Z-666a59cf, land-20261118T173351Z-2a481142).
write_file(repo .. "/scripts/fast-path.exclude",
  "scripts/test-agent-thing.lua  # needs a ledger the fast path has not got\n" ..
  "scripts/test-agent-unrunnable.lua  # needs a real raw terminal\n")
write_file(repo .. "/scripts/test-agent-live.lua", "-- mentions lua/core/agent.lua\n")
write_file(repo .. "/scripts/test-agent-unrunnable.lua", "-- mentions lua/core/agent.lua\n")
must("git add -A && git commit -q -m inventory", "commit the inventory", repo)
local planned, not_planned = land.gate_rows(row_run, { "lua/core/agent.lua" })
eq(#planned, 1, "only a row this fast path would run is requested")
eq(planned[1], "scripts/test-agent-live.lua", "and it is the live one")
eq(#not_planned, 2, "the declared rows are reported as not a gate row")
local why_of = {}
for _, entry in ipairs(not_planned) do why_of[entry.path] = entry.why end
contains(why_of["scripts/test-agent-thing.lua"] or "", "needs a ledger", "the report carries the ledger's reason")
contains(why_of["scripts/test-agent-unrunnable.lua"] or "", "raw terminal", "and the reason of a row found by name")
-- A changed path that IS a test the ledger declares not run: not requested, reported with the reason.
local only_declared, declared_report = land.gate_rows(row_run, { "scripts/test-agent-thing.lua" })
eq(#only_declared, 0, "a changed test the ledger declares not run is never requested")
eq(#declared_report, 1, "it is reported instead")
contains(declared_report[1] and declared_report[1].why or "", "needs a ledger", "with the ledger's reason")
local narrowed_text = land.plan_text({ plan = { files = 1, category = "lua-scripts-only", counts = {},
  classifier = "land-classify.sh", checks = { "fast" }, rows = planned, not_rows = not_planned, full = false } })
contains(narrowed_text, "not a gate row: scripts/test-agent-thing.lua (needs a ledger", "the plan reports it by name")
contains(narrowed_text, "over 1 Lua row(s)", "and asks for exactly one row")
-- The list the plan produces is a request `scripts/fast.sh` ACCEPTS: the real filter, the real candidate list,
-- over the rows this plan chose.
write_file(fixture .. "/rows.txt", table.concat(planned, "\n") .. "\n")
must("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_candidates' > " .. fixture .. "/candidates.txt",
  "candidate list", repo)
local accepted, accepted_out, accepted_err = shell("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_filter " ..
  fixture .. "/candidates.txt " .. fixture .. "/rows.txt'", repo)
eq(accepted, 0, "the planned rows are a request fast.sh accepts (" .. tostring(accepted_err) .. ")")
contains(accepted_out, "scripts/test-agent-live.lua", "the run would execute the planned row")
contains(accepted_out, "scripts/test-fast-row-environment.lua", "with the always-on core rows the runner adds")
-- The request the planner used to make - a declared row in it - is the refusal those two landings met, so the
-- two lists differ by a verdict and not by taste.
write_file(fixture .. "/rows-declared.txt", "scripts/test-agent-thing.lua\n")
local refused, _, refused_err = shell("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_filter " ..
  fixture .. "/candidates.txt " .. fixture .. "/rows-declared.txt'", repo)
eq(refused, 2, "a request naming the declared row is refused, so nothing runs")
contains(refused_err, "fast_narrow:unknown_row", "by the name the two measured landings hit")

-- 18c-3. `--full` means the whole suite: no WA_FAST_ROWS file, and every check. The rows file itself is
-- proved against the MERGED TREE (18c-4 below), so these cases carry a real one.
must("mkdir -p " .. land.run_dir("rows-full") .. " " .. land.run_dir("rows-plan-full"), "rows dirs")
local narrowed_plan = { plan = { rows = { "scripts/test-agent-live.lua" }, full = false } }
eq(land.gate_rows_file({ id = "rows-full", tree = repo, journal = narrowed_plan }, { full = true }), nil,
  "--full writes no rows file")
eq(read_file(land.run_dir("rows-full") .. "/gate-rows.txt"), nil, "and none exists on disk for that round")
eq(land.gate_rows_file({ id = "rows-plan-full", tree = repo, journal = { plan = { rows = {}, full = true } } }, {}), nil,
  "a plan that already runs the whole suite writes none either")
local full_checks, full_why = land.gate_checks({ journal = { plan = { checks = { "fast" } } } }, { full = true })
eq(#full_checks, #land.DEFAULT_CHECKS, "--full runs every gate check, not the narrowed set")
contains(full_why, "--full", "and the gate says so")
-- 18c-4. The rows file is proved against the MERGED TREE, never the planner's checkout.
--
-- WHY. The plan is made before anything is merged, from the operator's checkout (journal.repo);
-- scripts/fast.sh runs in the merged worktree (run.tree). The two lists disagree in both directions and each
-- disagreement was a broken gate:
--
--   * a branch that ADDS scripts/test-new.lua is not a row the planner's checkout has, so the plan said "not a
--     gate row" and the branch's own new test never ran - a narrowed gate that silently dropped the row the
--     change brought with it;
--   * a branch that ADDS an exclude line (or DELETES a row) left the plan requesting a row the merged tree's
--     runner refuses: fast_narrow:unknown_row, and the whole round gated on zero tests.
--
-- The merged tree is built the way impl.merge builds one: a worktree of the base with the branch merged in.
local rows_ref = must("git -C " .. repo .. " rev-parse --abbrev-ref HEAD")
local rows_base = must("git -C " .. repo .. " rev-parse HEAD")
local function merged_row_tree(name, edit)
  local branch = "change/" .. name
  must("git -C " .. repo .. " checkout -q -B " .. branch .. " " .. rows_base, "branch " .. branch)
  edit()
  must("git -C " .. repo .. " add -A && git -C " .. repo .. " commit -q -m " .. name, "commit " .. name)
  local sha = must("git -C " .. repo .. " rev-parse HEAD")
  local tree = fixture .. "/merged-" .. name
  must("git -C " .. repo .. " worktree add --quiet -b land-" .. name .. " " .. tree .. " " .. rows_base,
    "worktree for " .. name)
  must("git -C " .. tree .. " merge --no-ff --no-edit -m " .. name .. " " .. sha, "merge " .. name)
  -- The planner's checkout keeps the base: it must NOT hold what only the branch has.
  must("git -C " .. repo .. " checkout -q --detach " .. rows_base, "leave the base checked out")
  return sha, tree
end
local function rows_run(id, tree, sha, rows)
  must("mkdir -p " .. land.run_dir(id), "run dir " .. id)
  return { id = id, tree = tree, journal = { repo = repo, base = rows_base,
    branches = { { name = "change/x", sha = sha } }, plan = { rows = rows, checks = { "fast" }, full = false } } }
end

-- The branch ADDS a test row. The planner's checkout cannot see it...
local added_sha, added_tree = merged_row_tree("newrow", function()
  write_file(repo .. "/scripts/test-new-agent-row.lua", "-- mentions lua/core/agent.lua\n")
end)
local planner_run = { id = "rows-planner", journal = { repo = repo, base = rows_base,
  branches = { { name = "change/newrow", sha = added_sha } } } }
local planner_rows, planner_not = land.gate_rows(planner_run, { "lua/core/agent.lua", "scripts/test-new-agent-row.lua" })
eq(table.concat(planner_rows, " "), "scripts/test-agent-live.lua",
  "the planner's checkout maps the changed module to the one runnable row it has")
local planner_why = {}
for _, entry in ipairs(planner_not) do planner_why[entry.path] = entry.why end
contains(planner_why["scripts/test-new-agent-row.lua"] or "", "not a row this fast path runs",
  "and reports the branch's own new row as not a gate row, by name")
-- ...and the gate asks for it anyway, because the merged tree HAS it as a row.
local added_run = rows_run("rows-added", added_tree, added_sha, { "scripts/test-agent-live.lua" })
local added_file, added_failed, added_notes = land.gate_rows_file(added_run, {})
ok(added_file ~= nil and not added_failed, "a narrowed round gets a WA_FAST_ROWS file")
local added_text = read_file(added_file) or ""
contains(added_text, "scripts/test-agent-live.lua", "holding the rows the plan chose")
contains(added_text, "scripts/test-new-agent-row.lua", "AND the row the branch added, which the planner's checkout cannot see")
contains(table.concat(added_notes, " | "), "scripts/test-new-agent-row.lua", "and the evidence names what it asks for")
must("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_candidates' > " .. fixture .. "/candidates-added.txt",
  "the merged tree's candidate list", added_tree)
local added_code, added_out, added_err = shell("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_filter " ..
  fixture .. "/candidates-added.txt " .. added_file .. "'", added_tree)
eq(added_code, 0, "the merged tree's own filter accepts the request (" .. tostring(added_err) .. ")")
contains(added_out, "scripts/test-new-agent-row.lua", "so the branch's own new row really runs")

-- The branch ADDS an exclude line: a row the plan asked for is no longer a row the merged tree can run.
local excluded_sha, excluded_tree = merged_row_tree("excluder", function()
  write_file(repo .. "/scripts/fast-path.exclude",
    "scripts/test-agent-thing.lua  # needs a ledger the fast path has not got\n" ..
    "scripts/test-agent-unrunnable.lua  # needs a real raw terminal\n" ..
    "scripts/test-agent-live.lua  # this round excludes it\n")
end)
-- One runnable row left: it is requested, the excluded one is dropped BY NAME.
local two_run = rows_run("rows-two", excluded_tree, excluded_sha,
  { "scripts/test-agent-live.lua", "scripts/test-fast-row-environment.lua" })
local two_file, two_failed, two_notes = land.gate_rows_file(two_run, {})
ok(two_file ~= nil and not two_failed, "a round with one runnable row left is still narrowed")
local two_text = read_file(two_file) or ""
contains(two_text, "scripts/test-fast-row-environment.lua", "the runnable row is requested")
ok(two_text:find("scripts/test-agent-live.lua", 1, true) == nil,
  "the row the merged tree excludes is NOT requested (got " .. two_text .. ")")
local two_why = table.concat(two_notes, " | ")
contains(two_why, "scripts/test-agent-live.lua", "the dropped row is named in the evidence")
contains(two_why, "this round excludes it", "with the ledger's own reason")
-- Nothing left: no rows file at all, so the whole suite runs.
local none_run = rows_run("rows-none", excluded_tree, excluded_sha, { "scripts/test-agent-live.lua" })
local none_file, _, none_notes = land.gate_rows_file(none_run, {})
eq(none_file, nil, "a round whose only row the merged tree excludes writes no rows file")
eq(read_file(land.run_dir("rows-none") .. "/gate-rows.txt"), nil, "and none exists on disk")
local none_why = table.concat(none_notes, " | ")
contains(none_why, "the whole suite runs", "the gate says the whole suite runs")
contains(none_why, "scripts/test-agent-live.lua", "and names the row it dropped")
-- The stale list the plan would have written is exactly what the merged tree refuses: this is the failure.
write_file(fixture .. "/rows-stale.txt", "scripts/test-agent-live.lua\n")
must("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_candidates' > " .. fixture .. "/candidates-excluded.txt",
  "the excluded tree's candidate list", excluded_tree)
local stale_code, _, stale_err = shell("bash -c '. scripts/lib/fast-rows.sh && wa_fast_row_filter " ..
  fixture .. "/candidates-excluded.txt " .. fixture .. "/rows-stale.txt'", excluded_tree)
eq(stale_code, 2, "the pre-merge request really is refused, so nothing would run")
contains(stale_err, "fast_narrow:unknown_row", "by the name this case prevents")
-- And no merged tree at all is no proof of anything: the whole suite runs.
local no_tree, _, no_tree_notes = land.gate_rows_file({ id = "rows-notree", journal = narrowed_plan }, {})
eq(no_tree, nil, "without a merged tree no row is proved runnable")
contains(table.concat(no_tree_notes or {}, " | "), "the whole suite runs", "and the gate says so")
must("git -C " .. repo .. " checkout -q " .. rows_ref, "restore the fixture checkout")

-- 18c-5. The fast check ALWAYS carries WA_FAST_ROWS, empty when the round narrowed nothing: scripts/fast.sh
-- narrows only on a NON-EMPTY WA_FAST_ROWS ([ -n "$WA_FAST_ROWS" ]), so one inherited from the environment
-- would narrow a --full run that wrote no rows file - a run executing less than it said, obeying somebody
-- else's plan.
-- Review r2, MUST 2 and 3: the gate must hand the discrimination check the ROUND it is judging. Without
-- --branches a Refactor-only line never gets refused in a multi-branch round, and without the round's
-- base the check re-judges tests against origin/main when this round merged incoming/main instead.
do
  local command = land.gate_command({ name = "discrimination", command = "bash scripts/test-discriminates.sh origin/main" },
    nil, { journal = { base = "deadbeefcafe", branches = { { name = "change/a" }, { name = "change/b" } } } })
  contains(command, "--branches", "MUST 2: the gate names the round's branches: " .. tostring(command))
  contains(command, "'change/a,change/b'", "MUST 2: both branch names travel: " .. tostring(command))
  contains(command, "deadbeefcafe", "MUST 3: the round's base travels, not a hard-coded origin/main: " .. tostring(command))
  local single = land.gate_command({ name = "discrimination", command = "bash scripts/test-discriminates.sh origin/main" },
    nil, { journal = { base = "cafe", branches = { { name = "change/one" } } } })
  contains(single, "change/one", "a single-branch round still names its branch: " .. tostring(single))
  eq(land.gate_command({ name = "prompt-docs", command = "bash scripts/sync-prompt-docs.sh --check" },
    nil, { journal = { base = "cafe", branches = {} } }), "bash scripts/sync-prompt-docs.sh --check",
    "and no other check is touched by the round fields")
end
eq(land.gate_command({ name = "fast", command = "bash scripts/fast.sh" }, nil),
  "WA_FAST_ROWS= bash scripts/fast.sh", "no rows file means an EMPTY WA_FAST_ROWS, not an absent one")
eq(land.gate_command({ name = "fast", command = "bash scripts/fast.sh" }, "/tmp/rows.txt"),
  "WA_FAST_ROWS='/tmp/rows.txt' bash scripts/fast.sh", "a narrowed round names its file")
eq(land.gate_command({ name = "cargo-codemode", command = "cargo test" }, nil), "cargo test",
  "and no other check is touched")
local env_probe = fixture .. "/rows-env.sh"
write_file(env_probe, "#!/usr/bin/env bash\nprintf '%s\n' \"$WA_FAST_ROWS\"\n")
eq(must("env WA_FAST_ROWS=" .. fixture .. "/inherited.txt bash " .. env_probe), fixture .. "/inherited.txt",
  "an inherited WA_FAST_ROWS really does reach a check that does not set it")
eq(must("env WA_FAST_ROWS=" .. fixture .. "/inherited.txt " ..
  land.gate_command({ name = "fast", command = "bash " .. env_probe }, nil)), "",
  "and the empty assignment the gate always makes removes it")
-- At the gate: the command it actually runs, on both paths.
local saved_gate_exec = land.exec
local gate_commands = {}
-- Only the gate's own checks are answered here (they are held to their command); everything else - the row
-- inventory the rows file is proved with, the git calls - still runs for real.
local function is_gate_check(command)
  for _, marker in ipairs({ "scripts/fast.sh", "scripts/test-codemode-component.sh", "scripts/gate-cargo-codemode.sh", "cargo test", "sync-prompt-docs", "test-discriminates.sh" }) do
    if command:find(marker, 1, true) then return true end
  end
  return false
end
land.exec = function(command, cwd, timeout)
  if not is_gate_check(command) then return saved_gate_exec(command, cwd, timeout) end
  gate_commands[#gate_commands + 1] = command
  return { code = 0, stdout = "test result: ok. 3 passed\n", stderr = "" }
end
local saved_weight = land.weight_decorator
land.weight_decorator = ""
eq(land.impl.gate(added_run, {}), true, "a narrowed gate runs")
-- The exact command, now including the failed-row log directory (item 3 of the harness-fixes-2 round):
-- fast.sh keeps every failed row's own log there before it deletes its scratch directory, so a red gate
-- can still be read afterwards. Exact equality, not a prefix: the whole command is still pinned.
eq(gate_commands[1], "WA_FAST_ROWS='" .. land.run_dir("rows-added") .. "/gate-rows.txt'"
  .. " WA_FAST_KEEP_LOGS='" .. land.run_dir("rows-added") .. "/evidence/fast-logs' bash scripts/fast.sh",
  "the narrowed gate runs the fast check with the round's rows file (got " .. tostring(gate_commands[1]) .. ")")
contains(table.concat(gate_commands, "\n"), "scripts/test-discriminates.sh",
  "the gate runs the discrimination check: a branch whose new test does not discriminate cannot land")
gate_commands = {}
eq(land.impl.gate(added_run, { full = true }), true, "a --full gate runs")
eq(gate_commands[1], "WA_FAST_ROWS= WA_FAST_KEEP_LOGS='" .. land.run_dir("rows-added") .. "/evidence/fast-logs' bash scripts/fast.sh",
  "--full runs the fast check with WA_FAST_ROWS EMPTY (got " .. tostring(gate_commands[1]) .. ")")
contains(read_file(land.evidence_path("rows-added", "gate")) or "", "WA_FAST_ROWS=",
  "and the evidence logs the command that ran, not one it might have run")
land.exec = saved_gate_exec
land.weight_decorator = saved_weight

do
  -- 18c-6. A `git diff` that FAILS is not a round that changed nothing. M.changed_paths answered an empty list
  -- for a broken diff, which the plan read as "nothing to land" and the rows file as "no row to add" - so an
  -- unreadable git could refuse a landing, or narrow a gate, with no line anywhere saying so. The list now carries
  -- a named note, and every caller that would narrow on it runs the whole suite instead.
  local broken_sha = "0000000000000000000000000000000000000000"
  local function broken_journal()
    return { repo = repo, base = broken_sha, branches = { { name = "change/unreadable", sha = rows_base } } }
  end
  local broken_paths, broken_notes = land.changed_paths({ journal = broken_journal() })
  eq(#broken_paths, 0, "a diff that cannot be read yields no path")
  eq(#broken_notes, 1, "and one note instead of a silence")
  contains(broken_notes[1] or "", "change/unreadable", "the note names the branch whose diff failed")
  contains(broken_notes[1] or "", "could not be read", "and says what happened to it")
  -- The gate: the rows file it would have written is a request the merged tree refuses (18c-4), so the whole
  -- suite runs and the evidence names the failure.
  must("mkdir -p " .. land.run_dir("rows-unreadable") .. " " .. land.run_dir("plan-unreadable"), "unreadable run dirs")
  local unreadable_run = { id = "rows-unreadable", tree = repo, journal = broken_journal() }
  unreadable_run.journal.plan = { rows = { "scripts/test-agent-live.lua" }, checks = { "fast" }, full = false }
  local unreadable_file, _, unreadable_why = land.gate_rows_file(unreadable_run, {})
  eq(unreadable_file, nil, "an unreadable diff writes no rows file")
  eq(read_file(land.run_dir("rows-unreadable") .. "/gate-rows.txt"), nil, "and none exists on disk")
  local unreadable_text = table.concat(unreadable_why or {}, " | ")
  contains(unreadable_text, "could not be read", "the gate names the failure in its evidence")
  contains(unreadable_text, "the whole suite runs", "and says the whole suite runs")
  -- The plan: not the "nothing to land" refusal a broken git used to produce, and not a narrowed plan either.
  local broken_plan = land.build_plan({ journal = broken_journal() }, {}, broken_notes)
  eq(broken_plan.full, true, "a plan built on an unreadable diff runs the whole suite")
  eq(#broken_plan.checks, #land.DEFAULT_CHECKS, "with every gate check")
  eq(#broken_plan.rows, 0, "and no row it cannot prove")
  contains(tostring(broken_plan.unknown_paths or ""), "could not be read", "the plan records why")
  local broken_text = land.plan_text({ plan = broken_plan })
  contains(broken_text, "the changed paths could not be read", "the printed plan says the count is unknown")
  ok(broken_text:find("0 path(s) changed", 1, true) == nil, "and prints no file count it does not have")
  -- The door the operator uses: impl.plan answers a plan (and an evidence line), never "no changes".
  local plan_run = { id = "plan-unreadable", journal = broken_journal() }
  eq(land.impl.plan(plan_run, {}), true, "a round whose diff cannot be read still plans")
  eq(plan_run.journal.plan and plan_run.journal.plan.full, true, "onto the full path")
  contains(read_file(land.evidence_path("plan-unreadable", "plan")) or "", "could not be read",
    "and the failure is in the plan's own evidence")
  -- A diff that CAN be read is untouched: no note, and no path invented.
  local readable_paths, readable_notes = land.changed_paths({ journal = { repo = repo, base = rows_base,
    branches = { { name = "change/readable", sha = rows_base } } } })
  eq(#readable_paths, 0, "the base against itself changes no path")
  eq(#readable_notes, 0, "and a diff that worked has nothing to report")
end

-- 18d. The deploy's waves: canary alone, the middle together, the account node last.
local function wave_names(plan)
  local parts = {}
  for index, wave in ipairs(plan.waves) do
    local names = {}
    for _, entry in ipairs(wave) do names[#names + 1] = tostring(entry.node) end
    parts[index] = table.concat(names, "+")
  end
  return table.concat(parts, " | ")
end
local route = land.deploy_waves(land.RING, {})
eq(wave_names(route), "work | mail+nextcloud | openclaw",
  "the canary goes first alone, the middle goes together, the account node goes last")
eq(route.canary, "work", "the default canary is work")
eq(route.account, "openclaw", "the default account node is openclaw")
eq(route.canary_defaulted, nil, "a ring that names the canary does not default it")
local named = land.deploy_waves(land.RING, { canary = "nextcloud", account = "mail" })
eq(wave_names(named), "nextcloud | work+openclaw | mail", "the canary and the account node are knobs, not constants")
local ringless = land.deploy_waves({ { node = "a", mode = "tree" }, { node = "openclaw", mode = "tree" } }, {})
eq(wave_names(ringless), "a |  | openclaw", "a ring without `work` still gets a canary (the first non-account node)")
eq(ringless.canary_defaulted, true, "and the plan says the canary defaulted")
eq(#land.deploy_waves(land.RING, { canary = "work", account = "work" }).waves[3], 0,
  "a canary that IS the account node is not deployed twice")

-- 18e. A cost estimate and a report that compares: written once, read back from the journal.
local estimate = land.estimate("docs-only", {})
ok(estimate.seconds > 0, "the estimate is a number even with no history")
eq(estimate.per_step.deploy, 0, "the docs path expects no deploy at all")
eq(estimate.per_step.artifacts, 0, "and no build")
ok(estimate.per_step.gate > 0, "the gate is never free")
contains(estimate.from, "13/11", "with no finished run the estimate says where its numbers come from")
-- A journal with two finished runs is what the next plan measures against.
for index, seconds in ipairs({ 100, 300 }) do
  local id = "history" .. index
  write_file(land.journal_path(id), json.encode({ run = id, result = "done", created_at = 1, updated_at = 1,
    steps = { gate = { name = "gate", state = "done", seconds = seconds } },
    plan = { category = "lua-scripts-only" } }))
end
local measured = land.estimate("lua-scripts-only", land.land_runs())
eq(measured.per_step.gate, 200, "the gate's median comes from the journal, not from the fallback table")
contains(measured.from, "median", "and the plan says it was measured")
local average = land.journal_average(land.land_runs())
ok(average ~= nil and average.average > 0, "the report's comparison has a number to compare with")
ok(average.runs >= 2, "over the finished runs only (earlier cases in this row are finished runs too)")

-- 18f. The report names the path, the per-step time, the total and the journal's average.
local report_text = land.report_text({ run = "report-check", result = "done", plan = { category = "lua-scripts-only",
  expected_seconds = 600, expected_from = "median of 2 finished run(s)" },
  steps = { gate = { state = "done", seconds = 120 }, artifacts = { state = "done", seconds = 30 } },
  deploy_plan = { canary = "work", account = "openclaw", waves = { { "work" }, { "mail", "nextcloud" }, { "openclaw" } } },
  deploy = { { node = "work", mode = "tree", wave = 1, state = "installed", seconds = 12 } } })
contains(report_text, "## cost", "the report has a cost table")
contains(report_text, "`lua-scripts-only`", "it names the path the round took")
contains(report_text, "total | 2m30s", "it states the total in the same units as the plan")
contains(report_text, "journal average", "and the journal's average to compare with")
contains(report_text, "deploy order: canary work -> parallel mail+nextcloud -> account openclaw",
  "the report names the deploy's waves")

R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
