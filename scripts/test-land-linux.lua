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
-- The by-hand case (23/11) writes a SCRATCH journal and reads it back: the names it needs are the harness's.
local read_file, write_file, json = R.read_file, R.write_file, R.json

-- ---------------------------------------------------------------- the step's place, and its name
local position = {}
for index, name in ipairs(land.STEPS) do position[name] = index end
-- AFTER THE RING (Fable, 23/11, measured): a node deploys a commit only while HEAD == origin/main == that commit,
-- and this step moves main, so publishing the channel first would refuse every tree deploy of the release.
eq(position.linux, (position.deploy or 0) + 1, "the channel step comes right after the deploy")
eq(position.linux, (position.report or 0) - 1, "and the report is still last")
ok(position.publish ~= nil and position.deploy ~= nil, "both neighbours exist")
eq(land.EVENT_STEP.linux, "linux-channel", "its ledger row has a name of its own")
eq(land.version_tag("0.1.0"), "v0.1.0", "the channel tag IS the product version (Victor, 22/11)")
eq(land.version_tag("v0.1.7"), "v0.1.7", "a version that already carries its v is not doubled")
eq(land.parse_product_version("0.1.0") and land.format_product_version(land.parse_product_version("0.1.0")), "0.1.0",
  "the number is parsed and formatted by one pair of functions")
eq(land.parse_product_version("1.0"), nil, "a version this does not understand is refused, never bumped by accident")
eq(land.LINUX_INDEX, "releases/index-linux.json", "the step writes the index the installer reads")

-- ---------------------------------------------------------------- the precondition (first second, Fable 23/11)
--
-- `M.release_checks.version` decides whether the number main carries has ALREADY been released: if it has, the
-- previous release's bump commit never landed, and a cut now would publish bytes under a tag nobody chose. It is
-- a precondition, so it refuses before any artifact is built, the node release included.
setup_fixture()
land.candidates = function() return {} end
local version_row = land.release_checks.version({})
eq(version_row.ready, true, "main's number (0.1.0) has no release yet")
contains(tostring(version_row.why), "0.1.0", "the row says which number it read")
must("git -C " .. repo .. " tag -f v0.1.0 HEAD", "the tag the first release would create")
local released_row = land.release_checks.version({})
eq(released_row.ready, false, "a number whose tag already exists is not ready")
eq(released_row.error, "version_already_released", "and the refusal is named version_already_released")
contains(tostring(released_row.why), "v0.1.0", "naming the tag that is taken")
contains(tostring(released_row.next), "NEXT number", "and the fix: the constant must name the next release")
-- and the same fact on the remote, where `gh release create` puts the tag
must("git -C " .. repo .. " tag -d v0.1.0", "clear the local tag")
must("git -C " .. repo .. " push -q origin HEAD:refs/tags/v0.1.0", "the same tag on the fixture's origin")
eq(land.release_checks.version({}).error, "version_already_released", "a tag on the remote counts as released too")
must("git -C " .. repo .. " push -q origin :refs/tags/v0.1.0", "clean the remote tag")
eq(land.release_checks.version({}).ready, true, "and with neither tag the number is releasable again")
-- A RESUME carries the commit it is releasing: a tag naming THAT commit is this run's own (Fable, round 3).
must("git -C " .. repo .. " tag -f v0.1.0 HEAD", "a tag this run made")
eq(land.release_checks.version({}, { tree_commit = must("git -C " .. repo .. " rev-parse HEAD") }).ready, true,
  "the same tag is not a refusal when the journal says this run is releasing that commit")
-- the fixture's HEAD is its own root commit, so ANOTHER commit is taken from a branch tip
eq(land.release_checks.version({}, { tree_commit = must("git -C " .. repo .. " rev-parse change/one") }).ready, false,
  "but a tag naming ANOTHER commit still is")
must("git -C " .. repo .. " tag -d v0.1.0", "clear it again")
-- an unquoted minor bump is refused in the preflight as well as in the step
local minor_row = land.release_checks.version({ minor = true })
eq(minor_row.ready, false, "--minor without the quote is not ready")
eq(minor_row.error, "release_bump_not_authorised", "named in the preflight too")
contains(tostring(minor_row.next), "quote Victor", "with the one thing that authorises it")

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
contains(tostring((result or {}).detail), "published v0.1.0", "its answer names the release it published")
contains(tostring((result or {}).detail), "fresh", "and the live verdict the check gave")
local after = origin_main()
ok(after ~= before, "main moved")
eq(must("git -C " .. repo .. " rev-parse " .. after .. "^1"), release_sha, "by exactly one commit, on top of the release")
eq(must("git -C " .. repo .. " diff --name-only " .. release_sha .. " " .. after), "lua/core/build_identity.lua\nreleases/index-linux.json",
  "and that commit carries exactly its two allow-listed paths (the allow-list, not a hope)")
contains(live_channel(after), release_sha, "the live index names this release's commit")
eq((run.journal.linux or {}).state, "published", "the journal records the publish")
eq((run.journal.linux or {}).tag, "v0.1.0", "with the first release's version as the tag")
eq((run.journal.linux or {}).version, "0.1.0", "and the version itself, from the one owner in this tree")
eq((run.journal.linux or {}).next_version, "0.1.1", "while main is left carrying 0.1.1 for the next cut")
eq(#((run.journal.linux or {}).targets or {}), 2, "for both targets")
eq((run.journal.linux or {}).index_commit, after, "and the commit that carries it")
contains(tostring((run.journal.linux or {}).live), "fresh", "the freshness verdict is kept in the journal")
eq(observed.channel_pushes, 1, "the index commit was pushed onto main once")

-- -------- TWO RELEASES IN A ROW (Victor, 22/11): 0.1.0, then 0.1.1 - in VERSION, in the tag, in the index,
-- and in the header line the version renders.
local view = dofile("lua/core/cli_view.lua")
local function header(product) return (view.banner({ product = product, version = "abc12345", workspace = "~/work" }):gsub("\n", " | ")) end
contains(header("0.1.0"), "Welcome to wasm-agent! v0.1.0 \194\183 vabc12345", "the welcome line shows the version and the sha")
-- The first cut's tag exists on the remote now (gh creates it), which is what makes the next number the next one.
must("git -C " .. repo .. " tag -f v0.1.0 " .. release_sha, "the release tag gh created for the first cut")
must("git -C " .. repo .. " push -q origin refs/tags/v0.1.0", "push that tag to the fixture's origin")
-- THE DEFECT Fable found (23/11): the released bytes must say the number they are released as. The bundles are
-- built from the RELEASED commit, whose constant is therefore the tag - and main, one commit later, carries the
-- BUMP for the next cut. Both facts are read from git here, which is what `build.rs` embeds at build time.
contains(must("git -C " .. repo .. " show " .. release_sha .. ":lua/core/build_identity.lua"),
  'M.PRODUCT_VERSION = "0.1.0"', "the RELEASED commit's one owner says 0.1.0 - the number its bytes print")
contains(must("git -C " .. repo .. " show origin/main:lua/core/build_identity.lua"), 'M.PRODUCT_VERSION = "0.1.1"',
  "and main, one commit past it, already carries the BUMP for the next cut")
must("git -C " .. repo .. " fetch -q origin main", "read main back")
must("git -C " .. repo .. " reset -q --hard origin/main", "the next cut is made from the main the first one left")
local second_run = channel_run("linuxH")
local second_passed, second_result = land.impl.linux(second_run, { signer = "local" })
eq(second_passed, true, "the second release publishes too (" ..
  tostring((not second_passed) and (second_result and second_result.observed or second_result)) .. ")")
eq((second_run.journal.linux or {}).version, "0.1.1", "and the tree's own number - the bump the first cut wrote - is 0.1.1")
eq((second_run.journal.linux or {}).tag, "v0.1.1", "with v0.1.1 as the tag")
local second_sha = tostring((second_run.journal.linux or {}).index_base or "")
contains(must("git -C " .. repo .. " rev-parse " .. (second_run.journal.tree_commit or head())), "", "")
contains(must("git -C " .. repo .. " show " .. tostring(second_run.journal.tree_commit) .. ":lua/core/build_identity.lua"),
  'M.PRODUCT_VERSION = "0.1.1"', "the released bytes of the second cut say 0.1.1 too")
eq((second_run.journal.linux or {}).next_version, "0.1.2", "and main is left carrying 0.1.2 for the third")
contains(must("git -C " .. repo .. " show origin/main:lua/core/build_identity.lua"), 'M.PRODUCT_VERSION = "0.1.2"',
    "and the one owner on main says 0.1.2 - the bump this release wrote")
contains(live_channel(origin_main()), "\"tag\": \"v0.1.1\"", "the live index names v0.1.1")
contains(header("0.1.1"), "Welcome to wasm-agent! v0.1.1", "and a build of it would show v0.1.1 in the header")
-- A minor/major bump is Victor's word, quoted, or it does not happen - in both directions.
fresh_fixture()
local before_bump = origin_main()
local bumped = channel_run("linuxI")
local bumped_passed, bumped_result = land.impl.linux(bumped, { signer = "local", minor = true })
eq(bumped_passed, false, "--minor without Victor's quoted instruction is refused")
eq((bumped_result or {}).error, "linux_bump_not_authorised", "by name")
contains(tostring((bumped_result or {}).observed), "bump_not_authorised", "and the answer says what is missing")
contains(tostring((bumped_result or {}).next), "quote Victor", "and how to fix it: his words, quoted, in the notes")
eq(origin_main(), before_bump, "main is untouched")
-- ... and WITH his quoted instruction the same flag is allowed: 0.1.0 -> 0.2.0.
must("git -C " .. repo .. " -c user.email=f@example.com -c user.name=Fixture commit -q --allow-empty -m 'notes: the minor instruction'", "a commit to read the notes from")
R.write_file(repo .. "/docs/release/RELEASE_NOTES.md",
  "# Release notes\n\nVictor: \"0.2.0 is a minor release: the channel and the node have separate lives now.\"\n")
must("git -C " .. repo .. " add -A && git -C " .. repo .. " -c user.email=f@example.com -c user.name=Fixture commit -q -m 'notes: quote Victor'", "commit the quoted instruction")
local allowed = channel_run("linuxJ")
local allowed_passed, allowed_result = land.impl.linux(allowed, { signer = "local", minor = true })
eq(allowed_passed, true, "with the quoted instruction the minor bump is allowed (" ..
  tostring((not allowed_passed) and (allowed_result and allowed_result.observed or allowed_result)) .. ")")
-- A minor is decided ONE RELEASE AHEAD (Fable, 23/11): the release published is still the tree's number, and the
-- BUMP it leaves on main is the minor step - so the next cut is 0.2.0.
eq((allowed.journal.linux or {}).version, "0.1.0", "the release published is still the tree's own number")
eq((allowed.journal.linux or {}).tag, "v0.1.0", "under the tag v0.1.0")
eq((allowed.journal.linux or {}).next_version, "0.2.0", "and the bump it writes is the minor step: the next cut is 0.2.0")

-- -------- D (Fable, round 3): a RESUME of a release whose index push failed must not answer
-- `version_already_released` for ever. The publisher creates the tag (`gh release create`) and the index commit is
-- pushed afterwards, so between those two the tag exists and belongs to this very run.
fresh_fixture()
local resume_sha = head()
local resume_before = origin_main()
local run_k = channel_run("linuxK")
-- the push fails once, as a refused push does in the field
local saved_exec = land.exec
local refused_once = false
land.exec = function(command, cwd, timeout)
  if not refused_once and command:find("linux%-channel/index%-tree", 1) and command:find(" push ", 1, true) then
    refused_once = true
    return { code = 1, stdout = "", stderr = "fatal: the remote end hung up unexpectedly\n" }
  end
  return saved_exec(command, cwd, timeout)
end
local first_ok, first_result = land.impl.linux(run_k, { signer = "local" })
land.exec = saved_exec
eq(first_ok, false, "a refused push stops the step")
eq((first_result or {}).error, "linux_index_push_failed", "named linux_index_push_failed")
eq(origin_main(), resume_before, "and the index commit never reached main")
-- the publisher DID create the tag, at THIS release commit: that is the state a resume meets
eq(must("git -C " .. repo .. " rev-parse " .. land.version_tag("0.1.0")), resume_sha,
  "the publisher's tag exists, at this release's commit")
-- ... and the resume must go on (before the fix this answered version_already_released for ever)
local again_k = channel_run("linuxK")
local second_ok, second_result = land.impl.linux(again_k, { signer = "local" })
eq(second_ok, true, "the resume completes (" ..
  tostring((not second_ok) and (second_result and (second_result.error .. ": " .. tostring(second_result.observed)) or second_result)) .. ")")
eq((again_k.journal.linux or {}).state, "published", "and it published")
-- ONE tag, ONE index commit, and the entry written once per target
eq(must("git -C " .. repo .. " tag --list " .. land.version_tag("0.1.0")), land.version_tag("0.1.0"),
  "exactly one tag, and it is the release's")
eq(must("git -C " .. repo .. " rev-parse " .. origin_main() .. "^1"), resume_sha,
  "exactly one index commit, on top of the release")
eq(must("git -C " .. repo .. " diff --name-only " .. resume_sha .. " " .. origin_main()),
  "lua/core/build_identity.lua\nreleases/index-linux.json", "carrying its two allow-listed paths, nothing else")
local resume_entries = 0
for _ in live_channel(origin_main()):gmatch('"commit": "' .. resume_sha .. '"') do resume_entries = resume_entries + 1 end
eq(resume_entries, 2, "the entry is written once per target - no duplicate from the second publish")
-- A FINISHED run resumed says already_present, not a refusal (the tag it made is still there).
local finished = channel_run("linuxK2")
local finished_ok, finished_result = land.impl.linux(finished, { signer = "local" })
eq(finished_ok, true, "a finished run resumes green")
eq((finished.journal.linux or {}).state, "already_present", "and says already_present")
contains(tostring((finished_result or {}).detail), "already names", "with the tag and the commit it found")
eq(origin_main(), must("git -C " .. repo .. " rev-parse " .. origin_main()), "and main did not move again")

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
contains(tostring((routed_result or {}).detail), "published v", "its answer names the release it published as well")
contains(live_channel(origin_main()), routed_sha, "the live index names the release")

-- -------- BY HAND (Fable, 23/11): a channel published OUTSIDE the step is recorded, with who and why.
--
-- Release F's public bundle was published by hand at 09:22Z, so its run has no `done` result and the speed board
-- read "the newest release journal ... is not a finished release" about work that WAS finished. The verb records it
-- - after verifying the effect the step itself verifies (the live channel on origin/main names this commit for
-- every target) - and refuses BY NAME when the hand is unnamed, the reason is missing, or the claim cannot be
-- verified. The subject is a SCRATCH journal written here; no real journal is ever touched.
fresh_fixture()
local hand_sha = head()
must("git -C " .. repo .. " tag node-" .. hand_sha:sub(1, 12), "the node release whose channel was published")
local function publish_index_for(commit)
  local rows = {}
  for _, target in ipairs({ "x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl" }) do
    rows[#rows + 1] = string.format(
      '    {"tag": "v0.1.0", "commit": "%s", "commit_short": "%s", "target": "%s", "arch": "x64", "manifest_sha256": "%s", "url": "https://example.invalid/wa.tar.gz", "size": 1, "node_version": "24.22.1", "built_utc": "2026-11-23T09:22:00Z"}',
      commit, commit:sub(1, 12), target, string.rep("0", 64))
  end
  write_file(repo .. "/releases/index-linux.json",
    '{\n  "schema": "wasm-agent-linux-release-index",\n  "schema_version": 1,\n  "notes": "newest first",\n  "releases": [\n' ..
    table.concat(rows, ",\n") .. '\n  ]\n}\n')
end
publish_index_for(hand_sha)
-- cwd is the FIXTURE repository: a bare `must` runs in the node's own working directory, which is the tree under
-- test (measured 23/11 in this mission: a missing cwd committed the worktree and tried to push it at main).
must("git add -A && git commit -q -m 'releases: linux v0.1.0 (published by hand)' && git push -q origin main",
  "the hand's index commit", repo)
local hand_dir = land.run_dir("release-byhand")
local hand_evidence = hand_dir .. "/evidence/hand.log"
must("mkdir -p '" .. hand_dir .. "/evidence'", "the run's evidence directory")
local function scratch_journal(commit)
  write_file(land.journal_path("release-byhand"), json.encode({ schema = 1, run = "release-byhand", release = true,
    tree = repo, tree_commit = commit, created_at = 1000, updated_at = 1150, steps = {} }))
  return json.decode(read_file(land.journal_path("release-byhand")) or "{}")
end
scratch_journal(hand_sha)
write_file(hand_evidence, "$ gh release upload v0.1.0 wa-linux-x64-musl-....tar.gz\npublished by hand at 09:22Z\n")
local marked, answer = land.mark("release-byhand", "linux", hand_evidence,
  { by_hand = true, who = "Victor", why = "the vault was on the desktop and the cut ran from there", evidence = hand_evidence })
eq(marked, true, "a channel published by hand is recorded (" .. tostring((not marked) and ((answer or {}).error or "") .. ": " .. tostring((answer or {}).observed or "") or "ok") .. ")")
local journal = json.decode(read_file(land.journal_path("release-byhand")) or "{}")
eq(tostring(((journal.linux or {}).by_hand or {}).who), "Victor", "the journal names the hand that did it")
eq(tostring(((journal.linux or {}).by_hand or {}).why), "the vault was on the desktop and the cut ran from there",
  "and the reason it was done by hand")
eq(tostring(((journal.linux or {}).by_hand or {}).commit), hand_sha, "and the commit the live channel names")
eq(tostring(((journal.steps or {}).linux or {}).state), "done", "the step reads done, so a resume does not repeat it")
eq(((journal.steps or {}).linux or {}).marked, true, "and it says it was marked, with its evidence")
-- the refusals, each by name, each leaving the journal unwritten
local function refused_mark(commit, options, expected)
  scratch_journal(commit)
  local passed, why = land.mark("release-byhand", "linux", hand_evidence, options)
  eq(passed, false, expected .. ": the mark is refused")
  eq((why or {}).error, expected, "and named " .. expected)
  eq(json.decode(read_file(land.journal_path("release-byhand")) or "{}").linux, nil, expected .. ": nothing was recorded")
  return why
end
local needs_form = refused_mark(hand_sha, { evidence = hand_evidence, who = "Victor", why = "by hand" }, "mark_by_hand_required")
contains(tostring((needs_form or {}).next), "--by-hand", "and it names the form that records a hand")
refused_mark(hand_sha, { by_hand = true, why = "by hand", evidence = hand_evidence }, "mark_by_hand_needs_who")
refused_mark(hand_sha, { by_hand = true, who = "Victor", evidence = hand_evidence }, "mark_by_hand_needs_why")
local unverified = refused_mark(must("git -C " .. repo .. " rev-parse change/one"),
  { by_hand = true, who = "Victor", why = "by hand", evidence = hand_evidence }, "mark_not_verified")
contains(tostring((unverified or {}).observed), "does not name",
  "an unverifiable claim says which targets the live channel does not name")

R.stop_vault()
print(string.format("land-linux ok (%d checks)", R.count()))
