# Independent review: `change/codex-gate-lifecycle` @ `19bf2bd`

Reviewed tree **`8e305e5b1428113deb1024c9cd9902ecdca0d20b`** (commit
`19bf2bdd2f434f48756a522cb2388923c3a02e5b`, parent `ab827c8`, base `origin/main` = `da8dc891`).
Author: Orca/Codex `session=term_2806604b`. I did not write this delivery.

## VERDICT: `needs-change` — for that tree, on item 1 only

The commit's own subject is *"bind nested reservations to live ownership"*. **Admission** is bound
to live ownership and I verified that. **Release is not**, and that asymmetry is falsifiable exactly
as the brief demanded: kill the owner while a nested gate is in flight, and the lane releases the
capacity-1 slot with a **false proof of death**, then hands the same slot to another caller while
the nested gate is still running. Reproduced twice, raw logs
(`evidence/tip-19bf2bd-nested-drain.log`, `evidence/tip-19bf2bd-second-run.log`).

Two things the brief did not state, both material to landing:

1. **The branch tip is no longer this commit.** `change/codex-gate-lifecycle` (local and
   `origin/`) is at `c8589c7f57dea40c0476c8984694fea7dc7b1770` (tree
   `b71e56efc505b133c0ef644707c51f3c9adcf953`), whose parent is `19bf2bd`. Nothing can land
   `19bf2bd` alone. I re-ran the falsification against the tip's lane runner (sha256
   `1094b422…`): the slot is **kept**, the row goes `orphaned … automatic release withheld: owner
   drain evidence required`, and the second caller waits and is refused after its budget
   (`evidence/successor-c8589c7-nested-drain.log`). So the hole below is closed one commit later.
   **My verdict covers `8e305e5b` only**; for `b71e56e` I measured one property and nothing else.
2. **The delivery is five files, not two** (`scripts/gate-lane.mjs`,
   `scripts/test-gate-lane-wiring.cjs`, `scripts/test-parallel-finish.mjs`,
   `skills/parallel-evolution/scripts/finish.mjs` — the live consumer — and a new
   `skills/gate-lifecycle/SKILL.md`). There is also an earlier review doc on
   `change/review-codex-gate-lifecycle` (`docs/reviews/codex-gate-lifecycle.md`) that refused
   `19bf2bd` and then verified `c8589c7`; I did not read its contents, only the two commit
   subjects, and I reproduced the surviving-descendant falsification myself from the source.

## 1. Nested reservation bound to live ownership — half true

**Verified (positive).** A gate inside a gate inherits and does not queue:
`validate` requires the row to be `running`, the marker to match the originating id, the caller's
parent to be the holder, the recorded pid and the acquisition lease to be alive
(`GATE_LANE_HELD=slot:1`, `GATE_LANE_ORIGIN={id,dir,lease,holder_pid}` → `{"valid":true,...}`), and
it fails closed for a bare marker, a copied lease and a wrong id
(`evidence/refusal-and-validate.txt`: two `invalid_inheritance` refusals, exit 1). The wiring test's
nested scenario passes on the real consumers (`mode:"inherited"`, `request:1`, `waited_ms:0`).

**Falsified (the brief's demand).** Scenario, own state dir, real `acquire` CLI, holder pid = the
holder process exactly as `finish.mjs`/`merge-lane.mjs` do: the holder takes slot #1, its gate shell
starts a **nested gate** that validates its inherited admission (`valid:true`) and then keeps
running; the shell dies (the timed-out/`spawnSync`-timeout shell shape); the holder is killed
(`taskkill /F`). Result, from the lane's own rows:

- row #1 → `abandoned: holder pid 25468 gone, no gate pid was recorded and nothing the holder
  started for this slot is still running, lease 3b45d17b… not held; slot released after 11s`
  — while the nested gate (pid 73380, `ALIVE`, never finished) was running;
- the next caller was then **granted slot #2** at the same second the nested gate was verified
  alive (`evidence/tip-19bf2bd-nested-drain.log`, stages B and C) → **two gate executions under
  capacity 1**, i.e. the "gate lanes interfering / rows released while work is alive" class.

Mechanism, from the code and from a control I ran: release rests on `survivorsOf` →
`win32HolderChildren(holderPid)` = the holder's **direct children only**
(`scripts/gate-lane.mjs:250-303`). A descendant of a dead direct child is invisible. Control
(`evidence/control-direct-child-alive.log`): with the direct child provably alive before the kill
(Windows reports children `48188 node.exe 72136 bash.exe` of the holder), the shell died with the
holder and the lane released — there the claim was true; the failure is specific to work that
outlives the holder's children. The release is not only the `status` path: the acquirer's own
watchdog wrote it (`… so the acquirer released the slot after 11s`), so it is the live path, not a
tool artifact.

Note on fairness: `survivorsOf`/`gateStillRunning` are base code, not authored by this commit. What
is falsified is the commit's **claim**: with nested gates admitted by inheritance, a nested gate in
flight is neither protected nor drained when its owner dies, so "nested reservations are bound to
live ownership" does not hold end to end. The `--lease`/ancestry binding it adds is real and
useful; it is the release side that was left unbound.

## 2. Fixture isolation — holds, as measured

- `node scripts/test-gate-lane-wiring.cjs` at this tree: **exit 0, 38 checks, 0 skipped**, twice
  (`evidence/wiring-19bf2bd-a.log`, `-c.log`).
- **Two concurrent runs cannot see each other**: a concurrent pair both passed against distinct
  `mkdtemp` state dirs (`wa-gate-lane-wiring-A2oS0J\lane` vs `…igHDYD\lane`); an instrumented scratch
  copy of the same file run concurrently printed the same 38 labels in both processes
  (`evidence/wiring-instrumented-*-labels.log`). The production lane was never the state dir.
- **What was leaking, and the fix**: `test-parallel-finish.mjs` used to run its fixture gates with
  `process.env` unchanged, so a fixture gate inherited the caller's lane store (or the production
  default) and any admission marker. The commit pins `WA_GATE_LANE_DIR` to a private dir and clears
  `GATE_LANE_HELD`/`GATE_LANE_ORIGIN` (`scripts/test-parallel-finish.mjs:8-12`). Measured: run with
  a trap `WA_GATE_LANE_DIR`, it passes (26 checks, exit 0) and **creates nothing in the trap** (no
  `lane.sqlite`) — `evidence/test-parallel-finish-19bf2bd.log`.
- The wiring test now keeps its fixture root on failure instead of deleting it (evidence retention),
  and still asserts `dirname(root) === os.tmpdir()`.
- Anomaly, unexplained: one of my three plain runs reported `33 checks` with exit 0, while two
  others (and two instrumented concurrent runs) reported 38; all 38 `check()` call sites are
  unconditional and the 33-run's log is byte-identical to a 38-run modulo pids/paths
  (`evidence/wiring-19bf2bd-b.log`). I could not reproduce it or derive 33 from the source. I am
  reporting it rather than explaining it away: the self-reported count is the only witness to how
  many checks ran.

## 3. A refusal is still terminal — not weakened (strengthened for `finish.mjs`)

`acquire` with a 2 s budget against a held slot: **exit 75**, stdout 0 bytes (no receipt), the row
records `refused after 2s waiting for a slot …`, the holder keeps the slot, and the caller does not
run its gate (`evidence/refusal-and-validate.txt`). The refusal path in `gate-lane.mjs` is untouched
by the diff. For `finish.mjs` the commit makes the *unconsultable* case terminal too
(`mode:"unavailable"` now refuses instead of running unslotted), which the wiring test pins
(`gate_verified false`, `did not run`, no row) — strengthening, not weakening, item 3.

**But the two consumers now disagree**, and the file's own header is stale:

- `finish.mjs` fails **closed** when the lane cannot be consulted; `scripts/merge-lane.mjs` still
  fails **open** (`mode:"unavailable"`, gate runs, exit 0 — the wiring test asserts this in its skew
  check). One unreadable store therefore still permits an unserialised merge-lane gate.
- `merge-lane.mjs:505` sets only `GATE_LANE_HELD`; it never emits `GATE_LANE_ORIGIN`, which
  `finish.mjs:113` now requires. A nested `finish.mjs gate` under a **merge-lane**-held slot
  therefore refuses (`invalid_inheritance`) where it used to inherit. I could not find a reachable
  in-tree path (test.sh unsets `GATE_LANE_HELD` for the wiring test; `test-parallel-finish.mjs`
  fences itself), so this is latent, not demonstrated.
- The wiring test's header still claims an unconsultable lane "does not stop the gate: it runs, is
  still verified" while its own finish checks now assert the opposite (lines 15-17 vs checks 31-34).

## 4. Inconsistent wait budgets — **not addressed; open, as you suspected**

The commit does not touch `waitSecondsOf` (`gate-lane.mjs:370-375`, default 7200 s) or any caller's
budget: the budget is `--wait-seconds` / `WA_GATE_LANE_WAIT_SECONDS`, supplied by whoever asks. The
240 s / 421 s / 600 s refusals are therefore caller policy, and a 600 s budget against a 15 min gate
is a guaranteed refusal that discards the lane's whole run — reproduced in miniature in item 3
(2 s budget → exit 75 with a live, healthy holder). Nothing in this delivery fixes that, and the
commit's own change makes the waiting side *worse* under that policy: `finish.mjs` no longer
releases on an execution error, so a timed-out gate now holds the slot until someone runs
`reconcile --evidence`; every other lane then waits, and short-budget callers refuse. This is a
named residue of the delivery, acknowledged in its own Risk line.

## 5. New defects / interface reach

- **Slot held longer than the work (deliberate, but unoperated):** on `result.error` (`finish.mjs`
  timeout) the gate gives up its release and `unref`s the acquirer, so the row stays `running`
  until an owner supplies drain evidence. Correct against false death, but it converts a machine
  failure into a manual `reconcile` step, on a node whose only other exit is waiting or refusing.
- **Release narrowed:** `release` now requires `mode === 'acquire'`, a live ancestor, and a held
  lease. No in-tree caller releases a `run`-mode row (both consumers acquire), and the legitimate
  path still works — the wiring test ends with both rows `done` and the lane empty.
- **Row/receipt format:** additive only. The grant receipt gained `runner`/`inheritance`
  (`gate-lane.mjs:635-641`), `status --json` gained `read_only`, new `validate`/`inspect` commands,
  and `tryGrant` clears `depth`/`reason` on grant. The columns are unchanged, `wa-finish-gate.json`
  stays `schema:1`, and `merge-lane.mjs` / `finish.mjs` read only
  `grant.id|dir|label`, `code===75`, `gate_lane.{mode,request,waited_ms,reason}` — all still present.
  `skills/git-orchestrator/scripts/audit.mjs` consumes the receipt file and does not read
  `gate_lane`. No consumer breaks.
- `inspect` (read-only) works on a WAL store: `read_only:true`, `reconciled:[]` on a scratch store
  and on a **copy** of the live store (`evidence/inspect-live-copy.json`), which at review time
  showed row `#192 merge-lane 028380ac6d7d` holding the slot for ~95 s. I did not touch the live
  store beyond copying `lane.sqlite*`.
- Not fixed by this commit (unchanged base code): the ~12 `abandoned while waiting` rows come from
  `reconcileHolders`' `waiting` branch, which this diff does not touch.

## What I could NOT verify

- POSIX behaviour of `descendantOf`/`survivorsOf` (this host is Windows; the `/proc` branch and the
  "POSIX cannot prove drain" fail-closed path are unexercised).
- The live lane's own behaviour: I never ran `status`/`acquire` against
  `~/.wasm-agent/gate-lane`; my only live-store access was a read-only copy.
- `scripts/test.sh` / the smoke gate (excluded by the brief) and any real merge-lane landing.
- `c8589c7` beyond the one inherited-drain scenario; its `test-gate-drain.cjs` suite was not run.
- Whether the surviving-descendant hole costs anything in practice today, i.e. how often a gate
  shell dies while a nested gate outlives it.

## My branch and tip

`change/wa-session-childdispatchcd2db7d4-cc61-449e-9962-36ce699caff6` (from `da8dc891`), carrying
this verdict and `evidence/`; pushed. The delivery was not edited, nothing was merged, and no gate
slot was taken.
