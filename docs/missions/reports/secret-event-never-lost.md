# secret-event-never-lost - a redaction always leaves its `secret_redacted` event

Mission `change/secret-event-never-lost`, worktree `/home/victor/Work/missions/secret-event-never-lost/wt`,
base `2104a4d8`. Everything below was built and measured HERE on avell (16 cores); committed locally, never
pushed. Scratch kept at `/home/victor/Work/missions/secret-event-never-lost/scratch/` (`loop1.log`,
`probe-drop.lua`, `probe-audit.lua`, `locker.py`, `base/` = a worktree of the base commit).

## The verdict

**A real loss, not a test race.** `telemetry.event` writes `harness_events` synchronously on the one
connection, and when the ledger refuses the write it **drops the row** - there is no queue, no retry and no
later attempt, so the row never arrives (`lua/core/telemetry.lua:96-120`: the `busy_now` short-cut, the
cooldown, and the bounded retry all end in `note_drop`). A dropped `secret_redacted` row is therefore a
lost audit record, and the redaction it describes has no record at all.

Fixed in `9fc7ed49` (`lua/core/telemetry.lua`, `lua/core/agent.lua`): audit records take a second path,
`telemetry.audit`, which pays the ledger's own patience and keeps the record owed instead of dropping it.
Pinned by `scripts/test-secret-audit.lua` (`420b0d09`, `b3ecfb9a`), which fails on the base.

**Fable's review of `d1777bce` asked for three changes, and they are in** (`6bedf472`, `bf590b06`,
`9c7d4b89`):

1. **"Kept" survives a kill.** `owed` was process memory, so the log line "this record is not lost" was false
   the moment the node was stopped. A refused record is now APPENDED, one JSON object per line, to
   `<data>/audit-spool.jsonl` (owner-only 0600, fsynced) BEFORE the caller is told `false`, through a new
   host capability `append_file` (`6bedf472`); the flush writes the spool's rows into the ledger and rewrites
   the file without them; a run's start and end flush it. A row is written EXACTLY ONCE: `harness_events.id`
   is UNIQUE and a duplicate insert is read as "already there", so a flush interrupted between the insert and
   the rewrite finishes instead of doubling the record.
2. **One patience per flush.** The first row pays the ledger's patience, every row after it gets ONE attempt,
   and the first refusal stops the flush and keeps the rest - ten owed rows on a jammed ledger used to cost
   ten patiences (200 s), now one plus at most one connection wait.
3. **Texts:** (1) and (2) stay as approved; (3) and (4) are now true (the record really is kept, on disk) and
   are unchanged from the words Fable approved. One NEW line (6) exists only for the case where the spool
   itself cannot be written - listed in §7 for approval.

## 1. Re-measured: the row does not fail under load in 200 runs

The brief's premise (main-health `2104a4d8`, 23/11 ~06:45Z, load from 3-4 workers, `test-redact-secrets.lua:130`)
was re-measured, not taken:

* `git log --oneline ae3cbb37..2104a4d8 -- lua/core/telemetry.lua lua/core/redact.lua` is EMPTY: the brief is
  right that nothing landed in that range, so the drop policy (`bfa2f776` and earlier) was already in place.
* line 130 of `scripts/test-redact-secrets.lua` is `ok(saw, "the node must record that it saw a secret, not
  redact it silently")` - the row is about the `secret_redacted` event, as the brief says.
* one run on `2104a4d8` here: `redact secrets ok (23 checks)`.
* the loop (`scratch/remeasure.sh`, six copies of the row at a time, each with its own scratch HOME and its
  own ledger, with a full `cargo build --release` running beside them): **200 runs, 200 ok, 0 failures**,
  56 s wall, load average 10.8-15.6 on 16 cores (`scratch/loop1.log`: 200 `ok` lines, `EXIT=0`, no kept home,
  which the loop does only for a failure).

So the flake needs a condition plain machine load does not create. It does not need one to be a real loss:
the drop path is unconditional on load and only needs the ledger to refuse a write at the moment the tool
loop records the redaction.

## 2. Where the event goes, and the three ways it is lost

The event is not asynchronous, batched or deferred. In the tool loop the redaction calls
`telemetry.event(...)` (`lua/core/agent.lua:3903` on the base), which calls `M.setup()` and then one
`INSERT INTO harness_events` through `host.sql_exec` - and the test reads the same table a moment later, so
there is no flush to wait for. `write()` (`lua/core/telemetry.lua:88-121`) can end in `note_drop` three ways:

1. `sqlite_busy.busy_now()` - the run's preamble was already refused a write (0 attempts);
2. `drops.cooldown_until` - any earlier telemetry write in this process was refused within the last
   `WASM_AGENT_TELEMETRY_WRITE_COOLDOWN_MS` (5 s by default; 0 attempts);
3. the bounded retry exhausted (`WASM_AGENT_TELEMETRY_WRITE_ATTEMPTS` 2, `WASM_AGENT_TELEMETRY_WRITE_MS` 8000).

None of the three is followed by anything. `M.event` returns nothing, so the agent cannot tell a written row
from a lost one, and the turn continues and answers as if the record existed.

**Measured, with a real competing writer** (`scratch/probe-drop.lua` + `scratch/locker.py`, a python process
holding `BEGIN IMMEDIATE` on the row's own ledger for 25 s while the event is written; WAL, one connection in
the node):

    READY sid=42d1deb0-afec-46fa-b2f3-c2e50d3d6d16
    secret_redacted_rows=0 events=0 dropped=1 elapsed_ms=20141 available=true
    [lua] telemetry: dropped harness_events insert after 1 attempt(s) in 20140ms: database_busy: INSERT INTO
    harness_events(id,session_id,run_id,span_id,kind...) could not get the lock within 20140ms (4 attempt(s),
    last: database is locked) (retryable) - this record is lost, the run is not

Two facts in that line beyond "zero rows": `available=true` (the READER cannot tell "no record was written"
from "nothing happened" - the loss is only in `drops`), and the node knew it had lost the record and said so
only on the log channel.

The same answer injected in-process against the base tree (`scratch/probe-base.lua`, the base's own agent
path - `telemetry.event` - with the host's `{"error":"database is locked"}` on the audited row's first insert):

    base secret_redacted_rows=0 drops=1 refusals_left=1 audit_path=nil

## 3. The fix: an audit record is not droppable, and never silent

`9fc7ed49` - `lua/core/telemetry.lua:275-355` (`write_durable` at 295, `M.audit` at 317, `M.owed` at 337,
`M.flush_audit` at 342) and `lua/core/agent.lua:3917-3927, 2174-2187`:

* `telemetry.audit(session_id, run_id, span_id, kind, phase, payload, at)` - `M.event`'s arguments, a
  different write path: `sqlite_busy.retry` with the ledger's own patience (`WASM_AGENT_SQLITE_RETRY_MS`, the
  budget a transcript write already gets), never the `busy_now`/`cooldown` short-cuts, and only a LOCK is
  retried (any other refusal is the same answer next time and is reported at once);
* it answers `true`, or `false` plus the ledger's own words - a caller is never told "recorded" when it was
  not. A record that still cannot be written is kept in `owed`;
* `telemetry.owed()` / `telemetry.flush_audit()`, and the count is carried in `events().audit_owed` and
  `drops().audit_owed`, so a reader can say whether a session's ledger owes a security record;
* the agent writes the redaction record through `audit`, appends the reason to the reader's status line when
  it could not be recorded, and flushes what is still owed at the end of the run (next to the transcript's own
  deferred flush, `lua/core/agent.lua:2174`), telling the operator how many are missing and why.

Measured with the same external lock (`scratch/probe-audit.lua`):

    lock held 7 s:   audit_recorded=true waited_ms=4838 secret_redacted_rows=1 owed=0 events_audit_owed=0 drops=0
    lock held 25 s:  audit_recorded=false waited_ms=20143 secret_redacted_rows=0 owed=1 events_audit_owed=1 drops=0
                     [lua] telemetry: the audit record secret_redacted is not in the ledger yet (... ) - it is kept
                     and retried, this record is not lost
                     then, after the lock was gone: flush_written=1 flush_left=0 secret_redacted_rows=1

### 3a. The spool ("kept" must survive a kill) - `bf590b06`, `6bedf472`

* `host.append_file(path, text)` (`6bedf472`, `rust/wa-capabilities/src/host.rs` `append_durably`): creates the
  file owner-only (0600), opens it `O_APPEND` (two processes spooling one line each keep both), writes, and
  `sync_all()`s it - the line is on the device when it answers `true`. It exists because `write_file` cannot
  do this: that one replaces the whole file atomically (read-modify-write, so two spoolers lose a row) and takes
  its mode from the target's existing permissions. Unit test: `host::append_file_tests::
  appends_each_block_and_creates_an_owner_only_file` (2 lines appended in order, mode 0600, empty path refused).
  The contract fake answers it too and the fake's promise is judged in `scripts/test-contract-host.lua`
  (the append really appends, refuses outside its root; 64 checks, 13 capabilities compared).
* `telemetry.audit` spools the row BEFORE answering `false` and returns `false, reason, "spooled"`; only if
  the spool cannot be written does it fall back to `owed` in memory and say so (`"memory"`).
* `telemetry.flush_audit()`: spool rows first (oldest first), then `owed`, one patience for the first row and
  one attempt for the rest, stop at the first refusal, keep the rest, rewrite the spool without what was
  written. `telemetry.spool_pending()` reads the file and reports how many rows it holds.
* `lua/core/agent.lua` flushes the spool at the START of a run (inside the start window, so a jammed ledger
  cannot stall the turn's first second - `pcall`, because a refusal must not stop the turn) and at the end.
* A line in the spool that does not parse is KEPT and named (`unreadable_spool_line`), never deleted: a record
  nobody can read is still a record.
* WHAT THE SPOOL HOLDS: the row - ids, kind, phase, time, and the payload the caller passed. For a redaction
  that payload is the tool name and the NAMES of the secrets found, never a value. Asserted in the row: after a
  redaction of a known secret the spool contains `"kind":"secret_redacted"` and does NOT contain the secret.

The cost is named rather than hidden: a jammed ledger can hold a redaction's turn for the ledger's patience
(`WASM_AGENT_SQLITE_RETRY_MS`, 20 s by default; an operator can bound it), which is the price of the record
existing before the answer does - accepted by Fable's review, and this is the line for the changelog. Ordinary
accounting records keep the old, droppable path.

Measured after the change, same external lock (`scratch/probe-audit.lua` is the pre-spool probe; the row below
is the shippped path, `scripts/test-secret-audit.lua`, 48 checks): the refused record is spooled (mode 600,
no secret in the file), a SIGKILLed process loses nothing, and the next process writes the row exactly once.

## 4. The test, and why it can fail

`scripts/test-secret-audit.lua` (`420b0d09`, `b3ecfb9a`) runs the real agent loop on a real ledger in its own
scratch home (`scripts/lib/scratch-home.lua` guard first: it REFUSES to run on the operator's store, exit 2)
and injects exactly one answer: the host's own `database is locked` on the audited row's insert, on a ledger it
otherwise leaves untouched. The contract fake (`scripts/lib/contract-host.lua`) cannot serve that - it scripts
one answer per statement and has no SQLite behind it, and this row needs the real schema and the real loop -
so the injected answer is a wrapper around the real host, said in the file's own header.

48 checks, four phases:

* (1) two refusals during the turn: the turn runs, the transcript has no secret, **and the
  `secret_redacted` row is in the ledger**, nothing owed, `drops().count == 0`, and the two refusals really
  fired (a row that cannot fail catches nothing);
* (1b) one refusal with the audit path's patience at one attempt: the record is kept through the turn and the
  RUN's own flush writes it before the run returns;
* (2) a ledger that refuses for the whole patience: `audit` answers `false` with a reason, the record is
  counted owed, **the spool file holds it** (the row reads it back: it names the kind, does NOT contain the
  secret, is a file, is mode 600, and `spool_pending()` says 1), nothing claims a row that was not written,
  and a flush after the refusals stop writes it and empties the spool.
  Every ledger READ in the row fails loudly when the ledger cannot be read (`available == false`), instead of
  reading "could not look" as "nothing there".
* (3) A KILL CANNOT LOSE IT, across processes: the row starts a real child (`scripts/lib/secret-audit-spool-child.lua`,
  this tree's binary from `WA_FAST_BIN`/`WA_BIN` - it refuses to run without one rather than pass), the child
  spools a refused record and is KILLED by `timeout -s KILL` (asserted: exit 137, and the ledger gained no row),
  and the parent - a NEW process - flushes it: exactly one row with the child's `run_id`, and a second flush
  writes nothing more.

Discrimination, measured rather than argued:

* against the base (`scratch/base`, `git worktree add` of `2104a4d8`, the same row copied in):
  `lua error: ...:31: telemetry must offer a durable audit write (telemetry.audit)`, exit 1;
* against the base's own path, with the same refusal (`scratch/probe-base.lua`):
  `base secret_redacted_rows=0 drops=1` - the property itself fails there, not only the API guard;
* against the BASE CODE AND THE BASE BINARY, which is what `scripts/test-discriminates.sh` asks for once a
  branch touches `rust/` ("build the base binary to judge it"): the base worktree at `2104a4d8` with this
  branch's test files copied on top, built at `scratch/base-target` (`4m 20s`), run as the gate does:
  - `scripts/test-secret-audit.lua` -> `lua error: ...:31: telemetry must offer a durable audit write
    (telemetry.audit)`, rc=1: DISCRIMINATES;
  - `scripts/test-contract-host.lua` -> `attempt to call a nil value (field 'append_file')`, rc=1: the base
    host has no such capability, i.e. the gate's `new-symbol` verdict - it exercises code the base lacks.

Wiring: `scripts/test.sh:1790` runs the row next to `test-redact-secrets.lua`, and the fast path picks it up
because `scripts/fast-path.exclude` does not list it (a `test-*.lua` not listed there is in the fast path).
`scripts/test-redact-secrets.lua` is untouched: its assertions are unchanged, and it still prints
`redact secrets ok (23 checks)`.

## 5. What I did NOT verify, and what is still unknown

* **Which refusal produced the 23/11 main-health failure is not proven.** No log of that run was kept
  (`~/.wasm-agent/main-health` keeps result JSONs and per-row logs from other runs; none of them contains the
  failing row), so I cannot name the trigger. What is proven is that the drop policy is the only mechanism in
  this code that can produce exactly that signature (redaction done, transcript clean, no event), and that it
  loses the record for good.
* **I could not make the row fail with machine load alone**: 200 runs, 6 concurrent, cargo build alongside -
  all green. If the health flake has a second cause, it is still unnamed; the durable path makes it moot for
  this record either way `M.event` is not used for it any more.
* **The full fast path was NOT run to completion here.** It was started on the five touched/neighbouring
  rows under the suite lock (`flock -o ~/Work/missions/.suite.lock`, the operation ran 951 s) and never
  acquired it: two other missions' suites held it for the whole window; the waiting process was cancelled
  before it ran a single row (`scratch/fast.log` is 0 bytes), so nothing of this branch's fast run has a
  verdict. What WAS run, individually and green, on this node AFTER Fable's three changes:
  `test-secret-audit.lua` (48 checks, incl. the kill/restart proof), `test-contract-host.lua` (64 checks, 13
  capabilities compared), `rs wa-capabilities append_file_tests` (1 passed), `test-redact-secrets.lua` (23),
  `test-redact-secrets.lua` (23), `test-telemetry-incremental.lua` (40 checks), `test-telemetry-lock-run.lua`,
  `test-telemetry-lock-holder.lua`, `test-hook-events.lua` (28), `test-durable-steering.lua`,
  `test-stalls.lua` (16); and the always-on contract checks the fast path runs, directly:
  `sync-prompt-docs.sh --check` (ok), `check-instructions.mjs` (PASS, 79 checks/371 files),
  `test-landing-queue.mjs` (100 checks), `test-orphan-tests.mjs` (336 wired), `test-session-liveness.mjs`
  (14 checks). The land gate's `scripts/test-discriminates.sh 2104a4d8` answered `1 discriminating, 0
  blocking` while the branch was Lua-only (`scratch/discriminates.json`); once the branch touched `rust/` it
  reports both Lua rows `unrevertable` ("build the base binary to judge it"), which is why the base binary was
  built and both rows were run against base code + base binary by hand (§4).
* **When the spool is drained, stated exactly.** A node drains it at the START of a run (inside the start
  window) and at the END of a run, and at the front of the next audit record. A node that never runs a turn
  (a bare `wa status`, a UI poll) never drains it - no scheduler or watcher was added, because the review asked
  for "a starting node flushes the spool once the ledger answers" and the run boundary is where this node is
  about to write anyway. While refusals continue the spool GROWS (one line per refused record); nothing prunes
  it and nothing bounds its size on disk. That is the honest shape of a durable record with no sweeper, and it
  is the next thing to decide if a node ever sits jammed for hours while redacting.
* The row's phase (3) needs this tree's binary (`WA_FAST_BIN`, or `WA_BIN` which `scripts/test.sh:1790` now
  sets). It REFUSES with a named reason when neither is given - it does not skip and it does not pass.
* Out of scope, reported not changed: `lua/core/bash_mode.lua:69` (the operator's own `/bash` command) redacts
  a result with `redact.value` and records NO `secret_redacted` event - the same silence in a second path, a
  candidate for its own round.

## 6. Pre-existing failures (measured on the base, not mine)

`node scripts/check-temp-retention.mjs`: 55 `failed` lines on `2104a4d8` and the same 55 on this branch; the
new row is not among them (it writes its leak file into its own scratch home, not the temp root).

## 7. Texts to approve (new or changed operator-facing strings)

1. `lua/core/agent.lua:3932-3935` - appended to the redaction status line ONLY when the record could not be
   written: `"; its audit record is not in the ledger yet (<reason>) - the node keeps it and retries"`
   (APPROVED by Fable's review of `d1777bce`, unchanged)
2. `lua/core/agent.lua:2189-2191` (end of a turn, only when records are still owed):
   `"%d security record(s) are not in the ledger: the ledger would not take them (%s)"` (APPROVED, unchanged)
3. `lua/core/telemetry.lua:424-426` (node log line, one per record kept in the SPOOL):
   `"telemetry: the audit record %s is not in the ledger yet (%s) - it is kept and retried, this record is not lost"`
   (APPROVED once item 1 of the review is true - the record is on disk now, so it is)
4. `lua/core/agent.lua:2192` (node log line, end of a turn):
   `"telemetry.audit: %d security record(s) not stored: %s"` (APPROVED, unchanged)
5. Test row output (gate): `"secret audit ok (N checks)"`; refusal path: `"REFUSED test-secret-audit.lua: ..."`.
6. **NEW, awaiting approval** - `lua/core/telemetry.lua:430-432`, the case where even the spool cannot be
   written (no data directory, the host refused the append): `"telemetry: the audit record %s is not in the
   ledger yet (%s) and could not be spooled (%s) - it is kept in this process until the run ends"`. It exists
   because the approved line (3) would be a lie on that path, and the node must not go quiet there.
7. **NEW, awaiting approval** - `lua/core/telemetry.lua:493-494`, node log line when a flush wrote rows but
   the spool rewrite failed: `"telemetry: the audit spool could not be rewritten after a flush (%s); its rows
   are in the ledger and a later flush will recognise them"`.

## 8. Proposed FACTORY.md / HANDOVER.md text (APPROVED by Fable's review, applied by the orchestrator - NOT written here)

FACTORY.md (rule 16 area, next to the "a test that cannot fail cannot catch anything" rule):

> An AUDIT record is not an accounting record. A security fact - "this node saw a secret and redacted it" -
> is written through `telemetry.audit`, which pays the ledger's patience and keeps the record owed; it is
> never dropped by the accounting path's busy/cooldown short-cuts, and it is never silent: the caller gets
> true, or false plus the reason, and the operator is told. `scripts/test-secret-audit.lua` proves it with an
> injected `database is locked`.

HANDOVER.md (one line, for whoever reads the board next):

> 23/11 secret-event-never-lost: main-health's red row on `test-redact-secrets.lua:130` was a REAL loss, not a
> flake - `telemetry.event` drops a record the ledger refuses and nothing retried it. Fixed: `telemetry.audit`
> (9fc7ed49) + `scripts/test-secret-audit.lua` (420b0d09/b3ecfb9a), which fails on the base. 200 runs under
> load did not reproduce the original flake; the drop path is its only mechanism.
