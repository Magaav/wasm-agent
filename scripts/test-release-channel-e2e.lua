-- `wa release cut` -- THE CHANNEL STEP, END TO END, over the scripts and the build it really runs.
--
-- WHY (Fable, 23/11). Every earlier row replaced one half of this step with a stand-in:
-- scripts/test-land-linux.lua ran the REAL step (`impl.linux`) against a fixture publisher, and
-- scripts/test-linux-channel.sh ran the REAL publisher against a fixture builder. So
-- `scripts/release-linux.sh` - the part that builds the bytes and stages the bundle FROM them - had never run
-- inside a test, and release F's public channel died on its first real run
-- (release-20261123T082627Z-3fc25b76): the build wrote `wa` into the node's one build root
-- (docs/ONEROOT.md), the bundle step looked for it in `rust/target/<triple>/release/wa`, and the step answered
-- "no built binary at ...". Its receipt named the binary the whole time. The channel was published by hand that
-- day, so nothing had ever exercised the join.
--
-- WHAT RUNS HERE, and what does not:
--   real: the step (lua/core/land.lua impl.linux), scripts/publish-linux-channel.sh,
--         scripts/release-linux.sh, scripts/lib/build-receipt.mjs, scripts/lib/cargo-executable.mjs,
--         scripts/check-linux-channel-fresh.sh, the signature (a SCRATCH wa-vault, scripts/lib/
--         test-release-vault.sh, never the operator's) and its verification against the tree's trusted keys,
--         the git history and its remotes, the JSON index, and the commit the step pushes (index entry +
--         version bump);
--   stand-ins: the build itself (`node scripts/codemode-build.mjs build`), which compiles the node for two
--         triples - the stand-in writes a receipt of the real shape and a real executable at the path that
--         receipt names, OUTSIDE the checkout, where the real onebuild build puts it; `cargo` (which answers
--         the sentinel build with the `compiler-artifact` message naming its executable); `gh`
--         (scripts/lib/fake-gh.sh); and the TOOLCHAIN precondition (scripts/lib/build-requirements.sh), which
--         stats a rustup toolchain this fixture home does not have and is not the subject of this row.
--   The scratch HOME and the stand-ins' PATH are scripts/test-release-channel-e2e.sh's, which refuses to run
--   on the operator's home.
--
--   bash scripts/test-release-channel-e2e.sh      (this row needs that wrapper's environment)
local why_home = dofile("scripts/lib/scratch-home.lua").guard("test-release-channel-e2e.lua")
if why_home then print("REFUSED " .. why_home); os.exit(2) end

local R = dofile("scripts/lib/land-row.lua")
local land, repo, ok, eq, contains, must, setup_fixture = R.land, R.repo, R.ok, R.eq, R.contains, R.must, R.setup_fixture
local read_file, write_file, tree_root, json, behaviour = R.read_file, R.write_file, R.tree_root, R.json, R.behaviour
local shell = R.shell

R.start_vault()

-- THE TOOLCHAIN PRECONDITION, STANDING IN FOR ITSELF (and saying so): the real
-- scripts/lib/build-requirements.sh stats a rustup toolchain, node and the pinned code-mode assets, and refuses
-- on a fixture home. It is a precondition of a real build, not a fact this row can produce, and the real file is
-- exercised by every real build. A stub that accepted a MISSING BINARY would be the opposite mistake - that is
-- what this row is for, and it is not stubbed anywhere.
local REQUIREMENTS = [[#!/usr/bin/env bash
set -uo pipefail
wa_build_env() { :; }
wa_build_provision() { :; }
wa_build_check() { printf 'present rust\npresent node\npresent assets\n'; return 0; }
]]

local function head() return must("git -C " .. repo .. " rev-parse HEAD") end
local function origin_main() return (must("git -C " .. repo .. " ls-remote origin refs/heads/main"):match("^(%x+)")) end

-- The chain a release runs, copied in from the tree under test - so this row runs THIS tree's scripts, not a
-- copy that can drift.
local function install_real_chain()
  local files = { "scripts/release-linux.sh", "scripts/publish-linux-channel.sh", "scripts/codemode-build.mjs",
    "scripts/install.sh", "scripts/linux/bootstrap.sh", "lua/core/mcp.lua", "rust/Cargo.toml",
    "rust/wa-sentinel/Cargo.toml" }
  -- THE RECEIPT READERS are the thing this row is about, so they are copied when the tree has them: a tree that
  -- predates them stages the bundle from a guessed target directory, and that tree is exactly what this row must
  -- catch (it fails on the old defect, not on a missing fixture file).
  local optional = { "scripts/lib/build-receipt.mjs", "scripts/lib/cargo-executable.mjs" }
  for _, relative in ipairs(files) do
    local dir = relative:match("^(.*)/[^/]+$")
    if dir then must("mkdir -p '" .. repo .. "/" .. dir .. "'", "mkdir for " .. relative) end
    must("cp -f '" .. tree_root .. "/" .. relative .. "' '" .. repo .. "/" .. relative .. "'", "copy " .. relative)
  end
  for _, relative in ipairs(optional) do
    shell("cp -f '" .. tree_root .. "/" .. relative .. "' '" .. repo .. "/" .. relative .. "' 2>/dev/null")
  end
  -- The MCP runtime the bundle names (lua/core/mcp.lua M.RUNTIME): release-linux.sh refuses a bundle without it.
  local runtime = must("sed -n '/^M.RUNTIME={/,/}/p' '" .. repo .. "/lua/core/mcp.lua' | grep -o \"'[^']*\\.mjs'\" | tr -d \"'\"")
  for file in runtime:gmatch("%S+") do
    must("cp -f '" .. tree_root .. "/scripts/" .. file .. "' '" .. repo .. "/scripts/" .. file .. "'", "copy runtime " .. file)
  end
  must("cp -r '" .. tree_root .. "/ui' '" .. repo .. "/ui'", "copy the ui the builder stages")
  write_file(repo .. "/scripts/lib/build-requirements.sh", REQUIREMENTS)
  must("chmod +x scripts/release-linux.sh scripts/publish-linux-channel.sh scripts/lib/build-requirements.sh",
    "exec bits", repo)
  must("git add -A && git commit -q -m 'the release channel chain, as a release runs it'", "commit the chain", repo)
  must("git push -q origin main", "publish the chain", repo)
end

local function channel_run(id)
  local dir = land.run_dir(id)
  must("mkdir -p " .. dir .. "/evidence", "the run's evidence directory")
  return { id = id, tree = repo, journal = { run = id, release = true, tree = repo, tree_commit = head(),
    release_dir = dir .. "/release", artifacts = { signed = true, dir = dir .. "/release" } } }
end

-- ------------------------------------------------------------------ the cut: published, and FROM the receipt
behaviour.gh_authed, behaviour.gh_present = true, true
behaviour.channel_fails, behaviour.channel_wrong_commit = "", ""
setup_fixture()
install_real_chain()
local sha = head()
local short = sha:sub(1, 12)
-- The node release this cut makes, named as a tag: the freshness check compares the channel's newest entry with
-- the newest node release, and a fixture with no tag would pass that check for the wrong reason.
must("git -C " .. repo .. " tag node-" .. short, "the node release tag the cut makes")
local run = channel_run("e2eA")
local passed, result = land.impl.linux(run, { signer = "local" })
eq(passed, true, "the release channel step publishes over the real scripts and the real signature (" ..
  tostring((not passed) and ((result or {}).error or "") .. ": " .. tostring((result or {}).observed or "") or "") .. ")")
contains(tostring((result or {}).detail), "published v0.1.0", "and its answer names the release it published")
contains(tostring((result or {}).detail), "fresh", "with the live verdict the freshness check gave")
eq((run.journal.linux or {}).state, "published", "the journal records the publish")
eq(#((run.journal.linux or {}).targets or {}), 2, "for both targets the channel publishes")

local out = land.run_dir("e2eA") .. "/release/linux-channel/out"
local receipt_text = read_file(out .. "/wa-host.receipt.json") or ""
local receipt_ok, receipt = pcall(json.decode, receipt_text)
ok(receipt_ok and type(receipt) == "table" and receipt.ok == true,
  "the build wrote its own receipt (the file the bundle step now reads)")
-- THE DEFECT, IN ONE ASSERTION: the receipt's binary is OUTSIDE the checkout - the node's one build root - so a
-- bundle staged from `rust/target/<triple>/release/wa` cannot have come from these bytes at all.
ok(type(receipt) == "table" and tostring(receipt.binary or ""):sub(1, #repo) ~= repo,
  "the binary the receipt names is not inside the checkout (it is in the node's one build root): " .. tostring(receipt.binary))
local name = "wa-linux-x64-musl-" .. short
local bundled = must("tar -xzOf '" .. out .. "/" .. name .. ".tar.gz' " .. name .. "/wa | sha256sum | cut -d' ' -f1")
eq(bundled, tostring(receipt.binary_sha256),
  "the bundle's wa IS the bytes the build's receipt named (23/11: it was not staged from them at all)")
local manifest = read_file(out .. "/" .. name .. "/bundle.manifest") or ""
contains(manifest, "source_commit=" .. sha, "and the manifest names the commit being released")
contains(manifest, "target_triple=x86_64-unknown-linux-musl", "and the triple it was built for")
contains(manifest, "local_only=0", "and says it is not a test bundle")
-- the effect, not the command: the archive is ON the fake release, beside its signature
local tag = tostring((run.journal.linux or {}).tag or "")
contains(must("ls '" .. tostring(os.getenv("FAKE_GH_STATE") or "") .. "/" .. tag .. "' 2>/dev/null"), name .. ".tar.gz",
  "the signed set was uploaded to the release " .. tag)
local index_commit = tostring((run.journal.linux or {}).index_commit or "")
eq(must("git -C " .. repo .. " diff --name-only " .. sha .. " " .. index_commit),
  "lua/core/build_identity.lua\nreleases/index-linux.json",
  "the one commit the step pushed carries the index entry and the version bump, and nothing else")
contains(must("git -C " .. repo .. " show " .. index_commit .. ":releases/index-linux.json"), short,
  "and the live index on main names this release's commit")
eq(must("git -C " .. repo .. " rev-parse " .. origin_main() .. "^1"), sha, "main moved by exactly one commit, on top of the release")

-- ------------------------------------------------------------------ a receipt of ANOTHER commit is refused
-- The build's word is checked, not trusted: a receipt that describes another commit would stage bytes from a
-- source nobody released, so the step refuses by name and main does not move.
setup_fixture()
install_real_chain()
local other = must("git -C " .. repo .. " rev-parse change/one")
local before = origin_main()
local saved_exec = land.exec
land.exec = function(command, cwd, timeout)
  if command:find("publish%-linux%-channel%.sh") then command = "WA_FAKE_BUILD_COMMIT=" .. other .. " " .. command end
  return saved_exec(command, cwd, timeout)
end
local refused, why = land.impl.linux(channel_run("e2eB"), { signer = "local" })
land.exec = saved_exec
eq(refused, false, "a receipt that describes another commit stops the step")
eq((why or {}).error, "linux_channel_build_failed", "named by the publisher's own word")
contains(tostring((why or {}).observed), "build_failed", "and the observation is the publisher's refusal line")
contains(read_file(land.evidence_path("e2eB", "linux")) or "", "receipt_commit_mismatch",
  "the evidence names the receipt field that did not match (nothing was staged from those bytes)")
eq(origin_main(), before, "and main is untouched")

R.stop_vault()
print(string.format("release-channel-e2e ok (%d checks)", R.count()))
