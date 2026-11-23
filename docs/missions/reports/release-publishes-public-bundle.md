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
17. the release report's new rows: `| linux channel | published (v0.1.0, 2 target(s)) |` and `| channel index | releases/index-linux.json <sha12> on main |`
18. **the entrance**: ``✻ Welcome to wasm-agent! v0.1.0 · v6a7f613d`` (a commit label is prefixed `v`; a `node-<sha12>` release tag and a pin are printed as they are; each half is printed only when it is known)
19. **`wa --version`**: `wasm-agent v0.1.0 · v6a7f613d+dirty` (and `--build-info`'s `version=` is the same number)
20. `version_already_released: main's lua/core/build_identity.lua says <N> and v<N> already exists in this clone|on origin: the previous release's bump commit is missing, so this cut would ship bytes whose tag is taken` + `next: publish the bump commit (a release writes the NEXT number into M.PRODUCT_VERSION), or set that line to the next number, then cut again`
21. `release_bump_not_authorised: <why> ... next: quote Victor's instruction naming v0.2.0 in docs/release/RELEASE_NOTES.md and commit it, then wa release cut` (the preflight) and `linux_bump_not_authorised: <why> ... then wa release cut --run <id> --resume` (the step)
22. inside them: `bump_not_authorised: a minor bump needs Victor's quoted instruction naming v0.2.0 in docs/release/RELEASE_NOTES.md - a flag alone never moves the minor or the major` and `notes_missing: docs/release/RELEASE_NOTES.md is not in this tree, so no minor bump can be authorised`
23. `published v0.1.1 (2 target(s)) and releases/index-linux.json on origin/main = <sha12>: the released bytes say v0.1.1, and main's next cut is v0.1.2 (one patch past the release it follows); read back, fresh: ...`
24. `main's number is <N> and v<N> does not exist yet` (the version row, ready) and the reader's documented fallback `a binary older than the field falls back to the tree's one constant`
25. the bump commit's message: `releases: v0.1.1, the public Linux channel for <sha12> (main's next cut is v0.1.2)`
26. `version_already_released: the public channel for <sha12> was not published: its version is released elsewhere` with `<tag> already exists in this clone|on <origin> and names <sha12>, not <sha12>` - and, for a fresh run, `<tag> already exists ...` under `main's lua/core/build_identity.lua says <N> and ...`
### D. A resume was stuck on its own tag - fixed (round 3)

`impl.linux` refused `version_already_released` as soon as `v<N>` existed, BEFORE the "already present" probe. But
the tag is made by the publisher (`gh release create`) and the index commit is pushed afterwards, so a failure in
between (a refused push, a read-back, the freshness check) made `--resume` answer `version_already_released` for
ever - for a tag that very run had created. The same refusal also fired on a resume of a run that had finished.

- `M.version_tag_owner(tree, tag, commit)`: a tag that is ABSENT, or that names THIS release commit (locally or on
  the remote), is ours; only a tag naming ANOTHER commit is a collision. The step uses it instead of "any tag"; the
  publisher re-uploads with `--clobber` into a release of ours, which is what makes a resume idempotent.
- `M.release_checks.version(options, journal)` keeps refusing on ANY existing tag for a FRESH run (no
  `journal.tree_commit` yet) and applies the same "ours" rule on a resume - the row now gets the journal.
- A resume of a FINISHED run answers `already_present` (the probe runs and finds the index on main), never a
  refusal.
- The stale comments are gone ("from the tree's VERSION file ... `M.next_version` ... `v0.1.0` for the first cut",
  "a first cut of a tree whose VERSION already says 0.1.0"): the step's header now says the current rule.

**The test, and that it fails on the round-2 commit** (`scripts/test-land-linux.lua`, 101 checks):

- the fixture publisher now creates the tag too (`git tag -f <tag> <commit>`, which is what `gh release create
  --target` does), so a resume meets the state the field meets;
- a push that fails ONCE: the step stops as `linux_index_push_failed`, main did not move, and the tag exists at the
  release commit - then the RESUME completes, with exactly one tag, exactly one index commit (its two allow-listed
  paths, nothing else) and the entry written once per target (no duplicate from the second publish);
- a finished run resumed says `already_present`, and main does not move again;
- the preflight: the same tag is refused for a fresh run and accepted when the journal names that commit, and a tag
  naming another commit is refused in both cases.

Run against `64e2dcb6` with only `lua/core/land.lua` reverted (the harness and the row kept), the row FAILS at
`the same tag is not a refusal when the journal says this run is releasing that commit (got false, want true)` -
so the test does catch the defect.


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

## 7. The release owns the product version (added 22/11 23:55Z, `627fcc86`)

Victor: "make v0.1.0 be reflected into the entrance; v1.0 is wrong. each release we add v0.1.0 then v0.1.1 and so on
[a 1.0.0] needs major changes so i need to say so", and Fable's addition: "wa --version prints the product version
and the sha, from the same source, with a test".

**What was on the base first, and what the rebase changed**: on `6eb4b206` neither owner existed - no `VERSION`
file at the tree root and no `PRODUCT_VERSION` in `lua/core/build_identity.lua` - so this branch created a
`VERSION` file as the owner. Then main landed `change/launch-opening` (`8862b600`), which added
`M.PRODUCT_VERSION = "0.1.0"` in `build_identity.lua` with the comment that the release step owns that line.
Main landed first, so after the rebase the CONSTANT is the owner and this branch is the release that writes it:
the `VERSION` file is gone, `rust/wa-host/build.rs` and `rust/wa-capabilities/build.rs` each EXTRACT the constant
at build time (two readers, one owner - `wa-capabilities` cannot depend on `wa-host`), and
`M.product_version()` answers with the binary's embedded value, falling back to the constant for a binary older
than the field. The conflict in `chat.lua`/`cli_view.lua` was resolved by keeping BOTH sides: main's
`cli_view.model_line` composer and its `matrix` palette role, plus this branch's "each half only when it is
known, never `vunknown`" rule and the `v` prefix on a commit label.

- `rust/wa-host/build.rs` extracts `M.PRODUCT_VERSION` from `lua/core/build_identity.lua` at build time (with
  `cargo:rerun-if-changed` on that file), `rust/wa-host/src/build_info.rs::product_version()` trims it and
  `--build-info`'s `version=` is this number, not cargo's crate metadata.
- `rust/wa-capabilities/build.rs` reads the same line and puts `product_version` into the
  `host.build_identity()` JSON, so every Lua surface reads it from the binary instead of keeping a copy.
- `lua/core/build_identity.lua::product_version()`; `lua/core/chat.lua` hands it to the banner;
  `lua/core/cli_view.lua::banner` prints `✻ Welcome to wasm-agent! v0.1.0 · v<sha>` (a commit label gets the `v`,
  a `node-` release tag and a pin are printed as they are, and each half is printed only when it is known - never
  `vunknown`).
- `rust/wa-host/src/main.rs`: `wa --version` prints `wasm-agent v<version> · v<label>` - verified on a real build:
  `wasm-agent v0.1.0 · v627fcc86+dirty`.
- **`wa release cut` releases the tree's own number** (`M.tree_version`) and writes the BUMP behind it
  (`M.bump_version`): main's `M.PRODUCT_VERSION` always names the release the tree WILL be cut as (Fable, 23/11),
  so the bytes of a release print the number they are released as. The `linux` step uses that number as the channel
  release tag (`v0.1.0`, no more `wa-linux-<sha12>` and no more `-alpha.N`), rewrites the constant to `N+1` in
  place and commits that with the index entry - one commit, so the number a person reads and the bytes a machine
  installs never disagree. The commit's allow-list is exactly `lua/core/build_identity.lua` and
  `releases/index-linux.json`. See section 8 for the defect this replaced.
- **`--minor` / `--major` never move on their own**: the step refuses with `linux_bump_not_authorised` unless
  `docs/release/RELEASE_NOTES.md` carries Victor's instruction QUOTED, naming the bump and the version it produces
  (`Victor: "0.2.0 is a minor release: ..."`). A flag alone is never enough, and a tree without the notes file
  refuses too (`notes_missing`).

**Tests**

- `scripts/test-land-linux.lua` (68 checks): two releases in a row give `0.1.0` then `0.1.1` in the constant on main,
  in the tag, and in the index entry - and the header text is held to `Welcome to wasm-agent! v0.1.0 · vabc12345` /
  `v0.1.1`; `--minor` refused without the quote (`linux_bump_not_authorised`) and ALLOWED with it (`0.2.0`, tag
  `v0.2.0`).
- `scripts/test-product-version.lua` (16 checks, new, wired into the fast path's core rows): the reader's four
  answers (a version, a two-digit patch, `unknown` for a binary older than the field, trimmed), the four header
  shapes (version+sha, version+release tag, version+dirty sha, sha alone) and the ONE source: a binary built from
  this commit reports this tree's constant.
- `scripts/test-build-info.sh` (+3 checks) and `scripts/test-pin-label.sh` (rewritten): `--version` is held to
  `wasm-agent v<version> · v<...>`, `version=` to the file. The pin row's old assertion - "never the crate's
  0.1.0" (the 18/11 rule) - is REPLACED by the 22/11 one, not deleted: the line must carry the product version AND
  the bytes' label, in that order. A version without a sha would be the 18/11 lie again.
- `scripts/test-linux-channel.sh` (32 checks): the tree's `VERSION` decides the release tag (`v0.1.0`), the asset
  names keep the sha, the sums name both archives.

**Not verified here**: no real cut was run, so the version has never been bumped by a live release; the bump of
`VERSION` across two real cuts is proved only by the fixture. `scripts/test-build-info.sh` was run against a
release build of this tree (`27 checks, 0 failed`) and `scripts/test-pin-label.sh` (`11 checks, 0 failed`).

## 8. Fable's review round (23/11): A the defect, B and C measured

### A. The released bytes showed the PREVIOUS number - fixed

The cut built the bundles from the release commit and only afterwards rewrote `M.PRODUCT_VERSION`, so the second
cut published `v0.1.1` in the tag and the index while the `wa` a person installed printed `v0.1.0`. Fixed by
changing what the number MEANS, not by an override: **main's constant is the release the tree WILL be cut as.**

1. The cut releases `N`, the tree's own number - never "one past the tag" - so the bytes are built from a tree
   whose constant IS `N` (`impl.linux`, `M.bump_version`).
2. In the SAME commit as the index entry it writes `N+1` (patch) behind it, for the next cut; `--minor`/`--major`
   change the BUMP (`N.minor+1.0`, `N.major+1.0.0`), with the same quoted-instruction rule, so a minor is decided
   one release ahead. The commit message says both numbers.
3. A number whose tag already exists (the previous release's bump commit never landed) is refused in the FIRST
   second by the new `M.release_checks.version` row as `version_already_released` - before any artifact is built
   or published. The step refuses it too (`version_already_released`), so a caller that reaches it without the
   preflight gets the same answer; `release_bump_not_authorised` is refused at both ends for the same reason.
4. `M.PRODUCT_VERSION = "0.1.1"`: v0.1.0 is being published by hand from 8862b600 tonight, so this branch
   carries main's NEXT cut. The "first cut" special case is gone - the rule is one sentence now.

**Evidence the released bytes print the released number** (two real builds, two constants):

| tree's constant | `wa --version` of a binary built from it |
| --- | --- |
| `0.1.0` (commit `6a7f613d`, measured earlier) | `wasm-agent v0.1.0 · v6a7f613d+dirty` |
| `0.1.1` (commit `85513ce5`, this branch) | `wasm-agent v0.1.1 · v85513ce5+dirty` |

and the fixture holds the two cuts to it: for each cut, the RELEASED commit's `M.PRODUCT_VERSION` equals the tag it
is published under and the index entry's `tag`, while main (one commit later) already carries the bump -
`scripts/test-land-linux.lua`, 85 checks, including "the RELEASED commit's one owner says 0.1.0 - the number its
bytes print" and "the released bytes of the second cut say 0.1.1 too". A binary built from 8862b600 (tonight's
hand cut) prints `wasm-agent 8862b600` - that commit predates the `v<number> · v<sha>` line, so the hand cut's
bytes name their commit and not a number; the `v0.1.0` release exists as a tag and an index entry, not in that
binary's line.

**Between releases the header shows the NEXT number beside the sha** (`v0.1.1 · v<sha>`) - the bytes in your hands
are the release whose tag is the one before it. That is the shape Victor asked for, said here because it surprises:
the number on main leads the release, the number in a release names itself.

### B. What a fleet update does after a cut - MEASURED, and the step moved

Measured in the code that decides it, not assumed:

- `scripts/deploy-rendezvous.sh:10,13`: a node deploys only while `HEAD == EXPECTED` AND `origin/main == EXPECTED`
  - otherwise `fail 'source is not origin/main'`.
- `scripts/deploy.sh` (the canonical-tree gate, lines ~423-446): it builds nothing but a tree whose `HEAD` is
  EXACTLY `origin/main` and clean; a tree that is behind waits up to 600 s and then fails `canonical_busy`.

So with the channel step BEFORE the deploy (where I first wrote it), `main` was one commit past the released
commit at deploy time: every tree deploy of the released commit would have been refused, and a cut whose deploy is
refused is a cut that shipped to nobody. **The step now runs AFTER `deploy`** (`M.STEPS`, this commit): the ring
takes the released commit while main is still that commit, and main moves afterwards.

What the three per-node commands do after a cut (`main` = released + 1):

| command | after a cut |
| --- | --- |
| `wa update mail --binary --commit <released>` | installs that commit's published binary; the binary path has no tree gate - works. |
| `wa update nextcloud --release` | installs the published release into the node's prefix - no tree gate - works. |
| `wa update openclaw --tree --commit <released>` | would need a canonical tree equal to `origin/main`, which is now the bump commit: it waits and then refuses. For a tree node, ask for main's tip (`wa update openclaw --tree`, no `--commit`), which installs the bump commit's bytes. |

### C. The laptop's sentinel on the bump commit - MEASURED

The bump commit touches exactly two paths: `lua/core/build_identity.lua` and `releases/index-linux.json`. Measured
with the real classifier (`scripts/lib/node-binaries.sh`):

- `lua/core/build_identity.lua` - **not** a compiled input;
- `releases/index-linux.json` - **COMPILED** (any path with a slash that is not on the not-compiled list).

So the bump commit's compiled-inputs digest differs from the released commit's and the node's next redeploy cannot
reuse the published binary: it fast-forwards to main (the gate passes - `HEAD == origin/main`) and takes the cargo
path, i.e. the ~5 minute rebuild Fable called acceptable. Not a refusal, not a red: the deploy builds and
main-health measures the bump commit.

One thing there WOULD have been red, and is fixed in this round: `scripts/test-opening.lua` pinned
`identity.PRODUCT_VERSION == "0.1.0"` - landing this branch would have failed that row on the bump and every
release after it, a red main-health caused by a test rather than by the code. It now asserts the SHAPE and the
one-source rule (a `d.d.d` constant, never the alpha tag, every surface through the one reader) - stricter in what
it covers, and it cannot go red because a release moved the number.

The cheap alternative for C (add `releases/*` to the not-compiled list in `wa_compiled_input`) is NOT taken here:
that function decides every node's binary reuse, and a one-line change to it is a fleet-wide measurement of its
own. Recorded as the next step, not done in a review round.

