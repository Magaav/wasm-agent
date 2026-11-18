# release-glibc - a release binary never needs a newer glibc than the fleet has

Branch `change/release-glibc` in this worktree (`/home/victor/Work/missions/release-glibc/wt`), based on
`origin/main`. Built and tested HERE (avell, x86_64, 16 cores, host glibc 2.44). Committed locally; **never
pushed, never published**.

## Round 3 - the verification review's two nits (verdict: land)

| # | finding | where it was | what changed |
| --- | --- | --- | --- |
| 1 | under `curl \| bash` `$0` is `bash`, so the lib lookup resolved to `./lib/glibc-floor.sh` and SOURCED a file in the caller's working directory | `scripts/fleet-install.sh` 209-212 | the lookup is removed: the script sources no lib at all, and a test plants `./lib/glibc-floor.sh` in the cwd and proves it is never read |
| 2 | the test asserted one guard block for the lib only | `scripts/test-glibc-floor.sh` section 8 | both files are now proved to carry exactly one begin/end pair |

### 1. The hole, measured before and after

The old line, run by hand in a directory holding a planted `lib/glibc-floor.sh`:

    cd $d && WA_GLIBC_HOST=2.35 TARGET=$d/bin/wa bash -s "file://$d/art/newer" < fleet-install.sh

- **3b01caea**: the plant printed `PLANTED: the cwd lib was sourced`, its `wa_glibc_guard` (return 0)
  replaced the real one, and the run went straight past the floor check to the exec test - a **2.39**
  artifact on a declared **2.35** host, unrefused. That is the guard off, silently, in exactly the shape the
  fleet install is handed out in;
- **8d98aa11**: no plant line, `glibc_floor_exceeded` with both versions named, the target bytes untouched.

Removed rather than narrowed on purpose: resolving $0/BASH_SOURCE leaves the same hole for `bash
fleet-install.sh` (a bare relative path) and for a bare name on PATH, and there is nothing to gain from the
source at all - the block in the script is the lib's text byte for byte and the suite fails on one differing
line, so sourcing it on top was either a no-op or a bug.

### 2. The two tests, failing before and passing after

- suite: **109 checks** (113 with the four built artifacts from round 2, still on disk), against 96 (100) on
  3b01caea;
- **mutation 1** - the 3b01caea `fleet-install.sh` put back under the new test:
  `glibc floor FAILED: the planted ./lib/glibc-floor.sh was NOT sourced under bash -s: 'PLANTED_LIB_SOURCED'
  unexpectedly in: PLANTED_LIB_SOURCED: a cwd lib was sourced by fleet-install.sh`;
- **mutation 2** - a second `# wa-glibc-floor-begin` / `# wa-glibc-floor-end` pair appended to `fleet-install.sh`:
  `glibc floor FAILED: scripts/fleet-install.sh carries 2 wa-glibc-floor blocks, not 1`;
- both new cases run in the two shapes a node gets (`bash -s`, the pipe, and `bash fleet-install.sh`, a bare
  relative path), the plant is asserted to exist before the case runs (`[ -s ]`, so the check cannot pass for
  want of a fixture), and the planted file speaks **at source time**, so being read at all is the failure
  whatever order the definitions would have made of the functions.

### Also measured, not changed (outside the two nits)

`scripts/upgrade.sh` 34-37 carries the same cwd-relative fallback (`$(dirname "$0")/lib/glibc-floor.sh`,
and `$(dirname "$0")/lib/turn-guard.sh` beside it). It is not piped from curl - it runs from a checkout or an
install directory - so the hole is not reachable the way the fleet install's was, and closing it needs a
decision about how an installed copy finds its libs. Left as it is and named here rather than changed
unreviewed on the last round.

### Not verified / not done (round 3)

- **not pushed**: one local commit, `8d98aa11`, plus this report's commit. Nothing was published.
- the fleet install was **not run against a live node** (it would restart the node this session runs on): the
  refusal is proved end to end with fixture artifacts, which is what the suite does for every installer but
  `deploy.sh`/`upgrade.sh`, whose blocks are read out of the files and run.
- the full `scripts/test.sh` gate was not run in this round; the suite this change touches was, plus the two
  mutations above.

## Round 2 - the independent review of a9b60cc9: four findings, four changes

| # | finding | where it was | what changed |
| --- | --- | --- | --- |
| 1 | the deploy guard ran after the candidate had already been executed, so a too-new binary died on the digest error and `glibc_floor_exceeded` was never said | `scripts/deploy.sh`, block at 1137-1154, first execution at 1010 | the block moved to 1021-1033, right after `NEW`/`NEW_SENTINEL` are final and before `--capability-digest` at 1040 |
| 2 | `fleet-install.sh` refused without the lib beside it (`glibc_floor_lib_missing`), so the copy a node gets over `curl` could not check anything | `scripts/fleet-install.sh` 50-57 | the four functions travel inside the script, between `wa-glibc-floor` markers, and the test diffs them against the lib byte for byte |
| 3 | `sort -V` was a hidden dependency: without it the comparison answered "not covered" and refused binaries the host can run | `wa_glibc_covers` | the order is measured, never assumed; an unorderable comparison answers 2 = unknown, which allows with a printed `glibc_floor_unknown:` note, like musl |
| 4 | the byte scan counts any `GLIBC_x.y` string in the file (note only, no code) | `wa_glibc_max_symbol` | nothing in the scan; a test now compares it with `readelf -V`'s `.gnu.version_r`, on real linked binaries and on the four built artifacts |

### 1. deploy.sh: the guard is before the FIRST execution of the candidate

The candidate is executed four times before it is installed: `--capability-digest` (1010 on a9b60cc9),
`--lua-tree` (1052), the graph proof (1127), the embedded-runtime proof (1178). The guard was at 1144-1154,
so on a host older than the bytes need, the deploy died at 1011 with `the binary being installed cannot
state its capability digest` - a sentence that blames the artifact and hides the one refusal an operator can
act on (publish this commit with a lower floor). It is now at 1021-1033: after `NEW`/`NEW_SENTINEL` are
final on all three paths (Lua fast 592/593, published 668/669, built 981-993), before line 1040. The block
carries `wa-deploy-glibc-guard: begin/end` markers.

- **before (a9b60cc9)**: guard call at line **1148**, first `"$NEW" --...` at **1010**; the test's ordering
  assertion fails there (and the marker assertion too, the base has no markers);
- **now**: begin 1021, end 1033, call 1026, first execution 1040 - guard end < first execution;
- **mutation** (the guard block moved back below the digest check in a copy of the fixed file): the
  assertion fires with `guard_end=1042 > first_exec=1027`, so the test catches the defect it names;
- **behaviour**: the block, read out of `deploy.sh` by its markers and RUN (`fail`/`note` stubbed, the real
  lib): a 2.39 fixture on a `WA_GLIBC_HOST=2.35` host exits 9 with `refused(glibc_floor_exceeded)`, names
  both versions, and does not print `capability digest`; the same block passes a 2.31 candidate; a 2.39
  **supervisor** is refused too; with no lib beside it the block notes that the floor was not measured;
- **not proved**: `deploy.sh` end to end - it would build, swap and restart the node this session runs on.
  What runs is its own block, plus the line assertions on the file.

### 2. fleet-install.sh is self-contained, and the copy is proved to be the lib's

The four functions (`wa_glibc_max_symbol`, `wa_glibc_sort_orders_versions`, `wa_glibc_covers`,
`wa_glibc_host_version`, `wa_glibc_guard`) sit between `# wa-glibc-floor-begin` and `# wa-glibc-floor-end`
in `scripts/lib/glibc-floor.sh`, and the same 150 lines sit in `scripts/fleet-install.sh`. A shipped install
still has the lib beside it and sources it on top, so a fix to the lib reaches the script; the inline copy is
what a standalone copy runs. `scripts/test-glibc-floor.sh` extracts both blocks by their markers and
`diff`s them (empty now), and the "no second copy of the scan" grep allows exactly this one, by name.

- **before**: a copy of `fleet-install.sh` with no `lib/` beside it refused every install with
  `glibc_floor_lib_missing` - reproduced by the new test on the base tree:
  `glibc floor FAILED: the standalone copy makes the floor check itself: 'glibc_floor_exceeded:' not in:
  fleet-install: glibc_floor_lib_missing: .../lonely/lib/glibc-floor.sh`;
- **now**: that copy refuses the 2.39 fixture with `glibc_floor_exceeded`, names both versions, leaves the
  installed binary byte-identical, and lets a 2.31 fixture through to the exec test (so it is a check, not a
  blanket refusal).

### 3. `sort -V` is measured, and its absence is "unknown", not "refused"

A host can be without version order two ways, and the test stubs both: a busybox `sort` REJECTS `-V` (every
pipeline answers nothing), and a `sort` that ignores the flag silently answers byte order (2.9 above 2.10).
`wa_glibc_sort_orders_versions` probes the ordering `2.9 < 2.10` - a pair a byte sort gets wrong, unlike
`2.2.5` vs `2.31`, which it happens to get right - and `wa_glibc_covers` answers **2 = unknown** when the
probe fails. `wa_glibc_guard` prints `glibc_floor_unknown:` on stderr and returns 0; the refusal is
reserved for a comparison that actually happened.

- **before**: with a `sort` that rejects `-V`, `wa_glibc_covers 2.35 2.39` answered **1** ("not covered");
  with a `sort` that answers the scan and then fails, the guard **refused** a 2.39 artifact on a 2.35 host
  (`rc 3`, `glibc_floor_exceeded`) - a refusal about a comparison that was never made;
- **now**: `2` and an allow with the note in both cases; and `wa_glibc_max_symbol` says
  `glibc_floor_unknown: ... this host's sort cannot order them` instead of answering silence (the publisher
  reads it too, and used to print nothing and skip its own check);
- **not weakened**: a host WITH version order still refuses 2.39 on 2.35 (sections 1-2 of the test).

### 4. The scan against the ELF's own answer (note only - no code)

The scan counts any `GLIBC_x.y` string in the file, so a doc string or an embedded copy of another binary's
floor would be read as a floor these bytes do not have, and a host below it would refuse a binary it can
run. The brief asked for a test, not a rewrite, and that is what it got: the scan is compared with
`readelf -V`'s `.gnu.version_r` (what the loader actually enforces) on `/bin/true` (2.34), `/bin/ls` (2.38),
`sort`, and - with `WA_GLIBC_ARTIFACT_DIR` - on each of the four artifacts built in this mission
(2.30 each, 26/21/11/10 version needs). It passes on the base as well: it is a guarantee to keep, not a
defect fixed. `readelf` absent on a host means a printed SKIP, not a silent pass.

## What landed, per item of the mission

### 1. Build: a fixed glibc floor, read back out of the artifact

Already the shape of the build before this change: `scripts/publish-node-binaries.sh` builds both Linux
targets with `cargo zigbuild --release --offline --locked --target <triple>.2.31` (`GLIBC_FLOOR="2.31"`).
What changed:

- the read-back is now one shared function, `wa_glibc_max_symbol` (`scripts/lib/glibc-floor.sh`), instead
  of a private copy of the scan, so the publisher and the three installers cannot disagree about the same
  bytes (a test asserts there is no other copy but the one `scripts/fleet-install.sh` carries, and diffs
  that one against the lib byte for byte - round 2, item 2);
- the read-back is **version**-ordered: `GLIBC_2.2.5` (the base every x86_64/aarch64 build needs) now
  sorts *below* `GLIBC_2.31`. The old expression (`grep 'GLIBC_2\.[0-9]\+'` + `sort -uV`) reported
  `2.2` for it, which is a different version string than any loader prints;
- the refusal above the floor is unchanged in behaviour (`glibc_floor_exceeded`, exit 5) and now also
  refuses a **malformed** `--glibc` (`glibc_floor_malformed`, exit 2) - `2.3l` used to be accepted by
  a loose glob and would have produced a cargo-zigbuild target name zig does not know.

The publish step still measures every artifact (wa **and** wa-sentinel, both targets) and refuses to
publish above the floor; see the measured table below.

### 2. Install: all three installers refuse before the swap, with both versions

New `scripts/lib/glibc-floor.sh` (one measurement, one sentence):

| function | answer |
| --- | --- |
| `wa_glibc_max_symbol <file>` | newest `GLIBC_<version>` in the bytes (a byte scan, not `objdump -T`, because a publisher reads artifacts of the *other* architecture and a host `objdump` may not know a foreign machine) |
| `wa_glibc_host_version` | `ldd --version` first line, `getconf GNU_LIBC_VERSION` as the fallback; **"unknown"** on musl (`WA_GLIBC_HOST` stands in for the probe in fixtures only) |
| `wa_glibc_covers <have> <need>` | version comparison; an empty argument, or a host whose `sort` cannot order versions, answers **2 = unknown** - never "satisfied" and never "refused" (round 2, item 3) |
| `wa_glibc_guard <file> [label]` | 0 when this host can run it (or the question cannot be asked here), **3** with the refusal sentence when it cannot |

Wired in, each at the last point where the answer is still cheap and the swap has not happened:

- `scripts/fleet-install.sh` - after the download and its sha256/signature, **before** the exec test, the
  `.prev` backup and the swap. The script carries the four functions itself, so the copy a node gets from
  `curl` makes the check too; before that it refused with `glibc_floor_lib_missing` (round 2, item 2).
- `scripts/upgrade.sh` - after the signature gate, **before** the scratch proof, the `.pre-upgrade` backup
  and the swap (exit 3).
- `scripts/deploy.sh` - **before it executes the candidate at all** (`--capability-digest`, `--lua-tree`
  and the graph proof all run it), for the node binary **and** the supervisor (a sentinel that cannot start
  cannot roll a node back either); round 2, item 1 moved it there. The lib is added to deploy.sh's sourcing
  loop and shipped beside an installed copy, because `request deploy` runs the INSTALLED deploy.sh.

The message names both versions and where the host's came from:

    glibc_floor_exceeded: wa needs GLIBC_2.39 and this host has glibc 2.35 (ldd --version), so it was
    refused before anything was replaced and the installed binary was left alone. ...

### 3. Docs

`docs/INSTALL.md` has a new section, "The glibc floor: what a release binary may need, and what a host must
have": the floor and where it comes from, the incident, the **measured fleet** table, the three refusal
points with what each leaves behind, the sentence itself, the musl/non-Linux "unknown" rule, and what a host
below the floor can install instead (a lower `--glibc`, or the static musl bundle). `docs/COMPONENTS.md`
names the shared function and the install side in its existing glibc paragraph.

Measured fleet (read-only probes, 18/11 - `ldd --version` on each host plus the newest `GLIBC_` symbol in
the `wa` each host runs; no build, no code synced to a peer):

| host | arch / OS | glibc | installed `wa` (commit) needs | runs a 2.31-floor binary |
| --- | --- | --- | --- | --- |
| avell (this node) | x86_64, Arch | 2.44 | GLIBC_2.30 (built here) | yes |
| openclaw | aarch64, Ubuntu 24.04 | 2.39 | GLIBC_2.30 (14963b6f) | yes |
| mail | aarch64, Ubuntu 22.04 | 2.35 | GLIBC_2.30 (14963b6f) | yes |
| nextcloud | - | not measured (node offline) | - | unknown; the brief's "git 2.25 era" is **below** the floor |

## Proof

### A. A built artifact's max symbol is <= the floor (a real cross build here)

    WA_ZIG=/home/victor/wasm-agent/toolchain/zig/zig \
    bash scripts/publish-node-binaries.sh --local --allow-empty-codemode \
      --target-dir /home/victor/wasm-agent/target/m-release-glibc \
      --out /home/victor/Work/missions/release-glibc/node-binaries-proof

zig 0.17.1, cargo-zigbuild 0.24.1, commit 936880f9, floor 2.31. Build: aarch64 in 223 s, x86_64 in 169 s
(392 s total). The publisher's own read-back, and then an independent measurement (`wa_glibc_max_symbol`
**and** `objdump -T`, which agree):

| artifact | max GLIBC symbol | bytes | sha256 (first 16) |
| --- | --- | --- | --- |
| wa-aarch64-unknown-linux-gnu-936880f9292c | **2.30** | 44,956,448 | 45f8bc54e0f23c2e |
| wa-sentinel-aarch64-unknown-linux-gnu-936880f9292c | **2.30** | 5,400,192 | f2c4f5ae1d806df5 |
| wa-x86_64-unknown-linux-gnu-936880f9292c | **2.30** | 52,195,704 | a896269012568c45 |
| wa-sentinel-x86_64-unknown-linux-gnu-936880f9292c | **2.30** | 5,936,896 | d0ee8b07490c952a |

All four are <= 2.31, so they run on every host in the table above (2.39, 2.44) and on the 2.35 node the
incident happened on. The x86_64 pair was additionally **executed** here (`ran x86_64-unknown-linux-gnu
natively: wa --version answered`); the aarch64 row is reported `run: SKIPPED` because this host cannot
execute it, which is the publisher's own honest gate.

The same guard, both ways, on those real bytes: host 2.44 -> rc 0; `WA_GLIBC_HOST=2.29` -> rc 3 with
"needs GLIBC_2.30 and this host has glibc 2.29".

**What this run did NOT do**: it stopped at the signing step (`release_not_signed`, exit 6) because there
is no wa-vault admin token on this host. Nothing was published, nothing was pushed, no release exists. The
artifacts stay in `/home/victor/Work/missions/release-glibc/node-binaries-proof` (outside the worktree).

### B. A binary that needs a newer glibc is refused at install (the test)

`bash scripts/test-glibc-floor.sh` -> **glibc floor ok (96 checks)** - **100** with
`WA_GLIBC_ARTIFACT_DIR=/home/victor/Work/missions/release-glibc/node-binaries-proof` - hermetic (no network,
node, cargo or zig; fixture ELFs, `WA_GLIBC_HOST` for the host probe). It pins:

- the measurement: `2.2.5/2.17/2.31 -> 2.31`; `2.2.5` alone reads `2.2.5`; `2.31` covers `2.2.5`;
  `2.35` does **not** cover `2.39`; an empty host version is never "satisfied"; a file with no glibc
  symbol answers nothing; a missing file is not measured;
- the sentence: `glibc_floor_exceeded:`, `needs GLIBC_2.39`, `has glibc 2.35`, `installed binary was left
  alone`; and no refusal when the need is <= the host's;
- `fleet-install.sh` with a fixture needing 2.39 on a 2.35 host: exit 1, both versions in the output, and
  **the installed binary byte-identical, no `wa.prev.*`**; the same fixture at 2.31 gets *past* the floor
  step and stops at the exec test instead (so the guard is not a blanket refusal); **a copy of the script
  with no lib beside it makes that same check** (and lets a 2.31 artifact through) - round 2, item 2;
- `upgrade.sh` with a 2.39 candidate: exit 3, both versions, installed binary unchanged and **no
  `wa.pre-upgrade` backup** (the refusal really is before the backup);
- `deploy.sh`: the guard block, **read out of the script by its markers and run** against fixtures, refuses
  a 2.39 candidate with `refused(glibc_floor_exceeded)` and not with the old digest error, passes a 2.31 one,
  guards the supervisor too, and degrades to a note when the lib is absent; its line is before the first
  `"$NEW" --...`, before `wa_phase proving`, before `bash "$UPGRADE" "$CANDIDATE"`, and after all three
  assignments of `NEW`/`NEW_SENTINEL` - round 2, item 1;
- a host whose `sort` has no `-V`, or ignores it, or answers only the first comparisons it is asked: the
  measurement says `glibc_floor_unknown:` and the bytes are allowed through, the comparison answers 2 and
  not 1, and nothing is refused - round 2, item 3;
- the two copies of the four functions (`scripts/lib/glibc-floor.sh`, `scripts/fleet-install.sh`) are
  identical byte for byte, and the lib holds exactly one such block - round 2, item 2;
- the byte scan equals `readelf -V`'s `.gnu.version_r` maximum on `/bin/true`, `/bin/ls`, `sort` and, when
  `WA_GLIBC_ARTIFACT_DIR` names it, on each of the four built artifacts - round 2, item 4;
- the publish half measures with the same function, no third copy of the scan exists in `scripts/`, and a
  malformed `--glibc` is refused by name.

Registered in `scripts/test.sh` (`gate_run bash scripts/test-glibc-floor.sh`, next to the two node-binary
suites).

## Tests run, and the pre-existing failures I did not cause

| suite | this branch | base (`git stash`, a9b60cc9) |
| --- | --- | --- |
| `scripts/test-glibc-floor.sh` | **ok, 96 checks** (100 with the artifacts) | n/a (new) |
| `scripts/test-node-binaries.sh` | 68 checks, then FAIL | 68 checks, then FAIL - **same failure** |
| `scripts/test-deploy-node-binaries.sh` | FAIL | **same failure** |
| `scripts/test-deploy-preconditions.sh` | FAIL | **same failure** |
| `scripts/test-deploy-record.sh` | FAIL | **same failure** |
| `scripts/test-deploy-gate-policy.sh` | ok, 8 checks | ok |
| `scripts/test-deploy-policy-order.sh` | ok, 8 checks | ok |
| `scripts/test-deploy-ship.sh` | ALL PASS | ALL PASS |

Pre-existing, verified identical on the base (`git stash push` of this branch, same suite, same message):

1. `test-node-binaries.sh`: after 68 passing checks, "the plan names the binary cargo-zigbuild will use"
   fails because the suite's fixture tree does not carry `scripts/lib/build-target.sh`, which
   `publish-node-binaries.sh` sources when no `--target-dir` is given (`line 179: ... No such file or
   directory`, present at the same line on the base).
2. `test-deploy-node-binaries.sh`: "the installed prebuilt supervisor is not executable".
3. `test-deploy-preconditions.sh`: "the WSL shell was not refused by name" (its `--wsl` fixture's deploy.log
   path does not exist: `deploy.sh: line 159: .../home-wsl/AppData/Local/wasm-agent/deploy.log: No such file
   or directory`). Not touched by this round: the line moved only because `deploy.sh` grew the guard.
4. `test-deploy-record.sh`: "the record step refused: status 1 - .../run-record.sh: line 44: ROOT: unbound
   variable" (`ROOT` is unset in the extracted record block on both trees).

## Deliberately not done / not verified

- **Not pushed, not published.** Four local commits: `936880f9`, `aee61a3c` (round 1) and the two round-2
  ones (`scripts/deploy.sh` + the lib + docs, and the test).
- **The install guards were not run against a live node.** `upgrade.sh`/`deploy.sh` would restart the node
  this session runs on, so the behavioural proof for them is the fixture run in `upgrade.sh`'s case, the
  deploy guard block read out of `deploy.sh` and run against fixtures (round 2, item 1), plus the line
  assertions on the files; `fleet-install.sh`'s refusal is proved end to end (it downloads, refuses and
  leaves the target untouched).
- **`deploy.sh` and `upgrade.sh` still require the lib beside them** (and a deploy ships it): only
  `fleet-install.sh` is handed out as a single file, so only it carries its own copy. Giving a deploy a copy
  would double 150 lines for a path that always ships `scripts/lib/` next to itself.
- **Deploying this branch** would be the first live exercise of the deploy/upgrade paths; the guard is
  additive and runs before every existing gate, so a missing lib degrades to a loud note plus the existing
  exec/health proof rather than to a skipped install.
- **nextcloud could not be measured** (offline during this work). If its glibc really is 2.25-era, it is
  *below* the 2.31 floor: the install guard refuses by name and it keeps its current binary. Publishing that
  host a binary means `--glibc 2.27` (or the static musl bundle) - a policy decision I did not take.
- **The incident's 2.39 bytes are not on either node now**: mail and openclaw both run commit `14963b6f`
  and those bytes measure GLIBC_2.30, so the exact artifact from 18/11 was replaced before this work; the
  claim that a 2.39 build was installed is the brief's, not something I could re-measure.
- The full `scripts/test.sh` gate was not run (it is the landing's job); the three suites above plus the
  new one are what this change touches.
- `scripts/linux/bootstrap.sh` (the bundle channel) keeps its `candidate_does_not_run` exec refusal and was
  left as it is: it is outside the three installers the mission named, and its bundles are chosen per libc
  from `releases/index-linux.json`.
