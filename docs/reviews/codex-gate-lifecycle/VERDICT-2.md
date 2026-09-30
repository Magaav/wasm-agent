# Re-check: `change/codex-gate-lifecycle` @ `be2260d`

Reviewed tree **`5cd6effd3e48f0a9f838973d68310e4cf44440c9`** (commit
`be2260d8f2a239e7764e0a2cf75717412ce52d35`, parent `c8589c7`, one commit on top of the tree my
first verdict refused-and-then-the-successor-closed). `change/codex-gate-lifecycle` and
`origin/change/codex-gate-lifecycle` both point at it.

## VERDICT: `accept with named residue`

All three questions settle in the delivery's favour, by execution rather than by reading. The
residue is **not in the delta** — the delta is exactly the cleanup it claims — it is scope and
inheritance: a non-Windows leak path the new `finally` cannot reach, the 36 sibling families the
checker still defers, and the policy residues my first verdict named, which this commit does not
touch. Details in "Named residue".

## 1. The delta is confined to the cleanup, in one file

`git diff --stat c8589c7 be2260d` → `scripts/test-gate-drain.cjs | 15 +++++++++++----` (11
insertions, 4 deletions); `git diff --name-status` → `M scripts/test-gate-drain.cjs` and nothing
else, so the tree pair is `b71e56efc505b133c0ef644707c51f3c9adcf953` →
`5cd6effd3e48f0a9f838973d68310e4cf44440c9` with one file's blob changed
(`e36a5420…` → `cb7459f1…`, both sha256 of the blob are in `evidence/VERDICT-2-commands.txt`).

The change is what it says (`evidence/delta-c8589c7-be2260d.diff`): the three `stopOwned` calls
moved inside a nested `try`, whose own `finally` writes the two captured streams to this
reporter's stderr (`[gate-drain] drain-finish.stdout|stderr`, so the evidence survives a passing
run on the gate's log instead of only inside the removed root) and then
`fs.rmSync(root,{recursive:true,force:true,maxRetries:5,retryDelay:200})`. No lane source, no test
assertion and no other file is in the delta.

## 2. The leak is gone — measured

- Before: `ls -d $TMP/wa-gate-drain-*` → **0** families.
- `node scripts/test-gate-drain.cjs` (`evidence/be2260d-drain-regression.log`) → **exit 0**, final
  line `timeout drain check ok: attempted free-slot falsification refused; source/lease runner
  identity verified; exact source unchanged`.
- After: **0** families. Same count after a **failing** run, i.e. the nested `finally` fires on the
  error path too (`evidence/drain-negative-control-prefix-pair.log`).
- Checker, by the invocation `scripts/test.sh` uses — `node scripts/check-temp-retention.mjs`
  (line 1547 of that tree's `test.sh`, which lives in the sibling tip `90766a96`, not in this
  delivery's ancestry; checker sha256 `91343346…`):

| drain file blob | checker line for this file | totals | exit |
|---|---|---|---|
| `be2260d` (`cb7459f1…`) | `ok scripts/test-gate-drain.cjs (mint at 10; removes via node-rm)` | `PASS (223 files, 82 mint temp paths, 0 declared, 36 deferred, 0 resolved)` | 0 |
| `c8589c7` (`e36a5420…`) | `FAIL scripts/test-gate-drain.cjs mints a temp family and never bounds it in this file` `10:mkdtemp const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-gate-drain-'));` | `FAIL (223 files, 82 mint temp paths, 0 declared, 36 deferred, 0 resolved)` + `failed: scripts/test-gate-drain.cjs mints a temp family with no retention or cleanup path in this file` | 1 |

The `failed:` line is verbatim the landing's failure. My totals are 223/82/0/36 against the
landing's 231/88/1/36 because my tree carries neither the other five tips nor the checker itself
(copied in from `90766a96`); the same 36 files stay deferred, and this file's own line is the
discriminator, which is what the fix was for.

## 3. Nothing the earlier reviews verified regressed

- **Identity assertions untouched**: lines 20 (`sourceHashes = {lane: sha(lane), finish: sha(finish)}`),
  116 (`assert.deepEqual({lane:sha(lane),finish:sha(finish)},sourceHashes)`) and 117 (the success
  line) are byte-identical in both blobs; `git diff` shows them as context only.
- **The regression still fails loudly on the defect it was written for**: a scratch tree with the
  pre-fix pair (`19bf2bd` lane `5140836…` + `19bf2bd` finish `2f62f07…`) exits **1** with
  `FALSIFIED: a new private command ran while timed-shell descendant remained alive` and
  `AssertionError [ERR_ASSERTION]: unsafe drain: a surviving descendant did not retain its
  reservation … test-gate-drain.cjs:108:12`; the fixed pair exits 0 with its success line. So the
  check is not vacuous, and the cleanup did not blunt it.
- The lane-ownership work the two earlier verdicts covered is not in this delta at all (one file,
  a test).

## Named residue (why this is not a plain `accept`)

1. **The fix is Windows-only; the non-Windows path still leaks one family per run.** The root is
   minted at line 10 and the non-Windows branch exits at line 11, *before* `main()` — whose
   `finally` now does the removal. Forced and counted with a scratch wrapper that sets
   `process.platform = 'linux'`: 0 families before, **1** after
   (`evidence/posix-skip-family.log`; I removed the family the probe left). The checker cannot see
   this, because it is a text check and the file now mentions a removal path. On Windows — the host
   where the leak was measured (13079 stale entries) and where the gate runs — the leak is fixed.
2. **Only this file.** The checker prints, not fails, the 36 files that already mint unbounded
   families; that list is the sibling change's deliberate deferral and is unchanged here.
3. **Inherited policy residue, untouched by this commit** (from `VERDICT.md`, still open): a
   gate timeout now retains its slot until an owner supplies drain evidence; caller-supplied wait
   budgets (600 s against a 15 min gate) remain a guaranteed refusal; `finish.mjs` fails closed
   where `merge-lane.mjs` still fails open, and `merge-lane` emits no `GATE_LANE_ORIGIN`.
4. Minor: if `fs.rmSync` itself threw (a file still locked after 5 retries), it would replace a
   stop error from the nested `try`. Not observed; named for completeness.

## What I could NOT verify

- **The real six-tip landing tree.** It is not pushed and no merge of those six tips exists in the
  refs I hold, so I could not run the checker in the tree the gate failed in; I reconstructed the
  A/B in `be2260d`'s tree with the sibling tip's checker file. If the landing's checker differs
  from `90766a96`'s, my totals could differ (the per-file line is the file under review, so it
  should not).
- `scripts/test.sh` and any gate slot (excluded by the brief; the landing holds the slot).
- POSIX behaviour beyond the forced branch above: the regression's real Windows descendant fixture
  is the only path it exercises here.
- The other five tips in that landing (not my scope), and whether the landing now passes as a whole:
  I confirmed this file's checker line, not the landing's aggregate result.

Verdict, evidence and this re-check are on
`change/wa-session-childdispatchcd2db7d4-cc61-449e-9962-36ce699caff6` (from `da8dc891`). The
delivery was not edited, nothing was merged, and no gate slot was taken.
