-- `wa land` -- THE PUBLIC LINUX CHANNEL: the `linux` step of a release (`wa release cut`).
--
-- WHY THIS ROW EXISTS (Fable, 22/11). `wa release cut` published `node-<sha12>` releases and nothing else, so
-- `releases/index-linux.json` - the channel a machine with NO node installs from (`scripts/install.sh` ->
-- `scripts/linux/bootstrap.sh`) - was never written by a cut. Measured 22/11: six node releases cut in one day,
-- the channel's newest x86_64 entry 23 days old (`v0.1.0-alpha.13` at `d80d86bd`, 30/10), and the fresh-install
-- proof died with `core_lib_unreachable`. The lag was silent, which is why the step is a step: it has a name,
-- its own verdict, and its own refusals.
--
-- WHAT IT PROVES HERE: the step's place and order, the plan's skips, and the step itself through the REAL
-- `impl.linux` against the fixture's channel publisher (`scripts/lib/land-row.lua` CHANNEL_SCRIPT) and the REAL
-- freshness check - published, one commit on main carrying exactly one path, the live channel naming the
-- release, a rerun that publishes nothing twice, and the five refusals by name with main untouched each time.
-- The publisher's own build/sign/upload chain (and the fake GitHub it needs) is scripts/test-linux-channel.sh;
-- the real bundles are built by the next real cut, which is Fable's to run.
--
--   WA_SCRIPT=scripts/test-land-linux.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-linux.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local land, repo, ok, eq, contains, must, setup_fixture = R.land, R.repo, R.ok, R.eq, R.contains, R.must, R.setup_fixture
local observed, behaviour, journal_of, step_of = R.observed, R.behaviour, R.journal_of, R.step_of

R.start_vault()

local function origin_main() return (must("git -C " .. repo .. " ls-remote origin refs/heads/main"):match("^(%x+)")) end
local function head() return must("git -C " .. repo .. " rev-parse HEAD") end
local function live_channel(sha) return must("git -C " .. repo .. " show " .. sha .. ":releases/index-linux.json") end

-- ---------------------------------------------------------------- the step's place, and its name
local position = {}
for index, name in ipairs(land.STEPS) do position[name] = index end
eq(position.linux, (position.publish or 0) + 1, "the channel step comes right after publish")
eq(position.linux, (position.deploy or 0) - 1, "and right before the deploy: the ring rollout stays last")
ok(position.publish ~= nil and position.deploy ~= nil, "both neighbours exist")
eq(land.EVENT_STEP.linux, "linux-channel", "its ledger row has a name of its own")
eq(land.linux_tag("0123456789abcdef0123456789abcdef01234567"), "wa-linux-0123456789ab",
  "the channel tag is wa-linux-<sha12>: one release per commit, and never the node-<sha12> release")
eq(land.LINUX_INDEX, "releases/index-linux.json", "the step writes the index the installer reads")

-- ---------------------------------------------------------------- the step itself
--
-- Each group starts from a fresh fixture repository, because the step publishes a COMMIT: a case that ran after a
-- successful publish would find the channel already naming it and (correctly) do nothing, which proves nothing.
local function fresh_fixture()
  setup_fixture()
  land.candidates = function() return {} end
  behaviour.gh_authed, behaviour.gh_present = true, true
  behaviour.channel_fails, behaviour.channel_wrong_commit = "", ""
end

-- <id> [artifacts] -> a run shaped the way the step receives one: the release's tree, its commit, its signed
-- artefacts (from the `sign` step) and a directory for the channel.
local function channel_run(id, artifacts)
  local dir = land.run_dir(id)
  must("mkdir -p " .. dir .. "/evidence", "the run's evidence directory")
  local sha = head()
  return { id = id, tree = repo, journal = { run = id, release = true, tree = repo, tree_commit = sha,
    release_dir = dir .. "/release",
    artifacts = artifacts or { signed = true, dir = dir .. "/release" } } }
end

local function refusal(id, options, expected, artifacts)
  local main_before = origin_main()
  local candidate = channel_run(id, artifacts)
  local step_passed, step_result = land.impl.linux(candidate, options or { signer = "local" })
  eq(step_passed, false, expected .. ": the step fails")
  eq((step_result or {}).error, expected, "and the failure is named " .. expected)
  eq(origin_main(), main_before, expected .. ": and main is untouched")
  return step_result
end

-- -------- no signed node release, no channel entry: the entry would name bytes this machine would not ship
fresh_fixture()
local unsigned = refusal("linuxE", { signer = "local" }, "linux_unsigned_release", { signed = false, dir = "/nonexistent" })
contains(tostring((unsigned or {}).next), "--resume", "and says how to continue")

-- -------- a triple this channel does not publish is refused before anything is built (the allow-list)
fresh_fixture()
local bad_target = refusal("linuxF", { signer = "local", linux_targets = "riscv64gc-unknown-linux-musl" }, "linux_target_unknown")
contains(tostring((bad_target or {}).observed), "riscv64gc-unknown-linux-musl", "and names the triple it refused")

-- -------- the publisher's own refusal is the step's refusal, by name, and main is untouched
fresh_fixture()
behaviour.channel_fails = "build"
local build_failure = refusal("linuxB", { signer = "local" }, "linux_channel_build_failed")
contains(tostring((build_failure or {}).observed), "build_failed", "the publisher's own words are the observation")
contains(tostring((build_failure or {}).next), "--resume", "and the answer says how to continue")
contains(tostring((build_failure or {}).detail), "unaffected", "and says the node release is not affected")
fresh_fixture()
behaviour.channel_fails = "stale"
local stale = refusal("linuxC", { signer = "local" }, "linux_channel_index_stale")
contains(tostring((stale or {}).observed), "index_stale", "the stale channel is the publisher's word, carried up")

-- -------- the publisher answers done but names another commit: the read-back catches it, nothing is committed
fresh_fixture()
-- a commit that is NOT this release's (the fixture's HEAD is its own root commit, so a branch tip is used)
behaviour.channel_wrong_commit = must("git -C " .. repo .. " rev-parse change/one")
refusal("linuxD", { signer = "local" }, "linux_index_incomplete")

-- -------- published: one commit on main, one path, and the live channel names the release
fresh_fixture()
local release_sha = head()
local before = origin_main()
local run = channel_run("linuxA")
local passed, result = land.impl.linux(run, { signer = "local" })
eq(passed, true, "the step publishes the channel (" .. tostring((not passed) and (result and result.observed or result)) .. ")")
contains(tostring((result or {}).detail), "wa-linux-", "its answer names the channel tag")
contains(tostring((result or {}).detail), "fresh", "and the live verdict the check gave")
local after = origin_main()
ok(after ~= before, "main moved")
eq(must("git -C " .. repo .. " rev-parse " .. after .. "^1"), release_sha, "by exactly one commit, on top of the release")
eq(must("git -C " .. repo .. " diff --name-only " .. release_sha .. " " .. after), "releases/index-linux.json",
  "and that commit carries exactly one path (the allow-list, not a hope)")
contains(live_channel(after), release_sha, "the live index names this release's commit")
eq((run.journal.linux or {}).state, "published", "the journal records the publish")
eq((run.journal.linux or {}).tag, land.linux_tag(release_sha), "with the tag")
eq(#((run.journal.linux or {}).targets or {}), 2, "for both targets")
eq((run.journal.linux or {}).index_commit, after, "and the commit that carries it")
contains(tostring((run.journal.linux or {}).live), "fresh", "the freshness verdict is kept in the journal")
eq(observed.channel_pushes, 1, "the index commit was pushed onto main once")

-- -------- a second run of the same step publishes nothing twice
local again_before = origin_main()
local again = channel_run("linuxA2")
local again_passed, again_result = land.impl.linux(again, { signer = "local" })
eq(again_passed, true, "a rerun of the step is green")
contains(tostring((again_result or {}).detail), "already names", "because the channel already names this commit")
eq(origin_main(), again_before, "and main did not move again")
eq((again.journal.linux or {}).state, "already_present", "the journal says it was already published")

-- -------- the routed signer: the bundle is built here and the SUMS ARE SIGNED ON THE NODE (the same helper the
-- `sign` step uses), so a cut with `--signer <node>` still publishes the channel.
fresh_fixture()
local routed_sha = head()
local sign_calls_before = R.state.sign_calls
local routed = channel_run("linuxG")
local routed_passed, routed_result = land.impl.linux(routed, { signer = "laptop" })
eq(routed_passed, true, "a run that signs on another node publishes the channel too (" ..
  tostring((not routed_passed) and (routed_result and routed_result.observed or routed_result)) .. ")")
eq(R.state.sign_calls, sign_calls_before + 1, "and the sums were signed on that node, once")
contains(tostring((routed_result or {}).detail), "wa-linux-", "its answer names the channel tag as well")
contains(live_channel(origin_main()), routed_sha, "the live index names the release")

R.stop_vault()
print(string.format("land-linux ok (%d checks)", R.count()))
