# release-publishes-public-bundle

`wa release cut` publishes two channels for one commit: the `node-<sha12>` release an existing node updates from,
and the public Linux bundle channel (`releases/index-linux.json`) a machine with no node installs from. Until this
branch it published only the first, and the second had to be written by hand.

- branch: `change/release-publishes-public-bundle`, base `6eb4b206`
- commits: `c0a60678` (the freshness check), `2ab48ee8` (the publisher + its fixture suite), `a405939a` (the
  `linux` step, its fixture and the land rows it changes), `9f5c7db4` (a row for the step + the wiring)
- nothing was published: no `gh release`, no upload, no index change on the public channel. Every test below runs
  against a fake GitHub in its own scratch HOME.

## 1. What was measured before any code (and which brief facts had moved)

- `scripts/install.sh:177` picks the channel (`linux) CORE_PATH=scripts/linux/bootstrap.sh; CHANNEL='linux bundle
  (releases/index-linux.json)'`), `scripts/install.sh:241` fetches `$BASE/$REF/releases/index-linux.json`; the core is
  fetched from the COMMIT the entry names, never from `main`.
- `scripts/linux/bootstrap.sh:45` is the index URL, `:199-202` picks the first entry for this machine's target from
  a JSON read by python3, and `:240-262` verifies, in this order: the signed `SHA256SUMS` beside the asset, the
  asset's size against the index entry, the asset's sha256 against the signed sums, then `bundle.manifest` ->
  `files.sha256` -> every member.
- `scripts/release-linux.sh` builds one bundle per `--target` (the shipping build, `scripts/codemode-build.mjs`),
  refuses a `--local` bundle as publishable, writes `bundle.manifest`/`files.sha256`, and with `--publish TAG`
  uploads the asset + `SHA256SUMS` + `SHA256SUMS.sig` and rewrites the index - and prints that it does NOT commit
  it.
- `wa release cut` is `lua/core/land.lua`'s `release_cli` -> `wa land --release`; `M.STEPS` was
  `collect, plan, review, merge, gate, push, main, artifacts, sign, ship, publish, deploy, report` - the node release
  and nothing else.
- **The brief's first fact had already moved, the defect had not.** Fable's measurement ("newest x86_64 entry
  `v0.1.0-alpha.13` at `d80d86bd` (30/10), 23 days stale") was true at 17:30Z; by 18:17Z the same day alpha.16
  (`fc581ca2`) and alpha.17 (`d5b17c60`) had been published INTO the index by hand. Measured again at ~23:50Z on
  22/11, `bash scripts/check-linux-channel-fresh.sh` answered
  `stale: the newest published entry (d5b17c6007c6, aarch64-unknown-linux-musl, commit time 2026-11-22T17:26:36Z) is older than the newest node release node-c6f890e39840 (commit time 2026-11-22T18:19:14Z): the channel skipped a cut`
  - i.e. the channel was one cut behind again, because nothing in a cut writes it. Six release runs exist under
  `~/.wasm-agent/land/release-2026112*` for 22/11 (node-575510645889, node-c9904f6eb570, node-a9d4617d9692,
  node-fc581ca2319b, node-d5b17c6007c6, node-c6f890e39840), all `--signer local --no-deploy`, and the channel moved
  for two of them - by hand. So the defect is not "the channel is old", it is "the channel is a separate act".
- The second thing the same measurement settles: **the real cut signs on this node and uploads with this node's
  `gh`** (`signer: local` in every 22/11 journal; `publisher: gh here is signed in` in the preflight). The routed
  signer is not the normal path but it exists (`--signer <node>`), so it is supported here too (§3).

## 2. The freshness check (`c0a60678`)

`scripts/check-linux-channel-fresh.sh [--index FILE] [--repo DIR]` answers with a verdict, not an exit code that
means "ok":

| exit | first line | when |
| --- | --- | --- |
| 0 | `fresh: ...` | the newest published entry is not older than the newest `node-<sha12>` release (or is the same commit, or there is no node release yet) |
| 1 | `stale: ...` | the newest entry is older; also when the index is EMPTY (`stale: index_empty: ...`) |
| 2 | `unknown: ...` | no index, an unparseable one, a foreign schema, a commit this repository does not have, no python3/git |

`unknown` is never `fresh`: a check that cannot tell must not answer the way a green gate reads. This is the
"test that fails when the index's newest entry is older than the newest node-<sha12> release" the mission asked
for, as a program the step also runs; its fixtures are in §4.

## 3. The publisher and the step

`scripts/publish-linux-channel.sh` (`2ab48ee8`) is the one code path, standalone and inside the cut:

1. refuses a dirty tree, a commit that is not `HEAD`, a tag that is not `wa-linux-*`, a triple outside the
   ALLOW-LIST (`x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`), and a missing signing library - each by
   name, before anything is built;
2. asks `gh auth status` BEFORE the build (a cut that pays for two bundles and then finds gh signed out is the
   19/11 defect paid twice);
3. builds one bundle per target with `scripts/release-linux.sh --target` and reads every field back FROM THE
   BUNDLE (`source_commit`, `target_triple`, `local_only=0`), so a bundle built for another commit is refused;
4. writes ONE `SHA256SUMS` over the archives (accumulating the rows a previous publish of the same tag left),
   signs it with `scripts/sign-release.sh` (wa-vault's `release-signing` key) and verifies it HERE against the keys
   this tree trusts;
5. uploads to the tag `wa-linux-<sha12>` (NOT `node-<sha12>`: that release's `SHA256SUMS` is the node binaries'
   own trust root) and READS THE RELEASE BACK, holding it to the asset names and sizes measured here;
6. writes one entry per target into the index with node (the fields `bootstrap.sh` validates), keeps the older
   entries below, and replaces its own (commit, target) rows so a rerun cannot duplicate them;
7. runs the freshness check on the file it just wrote.

Two half-modes exist for a run whose signer is another node: `--build-only` (build + sums, unsigned) and
`--upload-only` (verify the signed sums, upload, index). They are the SAME functions, split either side of one
signature - `impl.linux` uses `M.sign_on_node`, the helper the `sign` step already uses, so a routed signature is
made and verified by the same code.

`impl.linux` (`a405939a`) is the step, ordered between `publish` and `deploy`:

- refuses by name when the run has no tree/commit (`linux_without_tree`/`linux_without_commit`), when the node
  release is not signed (`linux_unsigned_release`), when the target is outside the allow-list
  (`linux_target_unknown`), and carries the publisher's own refusal name up (`linux_channel_build_failed`,
  `linux_channel_index_stale`, ...);
- skips publishing when `origin/main`'s index ALREADY names this commit for every target (`already_present`);
- creates the index commit in a worktree of `origin/main` - never in the run's own tree, which a resume recreates
  from `tree_commit` - stages exactly `releases/index-linux.json` (and refuses `linux_index_path_not_allowed` if
  anything else is staged), validates the file the publisher wrote before committing it (`linux_index_invalid`,
  `linux_index_incomplete`), commits it, fast-forwards `main` (never a force push: `linux_index_not_fast_forward`),
  reads `main` back (`linux_index_not_readback`), and then judges the LIVE copy: every target named
  (`linux_index_incomplete`), and no older than the newest node release (`linux_index_stale`) or
  `linux_index_freshness_unknown` when that cannot be decided.

`M.release_checks.channel` (`a405939a`) asks for the toolchain in the first second (`cargo-zigbuild` on PATH, the
rust std for both targets), beside the existing signing/publishing/ancestry rows.

### The one invariant this changes, and the assertions it changed

A release now moves `main` by exactly one commit: the channel entry is useless in a worktree, because the installer
reads it from `main`. The old headers said "it pushes no branch and moves no main" (`lua/core/land.lua`, the
release-loop comment) and several rows asserted it. None of those assertions was deleted or loosened - each was
replaced by a stricter pair ("one commit past, carrying exactly one path", and "the live index names this
release"):

- `scripts/test-land-plan.lua` case 2 (`a405939a`): was `main IS the landed tip`; now `main_tip^ == landed tip`,
  `diff --name-only landed..main_tip` is exactly `releases/index-linux.json`, and the live index names the release.
- `scripts/test-land-until.lua` case 46 and 48 (`a405939a`): was `origin/main is where it was`; now the same pair,
  plus `observed.channel_pushes == 1` (the harness counts the channel's push apart from a landing's, so "no landing
  step pushed main" keeps its meaning). The gate-reuse case (was: a second release keeps the verdict of the first)
  now runs two release runs that STOP AT THE GATE - the only place main cannot move between them.
- `scripts/test-land-resume-19-11.lua` case 26 (`a405939a`): was `ls-remote origin main == landed tip`; now the
  remote's main carries the landed tip under the channel's one commit, and the credential node's routed push is
  asserted on its own (`state.routed_calls`).

## 4. Tests, and where they are wired

- `scripts/test-linux-channel.sh` (31 checks, 2 s): the freshness verdicts over a real git history with real
  `node-*` tags (fresh/stale/empty/unknown/foreign schema/unknown commit/no release), and the publisher's every
  refusal against a fake GitHub and a fixture-key signer - `build_failed`, `local_bundle`, `target_mismatch`,
  `commit_mismatch`, `release_not_signed`, `release_key_not_trusted`, `publish_needs_credentials` (before the
  build), `publish_failed`, `publish_not_readback`, `source_dirty`, `target_unsupported`, `tag_invalid`, plus
  `--no-publish`, `--check`, the entry contract `bootstrap.sh` validates, the older entries kept, and a rerun that
  replaces instead of duplicating. Its own scratch HOME; it refuses to run in the operator's.
  Wired: `scripts/test.sh` (`gate_run bash scripts/test-linux-channel.sh`, next to the Linux channel's installer
  row) and `scripts/fast.sh` (`check linux-channel bash scripts/test-linux-channel.sh`). (`2ab48ee8`, `9f5c7db4`)
- `scripts/test-land-linux.lua` (48 checks, 5 s): the step's place in `M.STEPS`, its ledger name, the tag shape,
  the plan's skips (docs-only, lua-only, components) and the forced run for a release-mode ring node, and the step
  itself through the real `impl.linux` - published (one commit on main, one path, the live index naming the
  release), a rerun that publishes nothing twice, and six refusals with `main` untouched: `linux_unsigned_release`,
  `linux_target_unknown`, `linux_channel_build_failed`, `linux_channel_index_stale`, `linux_index_incomplete` (the
  read-back case), plus the routed signer (`--signer laptop`: the sums are signed on the node, once).
  Wired: `scripts/lib/fast-rows.sh` (the always-on core rows, beside the other land rows) and therefore the fast
  path and the gate's Lua parity run; listed by glob as a candidate row, so the planner and the runner agree.
  (`9f5c7db4`)
- The fixture (`scripts/lib/land-row.lua`, `a405939a`): the channel publisher stand-in (the same flags, an entry per
  target, the two refusals), the REAL freshness check copied in, a `releases/index-linux.json` in the fixture repo,
  `observed.channel_pushes`, and the two knobs the row needs (`channel_fails`, `channel_wrong_commit`).

Rows run on this branch (avell, 22/11): `test-land-plan` (108), `test-land-release` (70), `test-land-sign` (46),
`test-land-rows` (137), `test-land-review` (47), `test-land-resume` (42), `test-land-resume-19-11` (22),
`test-land-quick` (155), `test-land-gate-rows` (82), `test-land-marks` (27), `test-land-gate-log` (8),
`test-land-linux` (48), `test-linux-channel` (31). No pre-existing failure was found in these rows; none of them is
claimed green on the full suite, which was not run here.


## 4b. Discrimination (does each test catch the change?)

`bash scripts/test-discriminates.sh 6eb4b206` (run here, 16 min) reported `1 discriminating, 0 blocking, 4
environment`: `scripts/test-linux-channel.sh` fails 31/31 on the base code (`linux-channel: 0 passed, 31 FAILED`),
and the four Lua rows were NOT judged by that script - it has no `wa` binary in its scratch worktree ("this tree has
no wa binary, so a Lua row cannot run the base code"). The four were judged by hand instead, against a worktree of
`6eb4b206` with the branch's test files on top and the installed `wa` driving them:

| row | on `6eb4b206` |
| --- | --- |
| `scripts/test-land-linux.lua` | `check failed: the channel step comes right after publish (got nil, want 12)` |
| `scripts/test-land-until.lua` | `check failed: step linux ran (got nil, want done)` |
| `scripts/test-land-plan.lua` | `check failed: main is one commit past the landed tip: the channel index (got e6604beb..., want e253e2ba...)` |
| `scripts/test-land-resume-19-11.lua` | not run by hand: it is changed the same way (the routed main push plus the channel commit) and the two rows above prove the pattern; the gate runs it. |

No assertion was deleted or loosened for this: the three changed rows assert MORE than they did (a channel commit,
its single path, and the live index naming the release), which is why they fail on a base that publishes no channel.

## 5. Texts to approve (operator-facing, verbatim)

1. `stale: the newest published entry (<short>, <target>, commit time <UTC>) is older than the newest node release <tag> (commit time <UTC>): the channel skipped a cut`
2. `next: publish the channel for the newest release - the linux step of "wa release cut" does it (scripts/publish-linux-channel.sh --commit <sha>); the lag stays silent until an install fetches a file the old entry names and that file has moved`
3. `unknown: <index_missing|unparseable|foreign_schema|commit_unknown|python3_missing|git_missing>: ...` + `next: nothing was decided here; a channel that cannot be read must not read as a published one`
4. `fresh: the newest published entry (...) is not older than the newest node release <tag>` / `fresh: the newest published entry (...) IS the newest node release <tag>` / `fresh: no node-<sha12> release in <repo>: there is no release for the channel to keep up with (...)`
5. `stale: index_empty: <index> publishes no Linux bundle at all, so a fresh machine has nothing to install`
6. `publish_needs_credentials: gh here is missing or signed out (gh reads its token from the desktop keyring; a systemd user unit has no session bus to unlock it), so nothing was built and nothing was uploaded; run the cut from a desktop shell, or build with --no-publish and upload by hand`
7. `release_not_signed: the sums were not signed by wa-vault, so no channel entry may name these bytes (WA_VAULT_ADMIN_URL/WA_VAULT_ADMIN_TOKEN where the vault reads them; or --build-only, sign where the vault answers, then --upload-only)`
8. `release_key_not_trusted: the signature beside <sums> does not verify against the keys <tree> (and this node) trust; a machine installing from this entry would refuse it`
9. `publish_failed: gh release upload <tag>` / `publish_failed: gh release create <tag>`
10. `publish_not_readback: <tag> does not list <asset> after the upload: <listing>`
11. `local_bundle: the bundle was built with --local (a test artefact) and is not publishable`
12. `target_unsupported: <triple> (this channel publishes x86_64-unknown-linux-musl and aarch64-unknown-linux-musl)` / `linux_target_unknown: the channel is asked for <triple>, and it publishes ...`
13. `commit_mismatch: the bundle records <sha>, not <sha>` / `target_mismatch: the bundle records <triple>, not <triple>` / `bundle_incomplete: <path> is missing (build it first: --build-only)`
14. `index_stale: <the freshness line>` / `index_freshness_unknown: the channel could not be judged: <the freshness line>`
15. `index    <path> (not committed here: the index is the trust root and a commit on main)` (the standalone publisher) and the step's own `published <tag> (<n> target(s)) and releases/index-linux.json on <origin>/main = <sha12> (read back, <freshness>)`
16. `linux_index_push_needs_credentials: ... next: the channel index is a commit on main and needs the credential that pushes main: run this step where that credential is (a desktop shell with gh signed in on this node)` - and `linux_index_not_fast_forward`, `linux_index_path_not_allowed`, `linux_index_invalid`, `linux_index_incomplete`, `linux_index_not_readback`, `linux_unsigned_release`
17. the release report's new row: `| linux channel | published (wa-linux-<sha12>, 2 target(s)) |` and `| channel index | releases/index-linux.json <sha12> on main |`

## 6. What was NOT verified (and what would verify it)

- **No real cut was run** (the mission forbids it), so the real path - two musl bundles built by
  `scripts/release-linux.sh --target` (cargo-zigbuild, the aarch64 candidate executed through binfmt), signed by
  wa-vault and uploaded with gh - has not been exercised end to end. The next `wa release cut` does it; the build
  half can also be proved alone with `bash scripts/publish-linux-channel.sh --no-publish` on a clean main.
- **The human test** ("the public install command into a scratch HOME and prefix installs, and `wa --version` there
  names the same commit as the release tag") needs a published bundle: it is the next cut's acceptance, not this
  branch's.
- **The `--account <node>` routing of the index push is not implemented.** The bundles are built and uploaded here
  and the index commit is pushed with THIS node's git credential; a cut that routes main to another node still
  publishes the channel, but the index push would fail by name (`linux_index_push_needs_credentials`) rather than
  being routed. Every 22/11 journal cut locally, so this is not the normal path - but it is a hole, named.
- The full gate (`scripts/test.sh`) and the fast path were not run on this branch: only the rows listed in §4, one
  file at a time, plus `luac5.4 -p` on every edited Lua file.
- Nothing was published: no `gh release`, no upload, no change to the public `releases/index-linux.json`. The
  fixture's GitHub is a directory; its signing key is `tests/fixtures/release-sign/keys.txt`.
