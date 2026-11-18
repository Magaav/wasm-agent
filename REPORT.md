# release-glibc - a release binary never needs a newer glibc than the fleet has

Branch `change/release-glibc` in this worktree (`/home/victor/Work/missions/release-glibc/wt`), based on
`origin/main`. Built and tested HERE (avell, x86_64, 16 cores, host glibc 2.44). Committed locally; **never
pushed, never published**.

## What landed, per item of the mission

### 1. Build: a fixed glibc floor, read back out of the artifact

Already the shape of the build before this change: `scripts/publish-node-binaries.sh` builds both Linux
targets with `cargo zigbuild --release --offline --locked --target <triple>.2.31` (`GLIBC_FLOOR="2.31"`).
What changed:

- the read-back is now one shared function, `wa_glibc_max_symbol` (`scripts/lib/glibc-floor.sh`), instead
  of a private copy of the scan, so the publisher and the three installers cannot disagree about the same
  bytes (a test asserts there is no second copy);
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
| `wa_glibc_covers <have> <need>` | version comparison; empty argument is never "satisfied" |
| `wa_glibc_guard <file> [label]` | 0 when this host can run it (or the question cannot be asked here), **3** with the refusal sentence when it cannot |

Wired in, each at the last point where the answer is still cheap and the swap has not happened:

- `scripts/fleet-install.sh` - after the download and its sha256/signature, **before** the exec test, the
  `.prev` backup and the swap. A copy of the script without its lib refuses by name
  (`glibc_floor_lib_missing`) rather than installing blind.
- `scripts/upgrade.sh` - after the signature gate, **before** the scratch proof, the `.pre-upgrade` backup
  and the swap (exit 3).
- `scripts/deploy.sh` - **before** the prove phase, for the node binary **and** the supervisor (a sentinel
  that cannot start cannot roll a node back either). The lib is added to deploy.sh's sourcing loop and
  shipped beside an installed copy, because `request deploy` runs the INSTALLED deploy.sh.

The message names both versions and where the host's came from:

    glibc_floor_exceeded: wa needs GLIBC_2.39 and this host has glibc 2.35 (ldd --version), so it was
    refused before anything was replaced and the installed binary was left alone. ...

### 3. Docs

`docs/INSTALL.md` has a new section, "The glibc floor: what a release binary may need, and what a host must
have": the floor and where it comes from, the incident, the **measured fleet** table, the three refusal
points with what each leaves behind, the sentence itself, the musl/non-Linux "unknown" rule, and what a host
below the floor can install instead (a lower `--glibc`, or the static musl bundle). `docs/COMPONENTS.md`
names the shared function and the install side in its existing glibc paragraph.

Measured fleet (read-only probes, 19/11 - `ldd --version` on each host plus the newest `GLIBC_` symbol in
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

`bash scripts/test-glibc-floor.sh` -> **glibc floor ok (52 checks)**, hermetic (no network, node, cargo or
zig; fixture ELFs, `WA_GLIBC_HOST` for the host probe). It pins:

- the measurement: `2.2.5/2.17/2.31 -> 2.31`; `2.2.5` alone reads `2.2.5`; `2.31` covers `2.2.5`;
  `2.35` does **not** cover `2.39`; an empty host version is never "satisfied"; a file with no glibc
  symbol answers nothing; a missing file is not measured;
- the sentence: `glibc_floor_exceeded:`, `needs GLIBC_2.39`, `has glibc 2.35`, `installed binary was left
  alone`; and no refusal when the need is <= the host's;
- `fleet-install.sh` with a fixture needing 2.39 on a 2.35 host: exit 1, both versions in the output, and
  **the installed binary byte-identical, no `wa.prev.*`**; the same fixture at 2.31 gets *past* the floor
  step and stops at the exec test instead (so the guard is not a blanket refusal); a copy of the script
  without `scripts/lib/glibc-floor.sh` refuses with `glibc_floor_lib_missing` and replaces nothing;
- `upgrade.sh` with a 2.39 candidate: exit 3, both versions, installed binary unchanged and **no
  `wa.pre-upgrade` backup** (the refusal really is before the backup);
- the order in the source: in `deploy.sh` the guard's line is before `wa_phase proving` and before
  `bash "$UPGRADE" "$CANDIDATE"`; in `upgrade.sh` it is before the scratch proof, the backup and the swap;
  the lib is in deploy.sh's sourcing loop and is shipped beside an installed copy;
- the publish half measures with the same function, no second copy of the scan exists in `scripts/`, and a
  malformed `--glibc` is refused by name.

Registered in `scripts/test.sh` (`gate_run bash scripts/test-glibc-floor.sh`, next to the two node-binary
suites).

## Tests run, and the pre-existing failures I did not cause

| suite | this branch | base (`git stash`, commit 74d48431) |
| --- | --- | --- |
| `scripts/test-glibc-floor.sh` | **ok, 52 checks** | n/a (new) |
| `scripts/test-node-binaries.sh` | ok 68 checks, then FAIL | ok 68 checks, then FAIL - **same failure** |
| `scripts/test-deploy-node-binaries.sh` | FAIL | **same failure** |

Pre-existing, verified identical on the base:

1. `test-node-binaries.sh`: after 68 passing checks, "the plan names the binary cargo-zigbuild will use"
   fails because the suite's fixture tree does not carry `scripts/lib/build-target.sh`, which
   `publish-node-binaries.sh` sources when no `--target-dir` is given (`line 179: ... No such file or
   directory`, present at the same line on the base).
2. `test-deploy-node-binaries.sh`: "the installed prebuilt supervisor is not executable".

## Deliberately not done / not verified

- **Not pushed, not published.** Two local commits: `936880f9` (the change) and `aee61a3c` (test file mode).
- **The install guards were not run against a live node.** `upgrade.sh`/`deploy.sh` would restart the node
  this session runs on, so the behavioural proof for them is the fixture run in `upgrade.sh`'s case plus the
  structural order checks; `fleet-install.sh`'s refusal is proved end to end (it downloads, refuses and
  leaves the target untouched).
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
