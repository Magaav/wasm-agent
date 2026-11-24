# components-reproducible

Priority 3, overnight 22-23/11. Fable measured (22/11 ~14:40Z) that a fresh build on avell no longer
reproduced 9 of the 11 pinned components. Branch `change/components-reproducible`, base `0d8657e5`,
worktree `/home/victor/Work/missions/components-reproducible/wt`. Commits `8911add6` (the build),
`197f9c6b` (the five repinned lines and the publish line) and `940e4dd6` (the check, its wiring, docs).

## Premises, re-measured before writing code

| brief said | measured on the base (main `0d8657e5`, node rustc 1.100.0, wasi-sdk 34.0) | verdict |
| --- | --- | --- |
| 9 of 11 pinned components no longer rebuild here | **10 of 11**: agent-core, graph, hooks, memory, mesh, model-gateway, selfloop, telemetry-sink, wa-email and wa-whatsapp differ; only `codemode` (225,184 bytes `9091cd79…`) is the pin | undercounted by one (wa-whatsapp was not in the list) |
| "most in size" | 8 of the 10 differ in size and in sha256; `mesh` differs in sha alone (both 211,918 bytes) and `wa-whatsapp` in both (8,814,222 against the pinned 8,840,589) | the size/sha split is the two causes, below |
| the cause is toolchain drift, dependency drift, or an embedded path/time | **one of those three plus a fourth the brief did not name**: (a) the compiler, (b) the checkout path, and (c) three pins main had left behind after real source changes - not a build fault at all | the brief's list was incomplete |
| nothing was repinned by Fable | correct: `components.lock` is untouched by the 22/11 bundle work | correct |

## The measurement that names the causes

**(a) The compiler.** The eleven pinned artifacts embed the rustc that built them. Eight carry
`/rustc/58cf8f9c35b3…` (`rustc 1.99.1 (58cf8f9c3 2026-10-13)`, the toolchain rustup installs for `1.99.1`);
`mesh`, `wa-whatsapp` and `codemode` carry `0ef1bc38…`, which is this node's default `1.100.0 (0ef1bc386
2026-11-09)`. So the lock has always needed two compilers at once, and the node could only ever match part
of it. Confirmed by rebuilding with the pinned one: with `RUSTUP_TOOLCHAIN=1.99.1`, on the base tree, in the
base checkout, `agent-core` becomes exactly the pin (392,561 bytes / `b24672b2…`), and so do `hooks`,
`memory`, `selfloop` and `telemetry-sink`; `model-gateway` and `wa-email` come out at the pinned size with
a different sha256, which is (b).

**(b) The checkout path, for exactly the five components with a `path =` dependency** (`graph` → wa-graph,
`mesh` → wa-mesh-core, `model-gateway` → wa-model-gateway, `wa-email` → outbox+index, `wa-whatsapp` →
outbox+index). Measured the way docs/COMPONENTS.md measures it: one commit, two checkout paths, the same
toolchain - `mesh` is 211,918 bytes with sha256 `4769e631…` from one path and `871179cc…` from the other,
and Cargo's own artifacts are named `libwa_mesh_core-8ee54b00c7a6cacd.rlib` in the first and
`libwa_mesh_core-cf7108a003359ad6.rlib` in the second. Cargo's source identity for a path package is its
canonical absolute path; that hash reaches the artifact through `-C metadata`, so no wrapper can take it
over (measured earlier in docs/COMPONENTS.md and re-measured here).

**(c) Three pins main had already walked past.** With (a) and (b) removed the build was reproducible and
agreed with six pins; the five that still differed were `codemode`, `mesh` (the compiler: `codemode`'s last
source change is its own 22/11 pin `99e817a8`, and `mesh`'s only changed file since 18/11 is
`wa-grant-policy/src/tests.rs`) and `graph`, `wa-email`, `wa-whatsapp` (the source: `rust/wa-graph/src/store.rs`,
`rust/wa-queue/src/queue.rs` and fourteen files of wa-whatsapp's tree and its outbox/index have changed
since those lines were set on 13/11 and 17/11). Half 1 of `scripts/test-component-pins.sh` judges that range
and did not catch it; that is a separate hole and is NOT fixed here (see "What is still open").

## The fix

`8911add6` - two inputs pinned instead of ambient, both in `scripts/build-components.sh`:

* **the compiler**: `COMPONENT_TOOLCHAIN="${WA_COMPONENT_TOOLCHAIN:-1.99.1}"` (`scripts/build-components.sh:28`),
  installed through rustup when the node lacks it (`:32-40`), exported as `RUSTUP_TOOLCHAIN` (`:41`).
  `WA_COMPONENT_TOOLCHAIN=node` builds with the node's default and is a named diagnosis aid, never the path
a  shipped artifact comes from.
* **the build root**: the tree is copied to `BUILD_ROOT="${WA_COMPONENT_BUILD_ROOT:-${TMPDIR:-/tmp}/wa-component-build}"`
  (`:199`) and built there - `/tmp/wa-component-build/src`, one path for every checkout, held for the whole
  run by `flock -o` re-exec, re-extracted per run so mtimes (and Cargo's cache) survive; where flock is
  missing the copy is `src-<hash of the tree>`, which needs no lock. `WA_COMPONENT_STABLE_ROOT=0` builds in
  the checkout and is the way to see what the path contributes.
* every run now prints `component toolchain: rustc …; wasi-sdk: 34.0` and `component build root: …`, so a
  build that does not match is diagnosed instead of guessed at.

`197f9c6b` - the five drifted lines repinned from the measured build, with each line's cause written into
`components.lock` (`components.lock:16`, "HOW THESE LINES ARE REPRODUCED"), and
`scripts/publish-components.sh` now ends a clean run with `all 11 match components.lock` - the phrase the
acceptance is stated in, printed only after every pinned name was measured in the run's own directory.

Measured after the fix: the same eleven components build to the same eleven sha256 from two different
checkout paths (the worktree and a second copy at `/tmp/wt-b2`), and `bash scripts/publish-components.sh`
prints `all 11 match components.lock`.

## The check that fails when a fresh build is not the pin (`940e4dd6`)

`scripts/test-component-lock-rebuild.sh` builds `agent-core hooks mesh graph` by default (`--all` for the
eleven) through the shipped pipeline into a private directory, compares each artifact's sha256 AND size to
its own line, greps it for the checkout path and the build root, and rebuilds one component with
`WA_COMPONENT_STABLE_ROOT=0` to prove the copy is a location and not an input. A parity half that cannot run
is a failure, not a skip. Wired into `scripts/test.sh:580` (it needs wasi-sdk and minutes; not in
`scripts/fast.sh`).

It discriminates, measured both ways: on the base `0d8657e5` it exits 1 (`hooks` 217,693 bytes /
`970ed931…` against the pinned 215,897 / `f5fef708…`), and on this branch it is 4 of 4 green.

## What Victor's test does now

`bash scripts/publish-components.sh` on this branch, no `--from`, prints (23/11):

```
publish-components: verified agent-core: b24672b2… (392561 bytes)
… eleven lines …
publish-components: all 11 match components.lock
publish-components: release tag: components-90a9719c5e9e
```

## Rows run, and what they said

No full suite was run (the G-wave rule). Run singly: `scripts/test-component-lock-rebuild.sh` (base red,
branch green - above), `scripts/test-component-pins.sh` (exit 0: 6 of 11 verified against a private copy of
the bytes, 5 `SKIP … no reachable copy` for the newly pinned names - correct until a bundle exists),
`scripts/test-publish-shared-commit.sh` (43 checks, 0 failed), `scripts/test-deploy-components.sh` (74
checks, ok), `scripts/test-repro-components.sh` (green: `ok: 2 component(s) reproduce byte for byte from two
checkout paths` - `svc-echo` `f841ec2f…` 191,647 bytes and `graph` `4e907b1f…` 8,187,401 bytes from two
differently named paths, no path leaked, and `graph` is the one with C inside AND a path dependency),
`scripts/test-devloop.sh` (22 checks, 0 skipped), `scripts/test-discriminates.sh` (the land gate's own
check of this branch: `discriminates scripts/test-component-lock-rebuild.sh`, 1 discriminating, 0 blocking).

Two rows are RED and are **pre-existing on the base**, verified by running them in a tree extracted from
`0d8657e5`:

* `scripts/test-deploy-components-shipped.sh`: `components.lock pins '… wa-whatsapp', expected '… wa-email'`
  - the test's expected set stops at ten names and the lock has pinned `wa-whatsapp` since 15/11. Same
  failure, same text, on the base. Not touched here.
* `scripts/test-install-guards.sh`: 72 checks, 6 failed, all six because `upgrade` refuses inside a turn
  running on the node it would replace; identical on the base. Environment of the run, not this change.

## What is still open

* **No bundle exists for the new lock.** The lock's sha256 is now `90a9719c5e9ee8f65ef7166d498993249b1a851c04b3e8957a1d0408bae487bc`,
  so the release tag is `components-90a9719c5e9e`, and `components-fbe95281b2ce` names the old pins. A deploy
  of main after this lands needs that bundle published (`scripts/publish-components.sh` prints the exact
  `gh release create` line) or it fails `component_release_unavailable`. Publishing is a release action and
  was out of scope for this branch. This also means `test-component-pins.sh` half 2 SKIPs five names until
  then - a release gate with `WA_PIN_CHECK_REQUIRE=1` will be red for exactly that reason, and the fix is
  the publish, not a code change.
* **Half 1 did not notice the stale source pins** (graph, wa-email, wa-whatsapp). Repinning them here makes
  the lock true again, but whatever let three components' sources change on main without their lines moving
  is still there. Not investigated, not fixed.
* Nothing on the node's own install (`~/.wasm-agent/components`, which still holds the old bytes) was
  touched; no fleet node, no release, no key material, and the malformed graph DB was not touched.

## Texts to approve

1. `component toolchain: rustc 1.99.1 (58cf8f9c3 2026-10-13) (pinned: 1.99.1); wasi-sdk: 34.0`
2. `component build root: /tmp/wa-component-build/src`
3. `publish-components: all 11 match components.lock`
4. `error: component builds are pinned to rustc 1.99.1 (components.lock) and rustup is not on PATH; install rustup, or WA_COMPONENT_TOOLCHAIN=node for a build whose bytes are not the pinned ones`
5. `component toolchain 1.99.1 is not installed; fetching it (rustup toolchain install, with both wasm targets)`
6. `error: cannot install rustc 1.99.1 (offline?); the pinned component bytes need it`
7. `error: WA_COMPONENT_BUILD_ROOT (…) is inside this checkout; the build root must live outside the tree it copies`
8. `error: cannot copy this tree into …` / `error: cannot enter the build root …`
9. `lock-rebuild: match <name>: <sha256> (<bytes> bytes)`
10. `lock-rebuild: DRIFT <name>: built <sha256> (<n> bytes); components.lock pins <sha256> (<n> bytes)`
11. `lock-rebuild: PATH LEAK <name>: <path> is inside the artifact`
12. `lock-rebuild: PARITY <name>: with the constant build root <sha>, built in the checkout <sha> - the copy is an input, not a location`
13. `lock-rebuild: PARITY <name> NOT MEASURED: WA_COMPONENT_STABLE_ROOT=0 build failed - the copy-is-not-an-input property is unproven on this run`
14. `lock-rebuild: <n> problem(s) over <n> measured component(s). A drifted line is either a source change (the pin is stale: repin it from this build with scripts/publish-components.sh), a compiler that is not the pinned one (components.lock, "HOW THESE LINES ARE REPRODUCED"), or a path that reached the bytes. Never edit the line to match: find out which of the three it is.`
15. `lock-rebuild: ok: <n> of <n> pinned component(s) build to their own line in components.lock`
16. `lock-rebuild: refusing_to_write_the_real_component_directory: <dir>`
17. `lock-rebuild: build_failed: …` / `lock-rebuild: artifact_missing: …` / `lock-rebuild: component_not_pinned: …`

The rest of the new text is comments in `scripts/build-components.sh`, `scripts/publish-components.sh`,
`components.lock` and `docs/COMPONENTS.md`, and the row's own comments in `scripts/test.sh`.

## What the brief asked that is NOT done, plainly

* No test was added to `scripts/fast.sh`: the check needs wasi-sdk and minutes and the brief's suite rule
  forbids a heavier fast path. It is in `scripts/test.sh` instead (rule 3's "wire it somewhere" is
  `scripts/test.sh:580`).
* No factory script was edited, and none needs to be: nothing outside this tree reads or writes the build
  root.

