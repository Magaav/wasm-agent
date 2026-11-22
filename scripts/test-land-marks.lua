-- `wa land` -- THE MARKS: a publish marked by hand only against evidence the world confirms, the ring a resume
-- keeps, and an operator pin that stops a deploy by name.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-marks.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-marks.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local land, fixture, ok, eq, contains, must, write_file, setup_fixture, behaviour = R.land, R.fixture, R.ok, R.eq, R.contains, R.must, R.write_file, R.setup_fixture, R.behaviour
local journal_of, step_of, SOLO_RING, standard_checks = R.journal_of, R.step_of, R.SOLO_RING, R.standard_checks

R.start_vault()

local function publish_cases()

-- THE RED GATE'S CHECK SET, defined here for the one case below that calls it: it belongs to the part that
-- runs case 24 (scripts/test-land-resume-19-11.lua), and repeating two lines is cheaper - and clearer - than a
-- shared name every part would have to carry.
local red_checks = function()
  return { { name = "fast", command = "bash " .. fixture .. "/land-gate/gate-red.sh", timeout = 60 } }
end
setup_fixture()
behaviour.release_present = false
-- A round with no gh must stop at publish when the release genuinely is not there; when it WAS
-- there, the round used to stop anyway - that is the defect the next block proves is gone.
local quiet_exec = land.exec
land.exec = function(command, cwd, timeout)
  if command:match("^command %-v gh") then return { code = 0, stdout = "no\n", stderr = "" } end
  return quiet_exec(command, cwd, timeout)
end
local blocked_code = land.run({ run = "case27", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(blocked_code, 1, "the round stops where gh is missing")
eq(step_of("case27", "publish").state, "failed", "at the publish step")
local evidence_path = fixture .. "/publish-evidence.txt"
write_file(evidence_path, "release node-... created by hand on the account node\n")
local no_evidence_ok, no_evidence = land.mark("case27", "publish", nil, {})
eq(no_evidence_ok, false, "a mark with no evidence is refused")
eq(no_evidence.error, "mark_evidence_required", "by name")
local missing_ok, missing_answer = land.mark("case27", "publish", fixture .. "/absent.txt", {})
eq(missing_ok, false, "a mark naming a file that does not exist is refused")
eq(missing_answer.error, "mark_evidence_missing", "by name")
-- The world does not support the claim yet: the release is not there.
behaviour.release_present = false
local false_ok, false_answer = land.mark("case27", "publish", evidence_path, {})
eq(false_ok, false, "a mark the world contradicts is refused")
eq(false_answer.error, "mark_not_verified", "and the refusal says the claim could not be verified")
eq(step_of("case27", "publish").state, "failed", "the step is untouched by a refused mark")
-- Now it is there, and the mark records it - with the evidence path and the flag.
behaviour.release_present = true
local mark_ok, mark_answer = land.mark("case27", "publish", evidence_path, {})
ok(mark_ok, "a verified mark is recorded: " .. tostring(mark_answer and (mark_answer.error or mark_answer.detail) or ""))
local marked_step = step_of("case27", "publish")
eq(marked_step.state, "done", "the step is done in the journal")
eq(marked_step.marked, true, "and it says it was marked")
eq(marked_step.mark_evidence, evidence_path, "naming the file that proves it")
local marked_journal = journal_of("case27")
eq(marked_journal.publish and marked_journal.publish.tag, "node-" .. tostring(marked_journal.tree_commit):sub(1, 12),
  "the publish record the step would have written is written")
local again_ok, again = land.mark("case27", "publish", evidence_path, {})
eq(again_ok, false, "marking a finished step again is refused")
eq(again.error, "mark_already_settled", "by name")
land.exec = quiet_exec

-- ---------------------------------------------------------------- case 28: the start options are the run's
-- A resume is the same round continued, so the ring and --no-deploy it started with still hold: measured
-- 18/11, a resumed round took the DEFAULT ring and deployed a node the operator had left out (item 28).
setup_fixture()
R.state.deploy_requests = {}
write_file(fixture .. "/land-gate/gate-red.sh", "#!/usr/bin/env bash\nexit 1\n")
must("chmod +x " .. fixture .. "/land-gate/gate-red.sh", "the red gate runs")
local one_node_ring = { { node = "work", mode = "tree" } }
eq(land.run({ run = "case28", signer = "local", ring = one_node_ring, no_deploy = false, full = true,
  branches = { "change/one" }, checks = red_checks() }), 1, "the round stops at the red gate")
local started = journal_of("case28").start
ok(type(started) == "table", "the journal stores the start options")
eq(started.full, true, "--full is one of them")
eq(started.ring and started.ring[1] and started.ring[1].node, "work", "and the ring, resolved")
R.state.deploy_requests = {}
eq(land.run({ resume = true, checks = standard_checks() }), 0, "the resume finishes the round")
local rang = {}
for _, request in ipairs(R.state.deploy_requests) do rang[request.node] = true end
ok(rang["work"], "the resumed round deployed the canary")
ok(not rang["openclaw"] and not rang["mail"] and not rang["nextcloud"],
  "and only the ring it started with - not the default ring of four nodes")
-- A node an operator pinned is never moved by a ring silently.
setup_fixture()
R.state.deploy_requests = {}
local pins = dofile("lua/core/pins.lua")
pins.set({ node = "work", kind = "operator", state = "active", reason = "operator test pin" })
local pinned_code = land.run({ run = "case28b", signer = "local", ring = one_node_ring, branches = { "change/one" }, checks = standard_checks() })
eq(pinned_code, 1, "a ring that would move a pinned node stops")
eq(step_of("case28b", "deploy").error, "node_pinned", "the refusal is the pin, by name")
contains(step_of("case28b", "deploy").detail or "", "active operator pin", "and it says the node is pinned")
local asked_pinned = false
for _, request in ipairs(R.state.deploy_requests) do if request.node == "work" then asked_pinned = true end end
ok(not asked_pinned, "nothing was asked of the pinned node")
pins.clear("work", { kind = "released", reason = "test done" })
end
publish_cases()

R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
