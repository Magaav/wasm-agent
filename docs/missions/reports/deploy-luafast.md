# change/deploy-luafast - a Lua-only deploy names both commits and stops refusing itself

Base: origin/main 93168d96 (land260). Branch `change/deploy-luafast`. **Committed locally, not pushed.**

Commits: `4fb06aa5` (scripts/deploy.sh, scripts/test-deploy-luafast-record.sh, scripts/test.sh), `723dc560`
(this report and the docs/COMPONENTS.md sentence), `12b04afe` (round 2: the `install-record` row, below).

## The failure, re-measured before any code was written

Every premise in the brief was checked against 93168d96 in this worktree. None was stale:

- `scripts/lib/install-record.sh:282-289` - `wa_running_identity` reads the binary's `--build-info` and
  `return 0`s at line 289 as soon as the binary names its commit, so `WA_RUNNING_RECORD_COMMIT` (assigned at
  line 295, further down) is never filled in that case. CONFIRMED.
- `scripts/deploy.sh:604` - `INSTALLED_COMMIT="$WA_RUNNING_RECORD_COMMIT"`, i.e. `""` whenever the binary can
  answer. CONFIRMED.
- At 93168d96, `scripts/deploy.sh:769-770` were
  `INSTALLED_BINARY_COMMIT="$(sed -n 's/^binary_commit=//p' ...)"` / `[ -n ... ] || INSTALLED_BINARY_COMMIT="$INSTALLED_COMMIT"`.
  A FULL install writes no `binary_commit=` (it is written only when `LUA_FAST=1`), so the first Lua-only
  deploy after a full install always had `INSTALLED_BINARY_COMMIT=""`. CONFIRMED.
- `scripts/deploy.sh:1768` then left `record_expected="$COMMIT"` (the new target) while `record_commit` came
  from the kept binary's own answer, and `scripts/deploy.sh:1784` refused. CONFIRMED, and reproduced in a
  fixture against the base commit (see "Discrimination" below):

  `deploy: refused(build_commit_mismatch): the binary installed at .../install-full-then-lua/wa reports commit 97251587b3a3 but this deploy meant to install a5d8c6167965`

One thing the brief did not name, and it decides the shape of the fix: `commit=` is not only compared inside
`record_installed`. It is what `lua/core/update.lua` (the one Lua reader of `installed.txt`) and
`scripts/verify-deployed.sh:111-121` compare with `origin/main` / the expected commit. Writing the KEPT
BINARY's commit there - which is what the fast path did while it still worked - makes a Lua-only install look
N commits behind main for ever, and `scripts/lib/node-binaries.sh:173` (rule 2 of the reuse decision) starts
its diff from it. So the record has to name the two facts separately; that split already exists in this
repository for the digest-fallback prebuilt install, and docs/COMPONENTS.md:299-305 now states it for the
fast path too.

## What changed (commit 4fb06aa5)

1. **`scripts/deploy.sh:768-814`** - the commit of the binary this deploy KEEPS is resolved in the order of
   evidence: (a) the binary itself whenever it answers `--build-info`, and likewise `RUNNING_SOURCE=record`,
   which install-record.sh only says after `wa_record_describes` proved the record's `sha256=` IS these bytes;
   (b) `binary_commit=` from the record, with `unknown` blanked (it is not an id); (c) nothing - and then
   `binary_commit=unknown` is written rather than a guess. `commit=` of a FAST-PATH record is never read as
   the binary's commit (`lua_fast_path=1` in the record plus `RUNNING_SOURCE=record` blanks that path
   explicitly, deploy.sh:799-806). A record that disagrees with a binary that can answer is now a recorded
   note, not a refusal - nothing is replaced on a fast path, so there is nothing to refuse.
2. **`record_installed`** - for `LUA_FAST=1`, `commit=` is `$COMMIT`, the Lua tree this deploy installed
   (deploy.sh:1833-1844); `record_expected` is still the kept binary's commit (deploy.sh:1812), so the
   mismatch check is now about the bytes this deploy KEPT, which is the only thing it can be about when no
   binary is installed; the `commit=unknown` note applies to a build only (deploy.sh:1823-1829); and the fast
   path writes `binary_commit=unknown` plus `binary_commit_why=` instead of `binary_commit=` with nothing
   after it (deploy.sh:1928-1942).
3. **The other users of `INSTALLED_COMMIT`** (the brief asked for them by name). There were three, and the
   third one - the fallback at line 770 - is now gone. The two that remain are messages in the
   `record_mismatch` branch, and BOTH had the same empty-value hole, reachable because `record_mismatch` needs
   only `sha256 != the binary's`, not a `commit=` in the record: `deploy.sh:616` printed
   "the record's commit= describes bytes that are no longer here" with nothing after `commit=`, and
   `deploy.sh:619` logged `ancestry_replaced=` empty. Both now read `${INSTALLED_COMMIT:-unknown}`.
4. **`scripts/test.sh`** - the new test is a gate row, right after `test-deploy-record.sh`, with a comment
   saying what the row pins.
5. **`docs/COMPONENTS.md`** - one paragraph stating the fast-path split (`commit=` = the tree,
   `binary_commit=` = the bytes, `lua_fast_path=1` says which) and the `unknown` + `binary_commit_why=` rule.

A real record written by the fixed code (from the test fixture; the target tree is 93168d96 here):

```
commit=93168d9649b33069bd9b19cb82c685345c446bd9
...
tree=a5d8c616796518a1082364aab682c157238a78ab
build_info=yes
lua_tree=93168d9649b33069bd9b19cb82c685345c446bd9
lua_fast_path=1
binary_inputs=89210ec6a33df8ce628f8732a43633646a7a5d0f9ae569825d132575e07d1104
...
binary_commit=a5d8c616796518a1082364aab682c157238a78ab
```

## Tests

New file `scripts/test-deploy-luafast-record.sh`, wired into `scripts/test.sh` (the row right after
`test-deploy-record.sh`). 37 checks, all passing. It extracts the deploy's own kept-binary block (from its
`LUA_FAST=0` to its `INSTALLED_BIN=` line) and its own `record_installed()` out of `scripts/deploy.sh`, runs
them over the REAL `scripts/lib/install-record.sh`, `scripts/lib/node-binaries.sh` and
`scripts/lib/commit-id.sh`, in a scratch install directory whose `wa` is a stub answering `--build-info`. It
covers: a full install followed by a Lua-only deploy (the reported failure); a second Lua-only deploy; a
kept binary that stops answering; a fast-path record with nothing naming the bytes; a full-install record and
a silent binary; and a record that disagrees with a binary that can answer. Hermetic: scratch `HOME`,
`WASM_AGENT_HOME` and install directories under `mktemp`, with an explicit refusal if any of them is the
machine's own state; no cargo, no network, no restart.

It is not a full end-to-end deploy: the build, the scratch-port proof, `upgrade.sh` and the restart are not
part of it, and I did not deploy this machine or restart anything.

### Discrimination (the row this branch adds must fail on the base)

`bash scripts/test-discriminates.sh origin/main` ->

```
discriminates\tscripts/test-deploy-luafast-record.sh\t  FAIL 6 the record is written from the binary's answer: got '97251587b3a3...' want '93168d96...'
test-discriminates: 2 discriminating, 0 blocking, 0 not judged by this machine (0 skipped, 0 timed out, 0 unrevertable, 0 environment)
```

Two rows, after round 2: the new file, and `scripts/test-install-record.sh` (amended there - see "Round 2"
below - and it fails on the base code at the fast-path rows it now carries).

Run by hand on a base worktree (`git worktree add /tmp/base-luafast 93168d96`, the test copied in), the base
fails 23 of the 37 checks, first with the reported refusal:

```
FAIL 1 the Lua-only deploy after a full install finishes (exit): got '1' want '0'
FAIL 1 it does not refuse the binary it just kept: 'build_commit_mismatch' should not be there
  (deploy: refused(build_commit_mismatch): ... reports commit 97251587b3a3 but this deploy meant to install a5d8c6167965 ...)
FAIL 1 the kept binary's commit is the binary's own answer: got '' want '97251587b3a3...'
```

`git log -S 'RECORD_BINARY_COMMIT' -- scripts/deploy.sh` names 4fb06aa5 as the commit that implements the
resolution; `git show 4fb06aa5 --stat` = scripts/deploy.sh +93/-10, scripts/test-deploy-luafast-record.sh
(new), scripts/test.sh +8.

## Round 2 - the preflight gate: `install-record`

The preflight of 21/11 20:26Z (run `preflight-20261121T202620Z-2599541`, main `a8c4cca8`, tree `ced11728`)
stopped on one row:

```
FAIL install-record (exit 1): ... test-install-record: 91 checks, 1 failed
```

Reproduced here with the same binary the gate uses (`WA_BIN=<build>/release/wa bash
scripts/test-install-record.sh`), the failing check is `scripts/test-install-record.sh:224`:

```
FAIL deploy.sh still records the caller's commit
```

which is `if grep -qF 'record_commit="$COMMIT"' scripts/deploy.sh; then bad ...`. Commit `4fb06aa5` writes
exactly that line, on purpose: a Lua fast path installs no binary, so the install IS the Lua tree the deploy
staged and verified, and `commit=` has to name it - `scripts/verify-deployed.sh:111-121` compares `commit=`
with the commit it was asked to verify, and `lua/core/update.lua:192` compares it with `origin/main`. The
bytes are named separately in `binary_commit=`, from the binary's own `--build-info`.

So the guard and the fix disagreed, and the rule behind the guard is not one to drop: **the caller's belief
must never become the record's identity** (18/11). What was asserted was the SHAPE of the code, not the
rule, and the shape stopped being able to tell the two apart. I did not delete it, did not rename the
variable to slip past the grep, and did not remove the row; the assertion now runs against the record the
real step writes, for both kinds of install, and it is more than the grep said:

1. a build whose bytes report the commit this deploy holds -> `commit=` is the BINARY's answer (`wa_build_field`);
2. a build whose bytes report ANOTHER commit -> the step is REFUSED (`build_commit_mismatch`) and writes no
   record at all, so the caller's commit cannot land in `installed.txt`;
3. a Lua fast-path record -> `commit=` is the tree, `binary_commit=` is the binary's own answer, the two are
   distinguishable, and `lua_fast_path=1` says which kind of record it is.

The step is `record_installed()` extracted from `scripts/deploy.sh` (same awk as `scripts/test-deploy-record.sh`),
run over the real `install-record.sh`, `node-binaries.sh` and `commit-id.sh` with the file's existing stub
binary. `91 checks, 1 failed` -> `100 checks, 0 failed`: nine checks added, none removed. On the base code the
amended file fails at row 3 (the base writes the binary's commit in `commit=`), which is what
`test-discriminates` now reports as the second discriminating row.

Verification of the row as the gate runs it, on a tree that merges this branch onto the CURRENT main
(`a8c4cca8`, merge clean - `scripts/test.sh` auto-merges):

```
test-install-record: 100 checks, 0 failed
test-deploy-luafast-record: 37 checks, 0 failed
```

## Rows run here, and rows that fail for reasons older than this branch

Ran on this node (avell): the new test (37/37), `scripts/test-install-guards.sh` (72/72),
`scripts/test-deploy-record.sh`, `scripts/test-deploy-ancestry.sh`, `scripts/test-deploy-node-binaries.sh`.
The full `scripts/test.sh` was NOT run (rule 15: one heavy suite at a time, and it is not what this round is
about); the row that matters for it is the `gate_run` line added at `scripts/test.sh:2552`.

Three of those fail on this machine, and each fails the same way on a base worktree at 93168d96:

- `scripts/test-deploy-record.sh` - dies before any assertion inside its own generated runner:
  `wa_build_info: command not found`, `note: command not found`, `ROOT: unbound variable`. Base: identical.
  So this row gives no signal here for the record step either way.
- `scripts/test-deploy-ancestry.sh` - 35 failed on this branch, 46 on the base, and every failure in both is
  one cause: a leftover fixture process on this machine (pid 2553463, deleted `.../install/wa`) holds port
  18799, so each case refuses with `cannot bind the port this node will be restarted onto`. Pre-existing and
  environmental; not killed (rule 17 - a process I did not start).
- `scripts/test-deploy-node-binaries.sh` - `FAILED: the installed prebuilt supervisor is not executable`.
  Base: identical.

## Texts to approve (operator- or record-facing, verbatim)

1. `deploy: the install record says binary_commit=<12 hex> but the binary kept here reports <12 hex>; the binary is the witness and the record below is written from its answer`
   (a `note`, so it goes to the deploy log and stdout when a fast-path record disagrees with a binary that can answer).
2. `installed.txt` line `binary_commit=unknown`, plus
   `binary_commit_why=nothing names the commit the kept binary <path> is a build of (<RUNNING_WHY>; running_source=<source>), and this install record carried no binary_commit=`
   when no source can name the kept bytes.
3. The `record_not_this_binary` refusal now says `so the record's commit=unknown describes bytes that are no
   longer here ...` where it used to say `commit=` followed by nothing.
4. The `ancestry_unverified=yes overrode=record_not_this_binary` note now records `ancestry_replaced=unknown`
   instead of an empty value.

## What this does not claim

- It does not claim the fast path was tested end to end (build, scratch-port proof, `upgrade.sh`, restart):
  it was not.
- It does not claim a deploy of this machine: nothing was deployed, restarted or pushed.
- It does not claim the three failing rows above are fixed, or that they were ever green here.

