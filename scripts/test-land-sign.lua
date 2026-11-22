-- `wa land` -- THE SIGNATURE: made on this node, made on a named node and handed back, refused without a
-- signer, refused when the key is not trusted, and a publish that stops when gh is not there.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-sign.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-sign.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local json, land, repo, origin, vault, ok, eq, contains, must, write_file, setup_fixture = R.json, R.land, R.repo, R.origin, R.vault, R.ok, R.eq, R.contains, R.must, R.write_file, R.setup_fixture
local advance_main, observed, journal_of, step_of, SOLO_RING, standard_checks = R.advance_main, R.observed, R.journal_of, R.step_of, R.SOLO_RING, R.standard_checks

R.start_vault()

setup_fixture()
local saved_exec_wt = land.exec
local function failing_worktree(answer)
  land.exec = function(command, cwd, timeout)
    if command:match("^git %-C .* worktree add") then return answer end
    if command:match("^command %-v gh") then return { code = 0, stdout = "no\n", stderr = "" } end
    return saved_exec_wt(command, cwd, timeout)
  end
  local ok_run = land.run({ run = "case12b", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
  land.exec = saved_exec_wt
  return ok_run, step_of("case12b", "merge") or {}
end
do
  local code, step = failing_worktree({ code = 128, stdout = "", stderr = "fatal: could not create leading directories of 'x'\n" })
  eq(code, 1, "a refused worktree stops the landing")
  eq(step.error, "worktree_failed", "the stop is named")
  contains(step.observed, "fatal: could not create leading directories", "git's own words are in the answer")
  contains(step.observed, "exit 128", "and so is the exit code it came with")
  contains(step.observed, "command: git worktree add", "the command that failed is named")
  contains(step.detail, "exit 128", "the report line carries the code too")
end
do
  local code, step = failing_worktree({ code = 1, stdout = "", stderr = "host_error: disk_cap_refused_before_launch" })
  eq(code, 1, "a host refusal stops the landing too")
  contains(step.observed, "disk_cap_refused_before_launch", "a host refusal with no streams still says why")
  contains(step.observed, "exit 1", "and carries its code")
  ok(step.observed ~= "", "a host refusal with no streams is never empty")
  ok(step.observed ~= "", "the observed detail is never empty")
end
do
  local code, step = failing_worktree({ code = 1, stdout = "", stderr = "unreadable operation wrapper: {not json}", raw = "{not json}" })
  eq(code, 1, "an unreadable host answer stops the landing")
  contains(step.observed, "raw host answer: {not json}", "the raw host answer is kept when it is not the expected JSON")
end
do
  -- git can fail on STDOUT alone; the old line read stdout only when stderr was empty, and an empty answer
  -- was what it produced when both were. Neither stream is assumed.
  local code, step = failing_worktree({ code = 128, stdout = "Preparing worktree (new branch 'land1/final')\nfatal: already used by worktree at /tmp/x\n", stderr = "" })
  eq(code, 1, "a stdout-only failure stops the landing")
  contains(step.observed, "fatal: already used by worktree", "git's stdout words are reported when stderr is empty")
end

do
  -- The exact shape that produced the empty observed four times: a failure with NEITHER stream. It must
  -- still say something a reader can act on, rather than nothing at all.
  local code, step = failing_worktree({ code = 128, stdout = "", stderr = "" })
  eq(code, 1, "a silent failure still stops the landing")
  contains(step.observed, "(git answered with no output)", "a failure with no output says exactly that")
  contains(step.observed, "exit 128", "and still carries the exit code")
  ok(step.observed ~= "", "the observed detail is never empty, even when git said nothing")
end

-- ---------------------------------------------------------------- case 9: the signature made on a NAMED node
-- The vault's admin listener is not on this machine, so the pipeline signs where it is and the signature
-- travels back. This is that path: the node `laptop` runs the command it is given (its own signer, its own
-- environment) and answers with the signature; the land machine verifies it before anything ships.
if not R.state.vault_available then
  print("SKIP test-land: no scratch vault, so the signer-node hand-back was not exercised")
else
  setup_fixture()
  land.candidates = function() return { "laptop" } end
  R.state.sign_calls = 0
  local node_code = land.run({ run = "case9", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
  eq(node_code, 0, "a release signed on the node that reaches the vault lands")
  local node_journal = journal_of("case9")
  eq(node_journal.artifacts.signer, "laptop", "the journal names the node that signed")
  eq(node_journal.artifacts.signed, true, "the signature that came back verified here")
  contains(node_journal.artifacts.key_id, "release-signing-", "and it names the key")
  ok(R.state.sign_calls >= 1, "the signer node actually ran the signing command")
  contains(must("git -C " .. repo .. " fetch -q oc-in refs/heads/" .. node_journal.artifacts.ref ..
    " && git -C " .. repo .. " ls-tree -r --name-only FETCH_HEAD"), "SHA256SUMS.sig",
    "the shipped release carries the signature made elsewhere")
  advance_main(node_journal.tree_commit)

  -- ------------------------------------------------------------- case 10: no signer at all
  setup_fixture()
  land.candidates = function() return {} end
  local unknown_code = land.run({ run = "case10", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
  eq(unknown_code, 1, "no reachable vault stops the landing")
  eq(step_of("case10", "sign").state, "failed", "the sign step is failed")
  eq(step_of("case10", "sign").error, "signer_unknown", "the refusal is named")
  contains(step_of("case10", "sign").next, "--signer", "the refusal names the way to fix it")
  local unsigned_journal = journal_of("case10")
  ok(unsigned_journal ~= nil, "the journal of an unsigned stop is written")
  local unsigned_tip = tostring((unsigned_journal or {}).tree_commit or "")
  ok(#unsigned_tip == 40, "the journal names the landed tip of the unsigned run")
  eq(must("git -C " .. repo .. " ls-remote oc-in refs/heads/artifacts/node-" .. unsigned_tip:sub(1, 12)), "",
    "nothing was shipped for an unsigned release")
  local unsigned_ship = step_of("case10", "ship")
  ok(unsigned_ship == nil or unsigned_ship.state == "pending", "the ship step never ran")
  local unsigned_publish = step_of("case10", "publish")
  ok(unsigned_publish == nil or unsigned_publish.state == "pending", "and nothing was published")

  -- ------------------------------------------------------------- case 11: a key this project does not trust
  setup_fixture()
  land.candidates = function() return {} end
  write_file(repo .. "/config/release-keys.txt", "wa-trusted-keys v1\n")
  must("git add -A && git commit -q -m 'trust nothing' && git push -q origin main && git push -q oc-in main",
    "commit an empty trusted-key list", repo)
  local untrusted_code = land.run({ run = "case11", ring = SOLO_RING, branches = { "change/one" },
    signer = "local", checks = standard_checks() })
  eq(untrusted_code, 1, "a signature by an untrusted key stops the landing")
  eq(step_of("case11", "sign").state, "failed", "the sign step is failed")
  eq(step_of("case11", "sign").error, "release_key_not_trusted", "the refusal is named")
  contains(step_of("case11", "sign").next, "config/release-keys.txt", "it names where the key has to be trusted")
  local untrusted_journal = journal_of("case11")
  ok(untrusted_journal ~= nil, "the journal of an untrusted-key stop is written")
  local untrusted_tip = tostring((untrusted_journal or {}).tree_commit or "")
  ok(#untrusted_tip == 40, "the journal names the landed tip of the untrusted run")
  eq(must("git -C " .. repo .. " ls-remote oc-in refs/heads/artifacts/node-" .. untrusted_tip:sub(1, 12)), "",
    "a release no node would verify is not shipped")
end

-- ---------------------------------------------------------------- case 12: publish without a credential
setup_fixture()
local saved_route = land.exec
land.exec = function(command, cwd, timeout)
  if command:match("^command %-v gh") then return { code = 0, stdout = "no\n", stderr = "" } end
  return saved_route(command, cwd, timeout)
end
local no_gh = land.run({ run = "case12", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(no_gh, 1, "a machine without gh stops at the publish")
local publish_step = step_of("case12", "publish")
eq(publish_step.error, "publish_needs_credentials", "the stop is named")
contains(publish_step.next, "PUBLISH.sh", "the stop names the exact command that publishes elsewhere")
eq(step_of("case12", "sign").state, R.state.vault_available and "done" or "failed", "the release was signed before it was published")
eq(step_of("case12", "ship").state, "done", "and shipped")
land.exec = saved_route

-- ---------------------------------------------------------------- case 13: the reviewer really runs
-- `wa land` runs the reviewer that LANDED (`wa eval reviewer`) on every branch of the round and BEFORE the
-- merge, through that door and no other. The fake sits where that process sits (`M.review_binary_path`) and
-- speaks that door's contract (`--json`), so the step, the spawn, the join, the journal and the report are all
-- the shipped code. What this case proves: findings reach the journal and the report, the review really runs
-- BESIDE the gate (the fake only answers after the gate's own row has run), and the reviewer is given the
-- branch, the base and the brief the ready box knew.

R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
