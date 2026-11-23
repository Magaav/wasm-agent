-- `wa land` -- THE 19/11 CASES: a bare --resume finds the stopped run, the land<N> number is the remote's,
-- --account moves main on the named node, and a release that already exists is not a stop.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-resume-19-11.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-resume-19-11.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local json, land, fixture, repo, incoming, origin, ok, eq, contains, must, write_file = R.json, R.land, R.fixture, R.repo, R.incoming, R.origin, R.ok, R.eq, R.contains, R.must, R.write_file
local setup_fixture, observed, behaviour, journal_of, step_of, SOLO_RING, standard_checks = R.setup_fixture, R.observed, R.behaviour, R.journal_of, R.step_of, R.SOLO_RING, R.standard_checks

R.start_vault()

local function resume_19_11_cases()
  -- THE 19/11 CASES LIVE IN THEIR OWN FUNCTION. Lua allows 200 locals per function and this row was
  -- already at the limit; the cases share the outer fixtures as upvalues and add no register to the
  -- function that runs the whole row.
-- ---------------------------------------------------------------- case 24: a bare --resume finds the run
-- `wa land --resume` with no run named continues the newest unfinished run. It did not: the listing was
-- `ls -1dt '<root>'/*/journal.json`, and a glob inside quotes is never expanded, so the answer was always
-- "nothing to resume" with a stopped run sitting in the directory (item 24).
setup_fixture()
land.candidates = function() return {} end
write_file(fixture .. "/land-gate/gate-red.sh", "#!/usr/bin/env bash\nexit 1\n")
must("chmod +x " .. fixture .. "/land-gate/gate-red.sh", "the red gate runs")
local red_checks = function()
  return { { name = "fast", command = "bash " .. fixture .. "/land-gate/gate-red.sh", timeout = 60 } }
end
local stopped_code = land.run({ run = "case24", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = red_checks() })
eq(stopped_code, 1, "the red gate stops the round")
eq(journal_of("case24").result, "stopped", "and the run is recorded stopped")
local resumed_code = land.run({ resume = true, checks = standard_checks() })
eq(resumed_code, 0, "a bare --resume continues the stopped run and finishes it")
eq(journal_of("case24").result, "done", "the run it continued is the one on disk")
contains(step_of("case24", "gate").detail or "", "passed", "the gate of the continued run is the green one")

-- ---------------------------------------------------------------- case 25: the landing branch is free
-- A landing leaves `land<N>/final` on the incoming repository. A second landing that picks the same N pushes
-- on top of another round's ref, and the push step reads that ref back expecting its own commit (item 25).
setup_fixture()
must("git -C " .. repo .. " push -q oc-in main:refs/heads/land7/final", "another round already used land7")
local number_code = land.run({ run = "case25", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(number_code, 0, "a round lands while land7/final is on the incoming remote")
eq(journal_of("case25").land_branch, "land8/final", "the number is taken from the remote too, never reused")

-- ---------------------------------------------------------------- case 26: main and publish on a named node
-- The GitHub credential is on ONE node; --account names it, and the push and the release are done there
-- (`gh auth status` is what proves the credential, not `command -v gh`).
setup_fixture()
land.candidates = function() return {} end
R.state.routed_calls = {}
behaviour.gh_authed = true
behaviour.gh_present = true
local account_code = land.run({ run = "case26", signer = "local", ring = SOLO_RING, account = "laptop", branches = { "change/one" }, checks = standard_checks() })
eq(account_code, 0, "a round with --account lands")
local account_journal = journal_of("case26")
eq(account_journal.main_account, "laptop", "main was fast-forwarded on the named node")
-- MAIN NOW CARRIES ONE MORE COMMIT THAN THE LANDING (Fable 22/11): the public channel's index entry is a commit
-- on main (`impl.linux`). What the account node did is the fast-forward of the LANDED TIP, and that is read from
-- the remote's own history - the tightening, not a loosening, of "the source of truth is at the landed tip".
local account_main = (must("git -C " .. repo .. " ls-remote origin refs/heads/main"):match("^(%x+)"))
eq(must("git -C " .. repo .. " rev-parse " .. account_main .. "~1"), account_journal.tree_commit,
  "the source of truth carries the landed tip under the channel's one commit")
eq(must("git -C " .. repo .. " diff --name-only " .. account_journal.tree_commit .. " " .. account_main),
  "releases/index-linux.json", "whose only path is the channel index")
local routed_main = false
for _, call in ipairs(R.state.routed_calls or {}) do
  if call.node == "laptop" and call.kind == "main" then routed_main = true end
end
ok(routed_main, "and the fast-forward of main ran on the node that holds the credential")
local main_on_node, publish_on_node = false, false
for _, call in ipairs(R.state.routed_calls) do
  if call.node == "laptop" and call.kind == "main" then main_on_node = true end
  if call.node == "laptop" and call.kind == "publish" then publish_on_node = true end
end
ok(main_on_node, "the main push ran on laptop, not here")
ok(publish_on_node, "the release was created on laptop")
eq(account_journal.publish.account, "laptop", "the journal names the account that published")
-- A `gh` that exists but is not signed in is not a credential.
setup_fixture()
R.state.routed_calls = {}
behaviour.gh_authed = false
local noauth_code = land.run({ run = "case26b", signer = "local", ring = SOLO_RING, account = "laptop", branches = { "change/one" }, checks = standard_checks() })
eq(noauth_code, 1, "a signed-out gh stops the publish")
eq(step_of("case26b", "publish").error, "publish_needs_credentials", "the refusal is named")
contains(step_of("case26b", "publish").observed or "", "laptop", "and it names the node whose gh is not signed in")
local published_anyway = false
for _, call in ipairs(R.state.routed_calls) do if call.kind == "publish" then published_anyway = true end end
ok(not published_anyway, "nothing was published by a node that is not signed in")
behaviour.gh_authed = true

-- ---------------------------------------------------------------- case 27: mark a step done out of band

-- THE RESUME THE BRIEF IS ABOUT (21/11, hand fix 5). The release already exists on GitHub - published by an
-- operator, or by an earlier attempt that died after the release was created - and this process still cannot
-- run gh. It must be RECORDED as published, not stopped at the credential gate for ever.
setup_fixture()
behaviour.release_present = true
local resume_exec = land.exec
land.exec = function(command, cwd, timeout)
  if command:match("^command %-v gh") then return { code = 0, stdout = "no\n", stderr = "" } end
  return resume_exec(command, cwd, timeout)
end
local resumed = land.run({ run = "case27b", signer = "local", ring = SOLO_RING, branches = { "change/one" }, checks = standard_checks() })
eq(resumed, 0, "a round whose release already exists is not stopped by a gh that cannot run here")
local resumed_publish = step_of("case27b", "publish")
eq(resumed_publish.state, "done", "the publish step is done")
eq(journal_of("case27b").publish and journal_of("case27b").publish.state, "already_present",
  "and it records that the release was already there, rather than claiming to have published it")
land.exec = resume_exec
behaviour.release_present = true

-- A release created by hand must reach the journal by a VERB that re-verifies it, not by editing
-- journal.json. `wa land mark <step> --evidence <file>`: no evidence, no mark; a claim the world does not
-- support, no mark; a verified claim, a mark with `marked` and the evidence path on the step (item 27).
end
resume_19_11_cases()

R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
