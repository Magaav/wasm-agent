-- `wa land` -- THE REVIEWER'S CHANNEL: beside the gate, its own opt-out switch, a reviewer that cannot
-- run, and the join that reads its answer.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-review.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-review.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local json, land, repo, ok, eq, contains, must, write_file, read_file, review_home = R.json, R.land, R.repo, R.ok, R.eq, R.contains, R.must, R.write_file, R.read_file, R.review_home
local REVIEW_MARKER, fill, review_start, review_forget, review_arguments, review_started = R.REVIEW_MARKER, R.fill, R.review_start, R.review_forget, R.review_arguments, R.review_started
local setup_fixture, marker, advance_main, observed, behaviour, journal_of, step_of = R.setup_fixture, R.marker, R.advance_main, R.observed, R.behaviour, R.journal_of, R.step_of
local SOLO_RING, standard_checks = R.SOLO_RING, R.standard_checks

R.start_vault()

setup_fixture()
review_start("gate")
review_forget()
-- The gate's row touches the marker the fake waits for: a landing that serialised the review before the merge
-- and the gate could never touch it, and the findings would never arrive.
local overlap_gate = host.paths().home .. "/land-gate/gate-overlap.sh"
write_file(overlap_gate, fill([==[#!/usr/bin/env bash
# A gate row that leaves a trace the review can see: if the review ran AFTER the gate, this file is written
# after the fake looked for it, and the fake answers nothing.
touch @@MARKER@@
echo "fast: 12 rows ok"
]==], { MARKER = REVIEW_MARKER }))
local brief_path = review_home .. "/brief-one.md"
write_file(brief_path, "The brief for change/one: one file, one behavior, one string.\n")
must("rm -f " .. land.ready_file(), "an empty ready box")
local tip_one = must("git -C " .. repo .. " rev-parse change/one")
eq(land.cli({ "land", "ready", "change/one", tip_one, "--brief", brief_path }), 0,
  "a READY line with a brief is recorded")
contains(read_file(land.ready_file()) or "", "brief=" .. brief_path, "the brief travels on the ready line")
local reviewed_code = land.run({ run = "case13", signer = "local", ring = SOLO_RING, ready = true, no_deploy = true,
  checks = standard_checks(overlap_gate) })
eq(reviewed_code, 0, "a reviewer's findings never block a landing")
ok(read_file(REVIEW_MARKER) ~= nil, "the gate ran while the review was still going: the review is not serialised before it")
local reviewed = journal_of("case13")
eq(#(reviewed.review or {}), 1, "one review row per branch of the round")
local review_row = reviewed.review[1]
eq(review_row.branch, "change/one", "the row names the branch")
eq(review_row.state, "reviewed", "the review happened")
eq(review_row.findings, 2, "its findings are a number in the journal, not a sentence")
eq(review_row.review_id, "fake-001", "the row names the review, so a finding can be marked afterwards")
contains(review_row.answer, "fake reviewer", "the reviewer's own answer is in the journal")
eq(review_row.unavailable, nil, "and the field is absent, not empty")
eq(step_of("case13", "review").state, "done", "the review step is done once the reviews are joined")
contains(step_of("case13", "review").detail, "2 finding(s)", "the step counts the findings it reported")
local got_arguments = review_arguments()
contains(got_arguments, "branch=change/one", "the reviewer was given the branch")
contains(got_arguments, "base=" .. tostring(reviewed.base), "and the base the round is landing on")
contains(got_arguments, "brief=" .. brief_path, "and the brief the ready box knew")
eq(review_started(), 1, "exactly one review was started for one branch")
local review_report = read_file(land.report_path("case13")) or ""
contains(review_report, "## review", "the report has a review section")
contains(review_report, "fake reviewer", "the report carries the findings")
contains(review_report, "fake-001", "the report names the review")
advance_main(reviewed.tree_commit)

-- 13b. The reviewer's own opt-out switch: `reviewer = off` reaches the landing through the reviewer's own
-- module, so nothing is started and the step says which switch stopped it. A landing is not a second place
-- where "off" can mean something else. Proved on the step itself - the switch is read before anything else can
-- happen, so a landing around it would prove nothing more and cost a release build.
review_start("findings")
review_forget()
local real_engine = land.review_engine
land.review_engine = function()
  return { switch = function() return { on = false, source = "config <home>/.wasm-agent/env", value = "off" } end }
end
local off_run = { id = "case13b", journal = { run = "case13b", base = tostring(journal_of("case13").base),
  repo = repo, branches = { { name = "change/two", sha = must("git -C " .. repo .. " rev-parse change/two") } },
  steps = {}, review_jobs = {}, deploy = {}, todos = {} } }
local off_ok, off_result = land.impl.review(off_run, {})
land.review_engine = real_engine
eq(off_ok, true, "the review step never stops a landing")
eq(off_result.state, "skipped", "the review step is skipped, never silently done")
contains(off_result.detail, "reviewer off", "the skip names the switch")
contains(off_result.detail, "off", "and the value it read")
eq(review_started(), 0, "no review was started while the switch says off")
eq(#(off_run.journal.review_jobs or {}), 0, "and no job is recorded")

-- 13c. A reviewer that cannot run: "review unavailable: <reason>", never a silent skip and never a stop. The
-- landing is a real one on the repository case 13 left (change/two is still unmerged), because "never blocking"
-- is a statement about a landing and not about a step.
review_start("fail")
review_forget()
local failed_code = land.run({ run = "case13c", signer = "local", ring = SOLO_RING, branches = { "change/two" },
  no_deploy = true, checks = standard_checks() })
eq(failed_code, 0, "a reviewer failure does not stop the landing")
local failed = journal_of("case13c")
eq(#(failed.review or {}), 1, "the branch still has a row: a failure is evidence, not a silence")
contains(failed.review[1].unavailable, "review unavailable:", "the failure is named as unavailable")
contains(failed.review[1].unavailable, "exited 3", "with the exit the reviewer failed with")
contains(failed.review[1].unavailable, "the model route is missing", "and the reviewer's own words")
contains(step_of("case13c", "review").detail, "review unavailable:", "the step says the same thing")
eq(step_of("case13c", "review").state, "done", "recorded as a step that ran, not as a silent skip")
eq(failed.result, "done", "and the landing is done")
contains(read_file(land.report_path("case13c")) or "", "review unavailable:", "the report carries it")
advance_main(failed.tree_commit)

-- 13d. The join itself, without a landing: an answer about another commit is not this branch's review, and a
-- review nobody waited for is reported by name. Both are rows; neither is a stop.
-- A pid that is certainly alive: this row's own process, which is what a review still running looks like.
local process_id = (function()
  local decoded_ok, value = pcall(json.decode, host.runtime_info())
  if decoded_ok and type(value) == "table" then return value.process_id end
  return nil
end)()
local function collect_case(name, answer, exit_code, live)
  local stem = review_home .. "/collect-" .. name
  if answer then write_file(stem .. ".json", json.encode(answer) .. "\n")
  else must("rm -f " .. stem .. ".json", "clear a collected answer") end
  if exit_code then write_file(stem .. ".code", tostring(exit_code) .. "\n") end
  local journal_row = { run = "collect-" .. name, result = "done", deploy = {}, todos = {}, branches = {},
    steps = { review = { name = "review", state = "started", started_at = math.floor(host.now()) } },
    review_jobs = { { branch = "change/x", sha = string.rep("a", 40), base = "base", json = stem .. ".json",
      code_path = stem .. ".code", log = stem .. ".log", started_at = math.floor(host.now()),
      pid = live and process_id or 999999 } } }
  local saved = land.REVIEW_WAIT
  land.REVIEW_WAIT = 0
  land.review_collect({ id = "collect-" .. name, journal = journal_row })
  land.REVIEW_WAIT = saved
  return journal_row.review[1]
end
local other = collect_case("other", { schema = "harness-evaluator/review/answer/1", ok = true, state = "reviewed",
  review_id = "fake-003", findings = 1, sha = string.rep("b", 40), answer = "about another commit" })
eq(other.state, "reviewed", "the answer was a review")
contains(other.unavailable, "review unavailable:", "but it is not this branch's review")
contains(other.unavailable, "answered about bbbbbbbbbbbb", "and it says which commit it answered about")
local running = collect_case("running", nil, nil, true)
eq(running.state, "running", "a review nobody waited for is recorded as running")
contains(running.unavailable, "still running after 0s", "by its own words, not as \"no findings\"")
contains(running.unavailable, "wa eval reviewer list", "and it says where its record will arrive")
local gone = collect_case("gone", nil, nil, false)
eq(gone.state, "unavailable", "a review process that is gone without an answer is unavailable")
contains(gone.unavailable, "gone without an answer", "and says exactly that")

-- ---------------------------------------------------------------- case 14: a shipped ref that names a file it does not carry
-- The 13/11 defect, on purpose: PUBLISH.sh names SHA256SUMS and the commit does not hold it.
behaviour.omit_sums = true
local broken_code = land.run({ run = "case14", signer = "local", ring = SOLO_RING, branches = { "change/artifacts" }, checks = standard_checks() })
behaviour.omit_sums = false
eq(broken_code, 1, "an incomplete artifacts reference stops the landing")
eq(step_of("case14", "ship").state, "failed", "the ship step failed")
eq(step_of("case14", "ship").error, "ship_incomplete", "the refusal is named")
contains(step_of("case14", "ship").observed, "SHA256SUMS", "the refusal names the file the reference does not carry")

-- ---------------------------------------------------------------- case 15: the ready box
-- A fresh repository: case 14 pushed main before it failed at the ship, so reusing that history would land the
-- same commit again and the ref for it (the incomplete one case 14 made) would be the one under test.

R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
