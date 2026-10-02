# Independent review: `change/deploy-unbound` (tip `245d0a8`)

**Verdict: narrowed.** Nothing here blocks landing. Every mechanism the delivery claims
reproduces on the exact tree, under my own fixtures, and the four focused suites are
pinned by mutation. Three of its *stated* claims need narrowing (one stale doc, one
reading rule its own fix outgrew, one test that does not pin what its comment claims),
and the record-role ordering it describes as "the deploy's record wins" is
order-dependent rather than monotone.

* Reviewed tree: `245d0a844d7aab2c6da1ddc9c6076406cf69da9a`, 1 commit ahead of
  `origin/main` `2f02b4c`. Review branch `review/deploy-unbound` in my own worktree
  (`wa-worktree-childdispatch0a63f37c-fdac-4e29-b64c-4451abe47a43`).
* Producer: `child:dispatch:6204126f-93d1-4249-96a5-514acff56693` (I did not produce this).
* **Independence is the lane, not the model.** This node refuses `gpt-6-luna`
  (`model_not_servable`), so this review ran on `deepseek-v4.1-flash`/high - the same
  family as the producer. What makes it independent is that every number below came from
  my own fixture, my own mutations and the real scripts, not from the producer's report.
* Nothing was deployed, no node or window was restarted, the live install was never read
  or written, and nothing was pushed. Every experiment ran in `/tmp` fixtures, a scratch
  clone (`/tmp/review-mut/base`) and a scratch repository with its own bare `origin`.

## What I ran (verbatim results)

### The four focused suites, on the tip

```
$ bash scripts/test-deploy-record.sh
ok   the final record names the exact deployed commit - commit=cfb00e1 of cfb00e1
ok   the final record says clean-built-by-deploy - source_provenance=clean-built-by-deploy
ok   the final record is the owner's final one - record_role=final
ok   the final record names the deploy that wrote it - via=deploy.sh
ok   the final record carries the deploy's reason, not upgrade.sh's default - reason=land the three reviewed deliveries
ok   the recorded sentinel hash is the installed sentinel - recorded=2c398d07… installed=2c398d07…
ok   writing the record twice is idempotent - the early and final calls agree on every field but the time of writing
ok   the record is written before the steps that can die after the install - record at line 610, the self-ship that killed the 2026-10-02 deploy at line 654
ok   upgrade.sh records an INTERIM record when a deploy called it - record_role=interim via=deploy.sh
ok   a hand-run upgrade is its own final record - record_role=final via=upgrade.sh
ok   upgrade.sh receives WA_UPGRADE_VIA - WA_UPGRADE_VIA=deploy.sh
ok   the old shape is reproduced as losing the caller identity - WA_UPGRADE_VIA=unset …
test-deploy-record: ALL PASS (24 checks; private install directory /tmp/wa-deploy-record-KnF0my/install)   EXIT=0

$ bash scripts/test-deploy-self-ship.sh
ok   the rename form runs the rest of the script it just replaced - status 0
ok   the destination holds the new bytes afterwards
ok   no staging file survives the rename
ok   the in-place cp form is reproduced as losing the rest of the script - status 0, no line after the replacement
ok   the shipped script is complete, not truncated - destination 1542 bytes, source 1542 bytes
test-deploy-self-ship: ALL PASS (5 checks)   EXIT=0

$ bash scripts/test-deploy-gate-policy.sh
ok   the default deploy does not consult a release proof - the poisoned proof lookup was never invoked
ok   the strict path consults the proof lookup when the knob is set - it was invoked with …\wa-deploy-gate-policy-KcGjKw\root 31f1d8cb…
ok   the strict path refuses a tree with no release proof, naming the knob
test-deploy-gate-policy: ALL PASS (3 checks)   EXIT=0

$ node scripts/test-verify-install.mjs
verify install checks ok (8 checks, 0 skipped; isolated source/install fixture)   EXIT=0
```

### The deploy-related parts of `scripts/test.sh` (I did not run the full gate)

```
$ bash scripts/test-deploy-preconditions.sh     → deploy preconditions ok (EXIT=0, 7 cases, each refusal by name)
$ bash scripts/test-deploy-downgrade.sh         → deploy downgrade gate ok (24 checks) (EXIT=0)
$ bash scripts/test-deploy-service-target.sh    → deploy service-target ok (34 checks) (EXIT=0)
$ bash scripts/test-deploy-ship.sh              → ALL PASS (EXIT=0)
$ the turn-guard block, test.sh:258-270         → deploy refused: "cannot deploy from a running turn …"
                                                  upgrade.sh refused: "refused inside a running turn; …"
$ node scripts/test-lane-boundary.mjs           → lane boundary ok (68 checks) (EXIT=0)
```

The two new suites also run through the gate's own runner (`scripts/lib/gate-timing.sh`),
which is how `test.sh` invokes every suite:

```
3460	0	bash scripts/test-deploy-record.sh
723	0	bash scripts/test-deploy-self-ship.sh
```

## Claim 1 - the release linkage is gone from the deploy decision: PROVED

* Default (`WA_DEPLOY_REQUIRE_RELEASE_PROOF` unset): the poisoned proof lookup is never
  invoked (marker file absent), the block reaches the build, no `REFUSED`, and the default
  output carries no line about a release proof at all.
* Knob set: the lookup runs and the refusal names both the missing proof and the knob
  (`REFUSED: complete gate proof required for source tree 31f1d8cb… (WA_DEPLOY_REQUIRE_RELEASE_PROOF is set): {"verified":false,…}`).
* Mutation M5 below shows the behavioural half is real, not just the structural grep:
  `&&` → `||` in the guard (so the knob's text is still in the file but no longer guards
  the lookup) turns the suite red with `a deploy with no release proof was refused (status 3)`.
* `gate.on = "release"` is unchanged, and `lane-policy.json` changed only `deploy.when` /
  `deploy.evidence`. The policy text is enforced only as "a non-empty string"
  (`scripts/lib/lane-boundary.mjs:69`), so the rewording is documentation and
  `test-lane-boundary.mjs` stays green.

## Claim 2 - the two causes of the install-record bug: BOTH REPRODUCED

### 2(a) the `VAR=value \` prefix lost inside a continuation: reproduced, and fixed

My own measurement (bash 5.3.15, Git bash on Windows):

```
--- control (no comment in continuation) ---
stub received: FOO=[1] BAR=[two]        control exit=0
--- old shape (comment inside the continuation) ---
stub received: FOO=[unset] BAR=[unset]  oldshape exit=0     ← the command ran, the prefix vanished
--- the comment at column 0, same result ---
stub received: FOO=[unset] BAR=[unset]  oldshape2 exit=0
bash -c 'echo "[$FOO]"'  →  []                              oldshape3 exit=0
```

And on the real code - the invocation block read out of `2f02b4c:scripts/deploy.sh`
(lines 432-438) against my own stub that prints the environment it received, versus the
same block out of the tip:

```
===== OLD (2f02b4c) =====        ===== NEW (245d0a8) =====
  WA_INSTALL_DIR=unset              WA_INSTALL_DIR=/tmp/…/install
  WA_PORT=unset                     WA_PORT=8877
  WA_CLIENT_PORT=unset              WA_CLIENT_PORT=8878
  WA_UPGRADE_REASON=unset           WA_UPGRADE_REASON=a reason with spaces
  WA_UPGRADE_VIA=unset              WA_UPGRADE_VIA=deploy.sh
  ARG=…/tree/wa                     ARG=…/tree/wa
```

### 2(b) `cp -f` over the running script: reproduced, with a size sweep

Victim replaces itself in place, then has 40 more lines to read; replacement is longer
than the victim so every later offset shifts. `ship` = the real `ship_file()` out of the
tip; `cp` = the form it replaced.

```
n=5    cp    status=127 T1=0 T2=0  last=[…: line 11: replacement: command not found]
n=5    ship  status=0   T1=1 T2=1  last=[T2 the final line ran]
n=20   cp    status=127 T1=0 T2=0  last=[…: line 26: ent: command not found]
n=40   cp    status=127 T1=0 T2=0  last=[…: line 46: adding: command not found]
n=100  cp    status=0   T1=0 T2=0  last=[before the self-ship]        ← silent, status 0
n=400  cp    status=0   T1=0 T2=0  last=[before the self-ship]        ← silent, status 0
(every `ship` row: status=0, T1=1, T2=1)
```

The tail is lost at every size on this machine, and from n=100 the run ends with
**status 0** while silently skipping everything after the self-ship - which is the
producer's "worse" case, independently confirmed. I reproduced the *class* of the
observed `line 534: syntax error near unexpected token '('` (resume inside a line:
`line N: <fragment>: command not found`) rather than that exact string; the exact string
is the producer's live evidence, which I did not re-observe (see *Unproven*).

## Claim 3 - record ownership: holds in the observed order, order-dependent in general

Private install, the real `record_installed` out of `deploy.sh` and `record_install` out
of `upgrade.sh`, then the real `scripts/verify-install.sh`:

```
CASE A (the observed order: upgrade.sh then the deploy)
  after upgrade.sh:   commit=unknown source_provenance=unverified-binary record_role=interim via=deploy.sh
  after the deploy:   commit=6ba5b19 source_provenance=clean-built-by-deploy record_role=final via=deploy.sh
  ok   the install record is its owner's final one - record_role=final, via=deploy.sh

CASE C (the deploy killed between its early final write and its last act)
  record left behind: commit=6ba5b19 source_provenance=clean-built-by-deploy record_role=final via=deploy.sh
  deploy-result.json: ABSENT
  ok   installed.txt present - commit=6ba5b19 via=deploy.sh
  ok   the record was written for this install
  ok   the install record is its owner's final one - record_role=final, via=deploy.sh
```

So the early write does what it claims: a deploy that dies before its last act leaves the
deploy's own exact-commit record with the post-swap `sentinel_sha256`, not upgrade.sh's
interim one. See finding F1 for what that state does *not* name.

## Claim 4 - the reading rule: narrowed (finding F1)

The rule ("install blobs older than the deployed tree + `record_role=interim` + a
`deploy-result.json` older than `installed.txt` ⇒ an unfinished deploy") is correct for
the states it covers, but the early-final write removes its `interim` leg from the phase
that follows it: a deploy that dies *after* the early record - during the ship steps,
which is exactly where the 2026-10-02 run died - now leaves `record_role=final` with
`deploy-result.json` absent or stale. `verify-install.sh` never reads
`deploy-result.json` (`grep -c deploy-result scripts/verify-install.sh` → `0`), so nothing
in the verifier names that state either.

## Claim 5 - the state refusals still fire: CONFIRMED (with one documented exemption)

Scratch repository with its own bare `origin`, the real `deploy.sh` from the tip,
`WA_DEPLOY_ROOT` pointed at it, a private `WA_INSTALL_DIR`, nothing built:

```
(a) dirty tree         → deploy: the tree has 1 uncommitted change(s); commit or stash them first      exit=1
(b) HEAD not on main   → WITHOUT --require-main: NOT refused, reached "deploy: building" (the
                          WA_INSTALL_DIR exemption is deliberate, see F5)
                       → WITH --require-main: deploy: this tree's commit ca19ec5 is not on origin/main;
                          merge it to main and deploy from there                                        exit=1
(c) HEAD behind main   → deploy: this tree is 1 commit(s) behind origin/main; merge main first          exit=1
                          (same with WA_INSTALL_DIR unset)
(d) a downgrade        → pinned by scripts/test-deploy-downgrade.sh: 24 checks, EXIT=0
(e) port held by another install / (f) an install dir the service does not run from
                       → pinned by scripts/test-deploy-service-target.sh: 34 checks, EXIT=0
(g) a deploy from inside a run → refused by name in deploy.sh and upgrade.sh (unchanged code,
                          turn guard at deploy.sh:143, before every other step)
```

## Claim 6 - `scripts/test.sh` is additive: CONFIRMED

```
$ git diff --numstat 2f02b4c..245d0a8 -- scripts/test.sh
7	0	scripts/test.sh
$ git diff 2f02b4c..245d0a8 -- scripts/test.sh | grep -c '^-[^-]'
0
$ comm on the `^gate_run ` lines: old=68 new=70; dropped: (none); added:
  gate_run bash scripts/test-deploy-record.sh
  gate_run bash scripts/test-deploy-self-ship.sh
```

Both added lines sit at top level in the sequential suite list (column 0, next to
`test-deploy-gate-policy.sh` / `test-deploy-preconditions.sh`), and `gate_run`
(`scripts/lib/gate-timing.sh:9`) runs the command and returns its status, which `set -e`
turns into a gate abort. The timing rows above are from running both through that exact
function.

## Mutation tests (9 attempted, 8 red, 1 green)

Each mutation was applied to a scratch clone at the tip with a literal-replacement
mutator that refuses a pattern that is absent or non-unique, and the tree was restored
after each run.

| # | one thing mutated | suite | result |
|---|---|---|---|
| M1 | `deploy.sh` record printf: `via=deploy.sh` → `via=upgrade.sh` | test-deploy-record.sh | **RED** `the final record names the deploy that wrote it - via=upgrade.sh` |
| M2 | the early `record_installed` call deleted (only the last act writes) | test-deploy-record.sh | **RED** `the record is written before the steps that can die after the install - record at line 768 …` |
| M3 | a comment moved back *inside* the invocation continuation | test-deploy-record.sh | **RED** `upgrade.sh receives WA_UPGRADE_VIA` |
| M4a | `ship_file` reverted to an in-place `cp -f` over the destination | test-deploy-self-ship.sh | **RED** `the extracted self-ship does not rename (the marker moved?)` |
| M4b | `ship_file` rewrites the destination in place **and** stages+renames (`mv -f`/`cmp -s` still present) | test-deploy-self-ship.sh | **RED** `the rename form runs the rest of the script it just replaced - status 0` |
| M5 | guard `&&` → `\|\|` (knob text still in the file, no longer guarding) | test-deploy-gate-policy.sh | **RED** `a deploy with no release proof was refused (status 3)` |
| M6 | `upgrade.sh`: `role=interim/final` ownership removed, always `final` | test-deploy-record.sh | **RED** `upgrade.sh records an INTERIM record when a deploy called it - record_role=final via=deploy.sh` |
| M7 | `verify-install.sh`: `interim) record fail` → `record ok` | test-verify-install.mjs | **RED** `AssertionError: an interim record fails verification` |
| M8 | `record_installed` writes `installed.txt` non-atomically (no staging, no rename) | test-deploy-record.sh | **GREEN** - not pinned, see F3 |

## Attacks on the self-ship fix (my own fixtures, the real `ship_file`)

| attack | result |
|---|---|
| destination **is** the running script, executed while replaced | returns ok; destination holds the new bytes; no leftovers |
| **source missing** (a write that cannot happen before the rename) | `REFUSED: node installed, but could not stage target.sh`, exit 3, destination unchanged, no staged file |
| **rename cannot succeed** - destination's parent `chmod a-w` | not reproducible: the rename still succeeded (Windows read-only attribute does not stop it) |
| **destination is a read-only file** | not reproducible: the rename still replaced it |
| **rename cannot succeed** - contrived: the staged name exists as a directory | `REFUSED: node installed, but could not ship target.sh`, destination unchanged; residue left (the directory, which `rm -f` cannot remove) |
| **killed between the staged write and the rename** (300 MB source, SIGKILL mid-copy) | destination intact: `[ORIGINAL]` (9 bytes). Residue: `target.sh.ship.402`, 248,643,584 bytes. The **old** form in the same experiment left the destination **PARTIAL** (131,072,000 of 300,000,000 bytes) - the failure class this fix removes |
| two `ship_file` calls racing (two deploys) | destination complete, no leftovers (staging names are per-pid) |
| does anything else still `cp -f` over a running script? | no: the remaining `cp -f` sites ship the sentinel image, `whatsapp-*` pipeline scripts, lib modules, skills and job files - none of them is the shell's own file. `deploy.sh`'s self-ship and `upgrade.sh`'s self-ship are the only two that were, and both stage+rename |

## Findings

* **F1 `evidence:open`** - `record_role=final` no longer implies the deploy finished, and
  nothing names the difference. The early write (by design) means a death *after* it -
  during the ship steps, exactly where the 2026-10-02 run died - leaves `final` +
  `deploy-result.json` absent/stale. `verify-install.sh` reads `installed.txt`,
  `/health`, `serve.pid`, the sentinel and the request box, and never `deploy-result.json`
  (`grep -c deploy-result scripts/verify-install.sh` → `0`), so the verifier's verdict for
  that state is "the install record is its owner's final one" with no word about the
  unfinished deploy. Claim 4's reading rule requires `record_role=interim`, so it does not
  cover it either. Non-blocking: the record is *more* honest than before, and the death is
  still visible in `deploy-result.json`/`deploy.log` - but the delivery's own rule needs a
  third leg ("`final` with a `deploy-result.json` older than `installed.txt`"), or the
  verifier should read `deploy-result.json`.
* **F2 `docs:open`** - `docs/RECOVERY-THROUGHPUT.md:55-58` still says "`deploy.sh` *looks
  up* discoverable complete proof for a real Rust source workspace and records what it
  found, but does not require it". At the tip, with the knob unset, the tree is not handed
  to the lookup at all - the sentence is now false. `lane-policy.json` and
  `skills/self-update/SKILL.md` were updated; this doc was not. (`docs/CONCURRENCY.md:213-216`
  is still consistent.)
* **F3 `test-gap:open`** - `test-deploy-record.sh`'s "no half-written record is left
  behind" is a *leftover* check, not an atomicity check: M8 replaced the staged
  write+rename with a direct `> installed.txt` and all 24 checks still passed. The code is
  atomic by construction; the claim is unpinned.
* **F4 `evidence:open`** - `record_role` is not monotone. A later `upgrade.sh` call with
  `WA_UPGRADE_VIA=deploy.sh` overwrites a `final` record with an `interim` one - measured
  with the real blocks in one private install: after deploy A wrote
  `record_role=final source_provenance=clean-built-by-deploy`, deploy B's `upgrade.sh`
  left `record_role=interim source_provenance=unverified-binary`, and `verify-install.sh`
  then reported `FAIL the install record is its owner's final one - … a deploy was
  installing this node and did not reach its own record step …`. The refusal is the right
  one (do not trust this record), but the *cause sentence* asserts a death that did not
  happen in this ordering: the record names a state, not a proven story. Low severity -
  the reading rule's other legs (stale result, old shipped blobs) are what disambiguate.
* **F5 `pre-existing:open`** - two behaviours the delivery neither introduced nor changed,
  reported so landing does not read as a regression: (i) the `not on origin/main` refusal
  is skipped whenever `WA_INSTALL_DIR` is set, unless `--require-main` is passed (measured
  above), which is deliberate ("a scratch WA_INSTALL_DIR is a test") but also means the
  refusal the docs list is conditional; (ii) the knob is truthy on *any* non-empty value -
  `WA_DEPLOY_REQUIRE_RELEASE_PROOF=0` / `false` / `no` all enable the strict refusal
  (`-n` guard, unchanged from `2f02b4c`).
* **F6 `residue:open`** - the staged form converts a partial *destination* into residue:
  a SIGKILL between the staged write and the rename leaves `<name>.ship.<pid>` (measured:
  248 MB) in the install's `scripts/`; `upgrade.sh`'s form leaves
  `upgrade.sh.new.<pid>` the same way. No later run sweeps them, and nothing reads them.
  Not a correctness issue - the destination is never partial - and strictly better than
  what it replaced.

## Proved

1. The `VAR=value \` prefix is silently dropped when a comment line sits inside the
   continuation (my own measurement), and the invocation at the tip delivers
   `WA_INSTALL_DIR`, `WA_PORT`, `WA_CLIENT_PORT`, `WA_UPGRADE_REASON`, `WA_UPGRADE_VIA`
   and the binary argument - where the `2f02b4c` block delivered none of the five.
2. An in-place `cp -f` over a running script loses everything after it at every fixture
   size I tried, silently and sometimes with status 0; the real `ship_file()` (staged +
   rename) always finishes. A kill mid-copy leaves the old form's destination truncated
   and the new form's destination intact.
3. The release proof is not consulted on the default path (poisoned-lookup marker absent)
   and is consulted with a by-name refusal when the knob is set; the behavioural half
   fails under mutation.
4. The deploy's record names the exact commit, `clean-built-by-deploy`, `record_role=final`,
   the post-swap `sentinel_sha256`, its own `install_dir` and its own reason, over
   upgrade.sh's interim record; upgrade.sh's role flips with its caller; the early call and
   the last act agree on every field but `at=`; `verify-install.sh` fails an interim record
   by name.
5. The state refusals fire: dirty tree, HEAD behind `origin/main`, HEAD not on it (with
   `--require-main`), a downgrade, a held port, a service/install mismatch, and a deploy
   from inside a run.
6. `scripts/test.sh` is additive (7 insertions, 0 deletions; 68 → 70 `gate_run` lines,
   none dropped) and both new suites run under the gate's own runner.
7. Eight of nine mutations go red; the ninth is F3.

## Unproven / not tested

* **A rename that cannot succeed** could not be forced on this platform: read-only
  directory and read-only file attributes do not stop the rename under Git bash, and I
  have no way to hold the destination open without share-delete from MSYS. The only
  failure path I could exercise was the contrived directory-collision shape (refused by
  name, destination intact, residue). On POSIX the same question is untested by me.
* **The historical live incident** (claim 2's `line 534: syntax error near unexpected
  token '('`, `sentinel/deploy.out`, `verify-install --json` 47 checks / 4 failed on the
  live install) is the producer's evidence. I reproduced the mechanism and the
  install-record state it produced, not the live run: I did not read the live install's
  logs and did not run a deploy.
* **Claim 4's stale shipped wave scripts** (that ship-wave ran in the 17:33 deploy with
  `5b1ffdc` blobs and the 19:29 deploy died at 2(b) first) is a claim about two historical
  runs; I verified only that the code path that would produce it is the one that was
  fixed, and that `test-deploy-ship.sh` (3 checks) is green.
* The **full gate** was not run - by instruction it belongs to a release. The deploy-related
  suites and the lane-boundary suite were run individually.

Agent: wasm-agent node=wasm_the_first role=reviewer session=child:dispatch:0a63f37c-fdac-4e29-b64c-4451abe47a43
