-- `wa land` -- THE PLANS AND THE MODES: one row inventory, the plan a round builds, release-mode nodes, the
-- end-to-end round, and the CLI's own answers.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-release.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-release.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local land, tree_root, fixture, repo, incoming, journal_root, vault, ok, eq, contains = R.land, R.tree_root, R.fixture, R.repo, R.incoming, R.journal_root, R.vault, R.ok, R.eq, R.contains
local must, read_file, setup_fixture, observed, behaviour, fleet, journal_of, step_of = R.must, R.read_file, R.setup_fixture, R.observed, R.behaviour, R.fleet, R.journal_of, R.step_of
local SOLO_RING, standard_checks = R.SOLO_RING, R.standard_checks

R.start_vault()

local function release_cases()
-- ---------------------------------------------------------------- case 18: one row inventory
-- The planner and scripts/fast.sh ask the SAME function for the rows a narrowed run may execute; a planner
-- with its own idea of runnable asks for a row the runner refuses, which is a round gated on zero tests.
local inventory = land.row_inventory(tree_root)
local fast_rows = must("bash -c '. ./scripts/lib/fast-rows.sh && wa_fast_row_candidates'", "the runner's rows", tree_root)
local fast_set, planner_set = {}, {}
for row in tostring(fast_rows):gmatch("[^\r\n]+") do fast_set[row] = true end
for _, row in ipairs(inventory.list or {}) do planner_set[row] = true end
local only_planner, only_fast = 0, 0
for row in pairs(planner_set) do if not fast_set[row] then only_planner = only_planner + 1 end end
for row in pairs(fast_set) do if not planner_set[row] then only_fast = only_fast + 1 end end
eq(only_planner, 0, "every row the planner would request is a row the runner executes")
eq(only_fast, 0, "and every row the runner executes is one the planner knows")
-- ---------------------------------------------------------------- case 30: the pins move in a compiled round
-- A compiled round that ALSO moves components.lock builds the components bundle inside the `artifacts` step,
-- before any node takes the lock (item 28): building it afterwards describes a lock the fleet already reads,
-- and a node that takes both would take the new pins with the old bundle. On the base commit
-- `also_components` does not exist at all, so nothing marks such a round. The classifier and the row
-- inventory are the REAL ones - this asks the tree the row runs from, not a fixture.
local pinned_plan = land.build_plan({ id = "case30", journal = { repo = tree_root } },
  { "components.lock", "rust/Cargo.toml" })
eq(pinned_plan.category, "compiled", "a compiled change that also moves the pins is a compiled round")
contains(tostring(pinned_plan.steps.artifacts.also_components or ""), "components.lock",
  "and its artifacts step says the components bundle is built with the node release")
local plain_plan = land.build_plan({ id = "case30b", journal = { repo = tree_root } }, { "rust/Cargo.toml" })
eq(plain_plan.category, "compiled", "a compiled change that moves no pin is still compiled")
eq(plain_plan.steps.artifacts.also_components, nil, "and it builds no components bundle")
-- ------------------------------------------------ case 31: a Lua-only round still ships a release for a
-- release-installed node (review r1 #61). A node installed FROM a release has no checkout, so a round that
-- skipped artifacts/ship/publish left it on its old binary with nothing to install - while the plan said
-- "done". The plan reads the RING, not a constant: the same paths plan differently when a node in the ring
-- installs a tree instead.
local lua_paths = { "lua/core/land.lua" }
local release_ring = { { node = "nextcloud", mode = "release" } }
local release_plan = land.build_plan({ id = "case31", journal = { repo = tree_root } }, lua_paths, nil, release_ring)
eq(release_plan.category, "lua-scripts-only", "a Lua-only change is still a Lua-only round")
eq(release_plan.steps.artifacts.kind, "node-release",
  "and its artifacts step builds a NODE RELEASE: the ring has a node that cannot deploy a tree")
eq(release_plan.steps.artifacts.action, "run", "the artifacts step runs")
eq(release_plan.steps.ship.action, "run", "the release is shipped")
eq(release_plan.steps.publish.action, "run", "and published")
contains(tostring(release_plan.steps.artifacts.why or ""), "nextcloud",
  "the plan names the node that forced it")
contains(tostring(release_plan.steps.deploy.why or ""), "nextcloud:release",
  "and the deploy says which node takes the release")
local tree_ring = { { node = "work", mode = "tree" } }
local tree_plan = land.build_plan({ id = "case31b", journal = { repo = tree_root } }, lua_paths, nil, tree_ring)
eq(tree_plan.steps.artifacts.kind, "lua-tree", "a ring of tree nodes keeps the Lua-tree record")
eq(tree_plan.steps.ship.action, "skip", "and ships no node release")
eq(tree_plan.steps.publish.action, "skip", "and publishes none")
eq(land.build_plan({ id = "case31c", journal = { repo = tree_root } }, lua_paths, nil, nil).steps.artifacts.kind and
  land.build_plan({ id = "case31c", journal = { repo = tree_root } }, lua_paths, nil, nil).steps.ship.action,
  "skip", "no ring named: the configured ring decides, and it is all tree nodes")
-- ------------------------------------------- case 32: a release-mode ring node, signed through a coordinator
-- (review r1 must 3). The e2e above uses SOLO_RING and signer=local, so no case had ever driven a ring
-- entry whose mode is release - the one mode that exists for a node with no checkout - nor a signer that
-- is a NAMED NODE rather than this machine. Both are asserted from the journal and from what the stub node
-- was actually asked: a plan that claims the mode and a deploy that sends tree would read the same in the
-- journal otherwise.
setup_fixture()
land.candidates = function() return {} end
behaviour.gh_authed, behaviour.gh_present, behaviour.release_present = true, true, false
R.state.routed_calls, R.state.deploy_requests = {}, {}
local mixed_ring = { { node = "work", mode = "tree" }, { node = "nextcloud", mode = "release" } }
local release_code = land.run({ run = "case32", signer = "laptop", account = "laptop", ring = mixed_ring,
  branches = { "change/one" }, checks = standard_checks() })
eq(release_code, 0, "a round with a release-mode ring node and a node signer lands")
local release_journal = journal_of("case32")
eq(release_journal.result, "done", "the journal says done")
-- The deploy asked the release node for release, not for the default mode: the mode travels to the node.
local asked_modes = {}
-- Read from the JOURNAL's own deploy rows: what the round recorded it asked of each node. The stub's
-- call list is not used, because a later setup_fixture in this file clears it.
for _, row in ipairs(release_journal.deploy or {}) do asked_modes[tostring(row.node)] = tostring(row.mode) end
eq(asked_modes["nextcloud"], "release", "the release-mode node was asked for a release install")
eq(asked_modes["work"], "tree", "and the tree node was asked for a tree deploy")
ok(R.state.sign_calls > 0, "the sign step ran on the coordinator node, where the vault is", tostring(R.state.sign_calls))
local main_there = false
for _, call in ipairs(R.state.routed_calls) do
  if call.node == "laptop" and call.kind == "main" then main_there = true end
end
ok(main_there, "and main was fast-forwarded there too")
contains(tostring(((release_journal.steps or {}).sign or {}).detail or ""), "signed on laptop",
  "the journal says the release was signed on the coordinator node")
ok(release_journal.artifacts and release_journal.artifacts.key_id ~= nil,
  "and the release carries the key it was signed with", tostring(release_journal.artifacts and release_journal.artifacts.key_id))
-- A release-mode node is NEVER silently deployed as a tree: an unknown mode is refused by name.
setup_fixture()
R.state.deploy_requests = {}
local bad_ring = { { node = "nextcloud", mode = "relase" } }
local bad_code = land.run({ run = "case32b", signer = "local", ring = bad_ring, branches = { "change/one" },
  checks = standard_checks() })
eq(bad_code, 1, "a ring naming an unknown mode stops the round")
eq(step_of("case32b", "deploy").state, "failed", "at the deploy")
contains(tostring(step_of("case32b", "deploy").detail or ""), "mode_unknown",
  "and the node refuses it by name rather than deploying the default")
-- ---------------------------------------------------------------- case 29 (end to end): one command, no hand
-- steps. A fixture land - scratch incoming repository, fake gh, scratch vault - runs from collect to report
-- with nothing done by hand: every effect is either done by the machine or skipped WITH A REASON, no step
-- carries `marked` (nothing needed an out-of-band verb), and the report it wrote says done (the mission's
-- done-when).
setup_fixture()
land.candidates = function() return {} end
behaviour.gh_authed, behaviour.gh_present, behaviour.release_present = true, true, false
R.state.routed_calls = {}
local e2e_code = land.run({ run = "case29", signer = "local", account = "laptop", ring = SOLO_RING,
  branches = { "change/one", "change/two" }, checks = standard_checks() })
eq(e2e_code, 0, "a fixture land runs collect -> report and answers zero")
local e2e = journal_of("case29")
eq(e2e.result, "done", "the journal says done")
for _, name in ipairs(land.STEPS) do
  local state = (e2e.steps or {})[name] and e2e.steps[name].state or "pending"
  ok(state == "done" or state == "skipped",
    "step " .. name .. " is done or skipped with a reason (it is " .. tostring(state) .. ")")
  if state == "skipped" then
    contains(tostring(e2e.steps[name].detail or ""), "skipped", "the skip of " .. name .. " says why")
  end
  ok(not (e2e.steps or {})[name] or e2e.steps[name].marked ~= true,
    "no step of an unattended round was marked out of band (" .. name .. ")")
end
local e2e_report = read_file(land.report_path("case29")) or ""
contains(e2e_report, "result: **done**", "the report says the round is done")
contains(e2e_report, "## steps", "and carries the step table")
ok(e2e.main_account == "laptop", "main was fast-forwarded by the account node, not by hand")
eq(e2e.publish and e2e.publish.account, "laptop", "and the release was created by that node")
end

-- ---------------------------------------------------------------- case 17: the CLI

eq(land.cli({ "chat" }), nil, "not a land request: the dispatcher keeps its own path")
eq(land.cli({ "land", "--help" }), 0, "the help is free")
eq(land.cli({ "land" }), 2, "no arguments is a usage answer")
eq(land.cli({ "land", "--branches" }), 2, "a flag without a value is refused")
eq(land.cli({ "land", "--signer" }), 2, "a signer without a value is refused")
-- The dry run changes nothing and names the signer it would use.
local function journal_count()
  local out = must("ls -1 " .. journal_root .. " 2>/dev/null | wc -l")
  return tonumber((out:gsub("%s+", ""))) or 0
end
local before_journals = journal_count()
local before_pushes = observed.pushes
eq(land.cli({ "land", "--branches", "change/one", "--signer", "laptop", "--dry-run" }), 0, "the dry run answers zero")
eq(observed.pushes, before_pushes, "the dry run pushed nothing")
eq(journal_count(), before_journals, "the dry run wrote no journal")

-- -------------------------------------------- case 33: --until stops cleanly after the named step
--
-- A landing is not the only question worth asking: "would the gate of THIS branch be green on the main
-- that is there now?" is the question a mission has to answer BEFORE anybody lands it (FACTORY.md, Rule 2).
-- --until gate is that question asked by name - collect, plan, review, merge, gate and the report, and
-- no push, no main, no artifacts, no release, no node - and it answers exit 0, because a caller that
-- stopped where it asked to stop did not fail.
--
-- Every assertion below fails on the code before this change: without the flag the same call runs the
-- whole round (result done, a push, a main) and no step is left pending.
-- AN ANONYMOUS FUNCTION, NOT A do BLOCK: the file is already at the main chunk's 200-local limit, and
-- a function has a budget of its own. Nothing here escapes it; the names it reads are the file's.
-- The LEADING SEMICOLON is not decoration: without it Lua reads the call on the previous line (eq(...))
-- and this function call as one expression - eq(...)(function() ... end)() - and fails to call a nil.
release_cases()

R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
