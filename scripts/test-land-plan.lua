-- `wa land` -- THE PLAN: the weight probe, the happy path, a branch whose derived file the merge regenerates,
-- two branches that disagree about one, and a gate that is red, flaky, vacuous or budgeted.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-plan.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-plan.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local land, repo, incoming, origin, vault, ok, flatten, eq, contains, must, write_file = R.land, R.repo, R.incoming, R.origin, R.vault, R.ok, R.flatten, R.eq, R.contains, R.must, R.write_file
local read_file, start_vault, setup_fixture, advance_main, observed, journal_of = R.read_file, R.start_vault, R.setup_fixture, R.advance_main, R.observed, R.journal_of
local step_of, gate_script, set_gate, SOLO_RING, standard_checks = R.step_of, R.gate_script, R.set_gate, R.SOLO_RING, R.standard_checks

-- ---------------------------------------------------------------- case 1: the weight probe
local decorator = land.weight()
ok(decorator == nil or type(decorator) == "string", "the weight probe answers a decorator or nothing")
ok(#land.WEIGHT_CANDIDATES >= 2, "there is more than one weight candidate to fall back through")
contains(land.WEIGHT_CANDIDATES[1].decorator, "CPUWeight", "the first candidate is a systemd CPU/IO weight")
land.weight_decorator = ""

-- ---------------------------------------------------------------- case 2: the happy path
start_vault()
setup_fixture()

local happy = land.run({ run = "case2", signer = "local", branches = { "change/one", "change/two" }, checks = standard_checks() })
eq(happy, 0, "the happy path lands")
local journal = journal_of("case2")
ok(journal ~= nil, "the journal is written")
eq(journal.result, "done", "the run is recorded done")
local expected_state = { review = "done" }   -- the reviewer really runs: its findings are joined at the report
for _, name in ipairs(land.STEPS) do
  eq(step_of("case2", name) and step_of("case2", name).state, expected_state[name] or "done",
    "step " .. name .. " is " .. (expected_state[name] or "done"))
end
local tip = journal.tree_commit
ok(tostring(tip):match("^%x+$") ~= nil, "the journal names a landed tip")
contains(must("git -C " .. repo .. " ls-remote oc-in refs/heads/" .. journal.land_branch), tip,
  "the landed tip is on the incoming repository")
contains(must("git -C " .. repo .. " ls-remote origin refs/heads/main"), tip, "main was fast-forwarded to it")
-- The release set, the signature and the reference.
eq(journal.artifacts.commit, tip, "the release set is this commit's")
contains(journal.artifacts.manifest, "node-" .. tip:sub(1, 12) .. ".manifest", "the journal names the manifest")
ok(read_file(journal.artifacts.manifest) ~= nil, "the manifest is on disk")
if R.state.vault_available then
  eq(journal.artifacts.signed, true, "the release is signed")
  eq(journal.artifacts.signer, "local", "signed on this node (which sets the vault's admin URL)")
  contains(journal.artifacts.key_id, "release-signing-", "the journal names the signing key")
  ok(read_file(journal.artifacts.dir .. "/SHA256SUMS.sig") ~= nil, "SHA256SUMS.sig exists")
  eq(observed.signs, 1, "exactly one signing run")
end
eq(observed.builds, 1, "exactly one build")
eq(observed.ships, 1, "exactly one ship")
contains(must("git -C " .. repo .. " fetch -q oc-in refs/heads/" .. journal.artifacts.ref .. " && git -C " .. repo ..
  " ls-tree -r --name-only FETCH_HEAD"), "SHA256SUMS.sig", "the artifacts ref carries the signature")
contains(must("git -C " .. repo .. " ls-tree -r --name-only FETCH_HEAD"), "SHA256SUMS",
  "the artifacts ref carries SHA256SUMS")
eq(observed.pushes, 1, "exactly one push to the incoming repository")
eq(observed.main_pushes, 1, "exactly one push to main")
eq(observed.publish, 1, "exactly one publish")
eq(journal.publish and journal.publish.state, "published", "the release is recorded published")
eq(journal.publish and journal.publish.signed, true, "and recorded signed")
local nodes = {}
for _, row in ipairs(journal.deploy) do nodes[#nodes + 1] = row.node .. ":" .. row.mode end
eq(table.concat(nodes, ","), "work:tree,mail:tree,nextcloud:binary,openclaw:tree",
  "the ring deploys in order, with openclaw last and nextcloud binary-only")
for _, row in ipairs(journal.deploy) do eq(row.state, "installed", "node " .. row.node .. " is installed") end
local todo_items = {}
for _, todo in ipairs(journal.todos or {}) do todo_items[#todo_items + 1] = todo.item end
eq(table.concat(todo_items, ","), "", "no channel is a TODO any more (the reviewer that landed is the one that runs)")
eq(#(journal.review or {}), 2, "both branches of the round were reviewed")
for _, row in ipairs(journal.review or {}) do
  eq(row.state, "reviewed", "the review of " .. tostring(row.branch) .. " happened")
  eq(row.findings, 2, "its findings are a number in the journal: " .. tostring(row.branch))
end
local report = read_file(land.report_path("case2")) or ""
contains(report, "# wa land case2", "the report is written to a file")
contains(report, "signature", "the report carries the signature row")
contains(report, "nextcloud", "the report carries the per-node results")
contains(report, "## review", "the report carries the review section")
contains(report, "fake reviewer", "and the reviewer's own findings")
-- THE MERGE REGENERATED THE DERIVED FILE, in the merge commit itself. 21/11: two branches that are each
-- correct alone left lua/core/refusal_codes.lua stale, land244 was green anyway, and main was red for the
-- next landings. The fix belongs in the one place that sees both branches, and this is that place.
-- (Its own block: the file is at the main chunk's 200-local limit.)
do
eq(journal.regenerate and journal.regenerate.ran, true, "the merge ran the registered generator")
local changed = (journal.regenerate or {}).changed or {}
eq(#changed, 1, "the merge wrote exactly the declared generated file (got " .. flatten(changed) .. ")")
eq(changed[1], "generated/files.txt", "and it is the file the registry declares")
contains(step_of("case2", "merge").detail, "regenerate wrote generated/files.txt",
  "the merge step says what it regenerated")
local landed_generated = must("git -C " .. repo .. " show " .. tip .. ":generated/files.txt")
contains(landed_generated, "one.txt", "the landed merge commit carries a fresh generated file")
contains(landed_generated, "two.txt", "...with both branches' members in it")
local parents = {}
for word in must("git -C " .. repo .. " rev-list --parents -n 1 " .. tip):gmatch("%S+") do parents[#parents + 1] = word end
eq(#parents, 3, "the regeneration is IN the merge commit (two parents), not a commit of its own")
eq(must("git -C " .. journal.tree .. " status --porcelain"), "", "the merged worktree is clean after the amendment")
advance_main(tip)
end

-- ---------------------------------------- case 2b: a conflict only in a GENERATED file is not a stop
-- Two branches that each regenerated the same derived file disagree about bytes no person wrote. The
-- registry declares which paths those are, so the merge resolves exactly those and regenerates; anything
-- else stops, which case 2c proves in the other direction.
do
local function branch_with(name, path, text)
  must("git -C " .. repo .. " checkout -q -B " .. name .. " main", "branch " .. name)
  write_file(repo .. "/" .. path, text)
  must("git -C " .. repo .. " add -A && git -C " .. repo .. " commit -q -m '" .. name .. "'", "commit " .. name)
  must("git -C " .. repo .. " push -q oc-in " .. name .. ":refs/heads/" .. name, "push " .. name)
  must("git -C " .. repo .. " checkout -q main", "back to main")
end
branch_with("change/gen-a", "generated/files.txt", "a.txt\nfrom-a\n")
branch_with("change/gen-b", "generated/files.txt", "a.txt\nfrom-b\n")
local gen_code = land.run({ run = "case2b", signer = "local", ring = SOLO_RING, branches = { "change/gen-a", "change/gen-b" },
  checks = standard_checks() })
eq(gen_code, 0, "two branches that each edited the generated file still land")
local gen_journal = journal_of("case2b")
local first_resolution = (gen_journal.regenerate_resolved or {})[1]
ok(first_resolution ~= nil, "the journal records that a conflict was resolved, and where")
contains(tostring(first_resolution and first_resolution.paths or ""), "generated/files.txt", "it names the generated path")
local gen_body = must("git -C " .. repo .. " show " .. gen_journal.tree_commit .. ":generated/files.txt")
ok(not gen_body:find("from-a", 1, true) and not gen_body:find("from-b", 1, true),
  "the landed file is neither branch's hand-written bytes, it is the generator's output (got " .. gen_body .. ")")
contains(gen_body, "a.txt", "and it is what the generator writes for the merged tree")
advance_main(gen_journal.tree_commit)
end

-- ---------------------------------------- case 2c: a conflict anywhere else is still a STOP
-- The allow-list is the registry and nothing else: a branch that genuinely conflicts with another must stop
-- the landing for a person, exactly as before this fix.
do
local function branch_with(name, path, text)
  must("git -C " .. repo .. " checkout -q -B " .. name .. " main", "branch " .. name)
  write_file(repo .. "/" .. path, text)
  must("git -C " .. repo .. " add -A && git -C " .. repo .. " commit -q -m '" .. name .. "'", "commit " .. name)
  must("git -C " .. repo .. " push -q oc-in " .. name .. ":refs/heads/" .. name, "push " .. name)
  must("git -C " .. repo .. " checkout -q main", "back to main")
end
branch_with("change/clash-a", "clash.txt", "one\n")
branch_with("change/clash-b", "clash.txt", "two\n")
local clash_code = land.run({ run = "case2c", signer = "local", ring = SOLO_RING, branches = { "change/clash-a", "change/clash-b" },
  checks = standard_checks() })
eq(clash_code, 1, "a conflict in a file nobody declared generated still stops the landing")
eq(step_of("case2c", "merge").error, "merge_conflict", "the refusal is named merge_conflict")
contains(tostring(step_of("case2c", "merge").detail or ""), "clash.txt",
  "and it names the file a person has to resolve: " .. tostring(step_of("case2c", "merge").detail))
end

-- ---------------------------------------------------------------- case 3: a red gate stops the landing
local red = gate_script("gate-red")
set_gate("gate-red", "fail")
observed.pushes = 0
local red_code = land.run({ run = "case3", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks(red) })
eq(red_code, 1, "a red gate stops the landing")
eq(journal_of("case3").result, "stopped", "the run is recorded stopped")
eq(journal_of("case3").stopped_at, "gate", "it stopped at the gate")
eq(step_of("case3", "gate").state, "failed", "the gate step is failed")
contains(step_of("case3", "gate").detail, "failed twice", "the failure names both runs")
ok(read_file(step_of("case3", "gate").evidence) ~= nil, "the gate's evidence file exists")
eq(observed.pushes, 0, "no push happened")

-- ---------------------------------------------------------------- case 4: flaky under load
local flaky = gate_script("gate-flaky")
set_gate("gate-flaky", "flaky")
observed.pushes = 0
local flaky_code = land.run({ run = "case4", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks(flaky) })
eq(flaky_code, 1, "a flaky check stops the landing")
local flaky_step = step_of("case4", "gate")
eq(flaky_step.state, "flaky", "the gate step is recorded flaky, not done")
contains(flaky_step.detail, "flaky under load: fast", "the detail says flaky under load, by name")
eq(journal_of("case4").result, "stopped", "the run is stopped, never silently green")
eq(observed.pushes, 0, "a flaky gate pushes nothing")

-- ---------------------------------------------------------------- case 5: a check that proves nothing
write_file(host.paths().home .. "/land-gate/vacuous.sh", "#!/usr/bin/env bash\nexit 0\n")
local vacuous = land.run({ run = "case5", ring = SOLO_RING, branches = { "change/one" },
  checks = { { name = "cargo-codemode", command = "bash " .. host.paths().home .. "/land-gate/vacuous.sh", min_tests = 1 } } })
eq(vacuous, 1, "a check that proves nothing is not green")
eq(step_of("case5", "gate").error, "gate_vacuous", "the refusal is named")
contains(step_of("case5", "gate").detail, "proved nothing", "the detail says the run proved nothing")

-- ---------------------------------------------------------------- case 5b: a resume keeps what already passed
-- A resume re-ran EVERY gate check, so one red check made the operator pay again for every green one (the
-- 15-minute cargo checks included). Now a check that passed on this tree_commit with this command is kept, by
-- name, and only the red one runs again; a changed command is not the same check and runs again.
do -- its own block: the file is at the main chunk's 200-local limit
local function counting_check(name)
  local path = host.paths().home .. "/land-gate/count-" .. name .. ".sh"
  write_file(path, string.format([[#!/usr/bin/env bash
COUNT="%s/land-gate/count-%s.n"
echo $(( $(cat "$COUNT" 2>/dev/null || echo 0) + 1 )) > "$COUNT"
MODE="$(cat "%s/land-gate/count-%s.state" 2>/dev/null || echo pass)"
[ "$MODE" = pass ] && { echo "%s ok"; exit 0; }
echo "FAIL %s: fake red check"; exit 1
]], host.paths().home, name, host.paths().home, name, name, name))
  return path
end
local function count_of(name)
  return tonumber((read_file(host.paths().home .. "/land-gate/count-" .. name .. ".n") or "0"):match("%d+")) or 0
end
local function set_count_gate(name, mode)
  write_file(host.paths().home .. "/land-gate/count-" .. name .. ".state", mode .. "\n")
end
local green_path, red_path, stop_path = counting_check("green"), counting_check("later"), counting_check("stopper")
set_count_gate("green", "pass")
set_count_gate("later", "fail")
set_count_gate("stopper", "fail")
-- `stopper` stays red throughout, so every attempt stops at the gate and nothing is pushed by this case.
local function keep_checks(extra)
  return { { name = "green", command = "bash " .. green_path .. (extra or ""), timeout = 120 },
           { name = "later", command = "bash " .. red_path, timeout = 120 },
           { name = "stopper", command = "bash " .. stop_path, timeout = 120 } }
end
observed.pushes = 0
eq(land.run({ run = "case5b", ring = SOLO_RING, branches = { "change/one" }, checks = keep_checks() }), 1,
  "a red second check stops the landing")
eq(count_of("green"), 1, "the green check ran once")
eq(count_of("later"), 2, "the red check ran twice (beside, then alone)")
set_count_gate("later", "pass")
eq(land.run({ run = "case5b", ring = SOLO_RING, resume = true, checks = keep_checks() }), 1, "the resume stops at stopper")
eq(count_of("green"), 1, "the resume KEPT the check that passed on this tree - it did not run again")
eq(count_of("later"), 3, "the resume ran the red check again")
eq(count_of("stopper"), 2, "and reached the next check")
local gate5b = journal_of("case5b").gate
eq(gate5b[1].kept, true, "the kept check is marked kept in the journal")
eq(gate5b[1].tree_commit, journal_of("case5b").tree_commit, "it is kept for the sha it passed on")
eq(gate5b[2].kept, nil, "the re-run check is not marked kept")
contains(read_file(step_of("case5b", "gate").evidence) or "", "green: kept - passed on", "the evidence names the kept check")
-- a changed command is a different check: it runs again even on the same tree; an unchanged one stays kept
eq(land.run({ run = "case5b", ring = SOLO_RING, resume = true, checks = keep_checks(" # changed") }), 1, "still stopped")
eq(count_of("green"), 2, "a changed command is not kept: it runs again")
eq(count_of("later"), 3, "the check that passed on its first run last time is kept now")
eq(count_of("stopper"), 4, "the check that failed twice runs again")
eq(observed.pushes, 0, "no attempt of this case pushed")
-- A check with a PER-TEST budget (the discrimination check's shape) sizes its budget from the round's
-- changed paths. The journal's plan.files is their COUNT, and iterating it crashed the gate's own code
-- ("attempt to index a number value", 21/11 batch-4) before the check ever ran.
local budget_checks = { { name = "budgeted", command = "bash " .. green_path, timeout = 120, per_test_seconds = 30 },
                        { name = "stopper", command = "bash " .. stop_path, timeout = 120 } }
eq(land.run({ run = "case5c", ring = SOLO_RING, branches = { "change/one" }, checks = budget_checks }), 1,
  "the landing stops at the red check")
local gate5c = journal_of("case5c").gate or {}
eq(gate5c[1] and gate5c[1].name, "budgeted", "the per-test-budget check RAN (the gate did not crash sizing it)")
eq(gate5c[1] and gate5c[1].ok, true, "and passed")
end

-- ---------------------------------------------------------------- case 6: resume after the deploy failed on node 3
-- A fresh repository: case 2 landed these branches and advanced main, so merging them again here would be a
-- no-op and the tip would already BE main - the run would have nothing to push and prove nothing.

R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
