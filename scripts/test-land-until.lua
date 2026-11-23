-- `wa land` -- --UNTIL AND THE RELEASE LOOP: a landing that stops where it was asked to, and a release cut
-- from main that lands nothing.
--
-- Part of the land row, split out on 22/11 (mission main-green-2, item 2) so that no part of it can
-- hang under the fast path's 120 s watchdog. The harness - the scratch wa-vault, the fixture
-- repository and its two remotes, the scripted node, the fake reviewer's door, the assertion
-- helpers - is scripts/lib/land-row.lua; what was measured, and why each check exists, is in the
-- case comments below.
--
--   WA_SCRIPT=scripts/test-land-until.lua wa --db /tmp/wa-land.db

-- The scratch-home guard every row agrees on: this row writes a repository, a journal and a vault
-- into the home it is given, so it refuses to run on the operator's.
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-land-until.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local land, fixture, repo, origin, journal_root, vault, ok, eq, contains, must, setup_fixture = R.land, R.fixture, R.repo, R.origin, R.journal_root, R.vault, R.ok, R.eq, R.contains, R.must, R.setup_fixture
local observed, behaviour, journal_of, step_of, SOLO_RING, standard_checks = R.observed, R.behaviour, R.journal_of, R.step_of, R.SOLO_RING, R.standard_checks

R.start_vault()

;(function()
  local function origin_main() return (must("git -C " .. repo .. " ls-remote origin refs/heads/main"):match("^(%x+)")) end
  local function captured(run_it)
    local lines, saved = {}, print
    print = function(...)
      local parts = {}
      for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
      lines[#lines + 1] = table.concat(parts, "\t")
    end
    local called, answer = pcall(run_it)
    print = saved
    if not called then error(answer, 0) end
    return answer, table.concat(lines, "\n")
  end
  local real_checks = land.release_checks
  local function ready_checks()
    local asked = {}
    land.release_checks = {
      signing = function() asked.signing = true return { ready = true, why = "stub: the vault answers" } end,
      publishing = function() asked.publishing = true return { ready = true, why = "stub: gh is signed in" } end,
      channel = function() asked.channel = true return { ready = true, why = "stub: the musl toolchain is here" } end,
      ancestry = function() asked.ancestry = true return { ready = true, why = "stub: full history" } end,
    }
    return asked
  end

  -- ------------------------------------------ case 46: a release from main's tip lands nothing
  setup_fixture()
  land.candidates = function() return {} end
  behaviour.gh_authed, behaviour.gh_present, behaviour.release_present, behaviour.publish_fails = true, true, false, false
  local main_before = origin_main()
  local pushes, main_pushes, builds, signs = observed.pushes, observed.main_pushes, observed.builds, observed.signs
  local asked = ready_checks()
  eq(land.run({ run = "case46", release = true, signer = "local", ring = SOLO_RING, no_deploy = true,
    checks = standard_checks() }), 0, "a release of main's tip runs to the end")
  local j46 = journal_of("case46")
  eq(j46.result, "done", "the release run is recorded done")
  eq(j46.release, true, "the journal says it is a release run")
  eq(j46.tree_commit, main_before, "its tree is origin/main's tip, not a merge")
  eq(#(j46.branches or {}), 0, "it collected no branch")
  for _, name in ipairs({ "review", "merge", "push", "main" }) do
    eq(step_of("case46", name).state, "skipped", name .. " is settled as skipped")
    contains(step_of("case46", name).detail, "nothing to land", "and " .. name .. " says why, by name")
  end
  for _, name in ipairs({ "collect", "plan", "gate", "artifacts", "sign", "ship", "publish", "linux", "report" }) do
    local step46 = step_of("case46", name) or {}
    eq(step46.state, "done", "step " .. name .. " ran")
  end
  contains(step_of("case46", "deploy").detail, "--no-deploy", "--no-deploy is honoured")
  eq(j46.plan.full, true, "the plan is the FULL gate, never a narrowed one")
  eq(j46.plan.steps.artifacts.action, "run", "and the node release is built")
  eq(j46.artifacts.commit, main_before, "the release set is main's commit")
  eq(observed.builds, builds + 1, "exactly one build")
  if R.state.vault_available then eq(observed.signs, signs + 1, "exactly one signature") end
  eq(observed.pushes, pushes, "no landing branch was pushed")
  eq(observed.main_pushes, main_pushes, "no landing step pushed main")
  -- THE CHANNEL IS THE ONE COMMIT A RELEASE WRITES (Fable 22/11): a machine with no node installs from
  -- `releases/index-linux.json`, which is read from main, so the entry has to be committed there or the channel
  -- never moves. The assertion used to be "origin/main is where it was"; the true and tighter form is: main
  -- moved by EXACTLY one commit, that commit carries exactly ONE path, and that path names this release.
  eq(observed.channel_pushes, 1, "the channel's index commit was pushed onto main, once")
  local channel_main = origin_main()
  ok(channel_main ~= main_before, "a release now moves main by one commit: the channel index")
  eq(must("git -C " .. repo .. " diff --name-only " .. main_before .. " " .. channel_main, "the channel commit's paths"),
    "releases/index-linux.json", "and that commit carries exactly one path (an allow-list, not a hope)")
  local linux46 = step_of("case46", "linux") or {}
  eq(linux46.state, "done", "the linux step published the channel")
  contains(tostring((journal_of("case46").linux or {}).tag or ""), "v0.1.0",
    "the journal records the release the channel published (v0.1.0, from the tree's VERSION)")
  contains(must("git -C " .. repo .. " show origin/main:releases/index-linux.json", "the live channel index"),
    main_before, "the live index on main names this release's commit")
  eq(must("git -C " .. repo .. " for-each-ref refs/heads/land"), "", "no landing branch exists")
  ok(asked.signing and asked.publishing and asked.channel and asked.ancestry, "every precondition was asked before the run")
  -- The gate verdict is kept by TREE OBJECT - and a release now moves the tree (the channel index is a commit),
  -- so the reuse is proved where main cannot move: two release runs that stop AT the gate, one after the other.
  eq(land.run({ run = "case46b", release = true, until_step = "gate", checks = standard_checks() }), 0,
    "a release run that stops at the gate is green")
  eq(land.run({ run = "case46c", release = true, until_step = "gate", checks = standard_checks() }), 0,
    "a second one on the same main is green too")
  eq(origin_main(), channel_main, "and neither of them moved main (the channel step is after the gate)")
  local row46 = (journal_of("case46c").gate or {})[1]
  eq(row46 and row46.kept, true, "and its gate verdict is KEPT from the first, by tree object")
  eq(row46 and row46.kept_from, "case46b", "naming the run it was kept from")

  -- ------------------------------------------ case 47: the preconditions refuse in the first second
  land.release_checks = {
    signing = function() return { ready = false, error = "release_signing_not_ready", why = "stub: the vault does not answer", next = "FIX-SIGNING" } end,
    publishing = function() return { ready = false, error = "release_publishing_not_ready", why = "stub: gh is signed out", next = "FIX-PUBLISHING" } end,
    ancestry = function() return { ready = true, why = "stub" } end,
  }
  builds = observed.builds
  local code47, text47 = captured(function() return land.run({ run = "case47", release = true, checks = standard_checks() }) end)
  eq(code47, 1, "a release whose preconditions fail is refused")
  contains(text47, "refused(release_signing_not_ready): stub: the vault does not answer", "signing is refused by name")
  contains(text47, "next: FIX-SIGNING", "with the command that fixes it")
  contains(text47, "refused(release_publishing_not_ready)", "publishing is refused by name in the same answer")
  contains(text47, "next: FIX-PUBLISHING", "with its own fix")
  eq(journal_of("case47"), nil, "nothing was written: no journal")
  eq(observed.builds, builds, "and nothing was built")
  local journals_before = must("ls -1 " .. journal_root .. " | wc -l")
  local dry_code, dry_text = captured(function() return land.release_cli({ "release", "cut", "--dry-run" }) end)
  eq(dry_code, 0, "wa release cut --dry-run answers zero even when not ready")
  contains(dry_text, "release: signing: not ready (stub: the vault does not answer)", "the dry run says signing is not ready, and why")
  contains(dry_text, "release: publishing: not ready (stub: gh is signed out)", "and publishing")
  contains(dry_text, "review/merge/push/main skipped", "and prints the plan")
  eq(must("ls -1 " .. journal_root .. " | wc -l"), journals_before, "the dry run wrote no journal")
  eq(land.release_cli({ "release", "trust-key" }), nil, "every other release verb is not this door's")
  local code_b = captured(function() return land.cli({ "land", "--release", "--branches", "change/one" }) end)
  eq(code_b, 2, "a release that names a branch is refused: it lands nothing")
  -- The REAL checks, through the runner seam (the fake gh route, the scratch vault): never GitHub, never the
  -- operator's vault.
  land.release_checks = real_checks
  behaviour.gh_authed = false
  local rows = land.release_preflight({ signer = "local" })
  eq(rows[2].name, "publishing", "the second row is publishing")
  eq(rows[2].ready, false, "a signed-out gh is not ready")
  contains(rows[2].why, "keyring", "and the reason names the keyring")
  contains(rows[2].next, "gh auth login", "and the fix is one command")
  behaviour.gh_authed = true
  rows = land.release_preflight({ signer = "local" })
  eq(rows[2].ready, true, "a signed-in gh is ready")
  if R.state.vault_available then eq(rows[1].ready, true, "the scratch vault answers, so signing is ready") end
  eq(rows[3].name, "channel", "the third row is the public channel's toolchain")
  eq(rows[4].ready, true, "main contains the release this fixture published")
  contains(rows[4].why, "previous release", "and the row says which fact it read")
  -- The channel's check, both answers, with its own probe stubbed: what it reads is this host's toolchain, and a
  -- case may not depend on whether the machine that runs it has zig.
  do
    local saved_probe = land.exec
    land.exec = function(command, cwd, timeout)
      if command:find("cargo%-zigbuild", 1) then return { code = 0, stdout = "no\n", stderr = "" } end
      return saved_probe(command, cwd, timeout)
    end
    local row = land.release_checks.channel({})
    land.exec = saved_probe
    eq(row.ready, false, "no cargo-zigbuild: the channel's precondition is not ready")
    contains(row.why, "cargo-zigbuild", "and it names what is missing")
    contains(row.next, "provision-publish-toolchain", "with the one command that fixes it")
  end
  do
    local saved_probe = land.exec
    local asked_targets = {}
    land.exec = function(command, cwd, timeout)
      if command:find("cargo%-zigbuild", 1) then return { code = 0, stdout = "yes\n", stderr = "" } end
      if command:find("rustup target list", 1) then
        asked_targets[#asked_targets + 1] = command
        return { code = 0, stdout = "yes\n", stderr = "" }
      end
      return saved_probe(command, cwd, timeout)
    end
    local row = land.release_checks.channel({})
    land.exec = saved_probe
    eq(row.ready, true, "with the toolchain and both rust targets, the channel's precondition is ready")
    eq(#asked_targets, 2, "and it asks for the std of each target the channel publishes")
    contains(asked_targets[1], "x86_64-unknown-linux-musl", "the first is this machine's")
    contains(asked_targets[2], "aarch64-unknown-linux-musl", "the second is the other one the channel publishes")
  end

  -- ------------------------------------------ case 48: a failed release leaves main alone and resumes by id
  setup_fixture()
  ready_checks()
  main_before = origin_main()
  behaviour.publish_fails = true
  eq(land.run({ run = "case48", release = true, signer = "local", ring = SOLO_RING, no_deploy = true,
    checks = standard_checks() }), 1, "a release whose publish fails stops")
  eq(journal_of("case48").stopped_at, "publish", "at publish, by name")
  eq(origin_main(), main_before, "and main is untouched")
  local nothing, nothing_text = captured(function() return land.run({ resume = true }) end)
  eq(nothing, 1, "a bare wa land --resume does not continue a release run")
  contains(nothing_text, "nothing to resume", "it says there is no landing to resume")
  behaviour.publish_fails = false
  builds = observed.builds
  eq(land.run({ run = "case48", resume = true }), 0, "--run <id> --resume finishes it (the run remembers it is a release)")
  eq(journal_of("case48").result, "done", "the release is done")
  eq(step_of("case48", "merge").state, "skipped", "and the resume merged nothing")
  eq(observed.builds, builds, "the build was not repeated")
  local resumed_main = origin_main()
  ok(resumed_main ~= main_before, "the resumed release published the channel, so main moved by one commit")
  eq(must("git -C " .. repo .. " diff --name-only " .. main_before .. " " .. resumed_main, "the channel commit's paths"),
    "releases/index-linux.json", "and that commit carries exactly one path")
  local linux48 = step_of("case48", "linux") or {}
  eq(linux48.state, "done", "the channel step is done on the resume")

  -- ------------------------------------------ case 49: --until main is a complete landing; a release is separate
  setup_fixture()
  ready_checks()
  builds = observed.builds
  local code49, text49 = captured(function()
    return land.run({ run = "case49", ring = SOLO_RING, branches = { "change/one" }, until_step = "main",
      checks = standard_checks() })
  end)
  eq(code49, 0, "a landing that stops after main exits 0")
  local j49 = journal_of("case49")
  eq(j49.result, "stopped_at_until", "its result is stopped_at_until")
  eq(j49.stopped_at, "main", "at main")
  eq(origin_main(), j49.tree_commit, "and main IS the landed tip")
  contains(text49, "the landing is complete", "the output says the landing is complete")
  contains(text49, "wa release cut", "and names the release command as a separate one")
  eq(observed.builds, builds, "no release was built by the landing")
  R.state.deploy_requests = {}
  eq(land.run({ run = "case49r", release = true, signer = "local", ring = SOLO_RING,
    checks = standard_checks() }), 0, "a later release runs on its own, and deploys the ring")
  eq(step_of("case49r", "deploy").state, "done", "the release run's deploy step ran (scripted node)")
  ok(#R.state.deploy_requests >= 1, "the ring's node was asked to install")
  eq(R.state.deploy_requests[#R.state.deploy_requests] and R.state.deploy_requests[#R.state.deploy_requests].commit, j49.tree_commit,
    "and it was asked for main's commit")
  eq(journal_of("case49r").tree_commit, j49.tree_commit, "it releases the main that landing made")
  local after = journal_of("case49")
  eq(after.result, "stopped_at_until", "the landing's journal is untouched by the release")
  eq(after.steps.artifacts and after.steps.artifacts.state or nil, j49.steps.artifacts and j49.steps.artifacts.state or nil,
    "and none of its steps was resumed")
  land.release_checks = real_checks
end)()


R.stop_vault()
print(string.format("land ok (%d checks)", R.count()))
