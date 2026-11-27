# Is the law worth it? The trial (27/11, Victor: "check if it's worthy; you can apply it")

Three laws were applied to this tree for real, before the guard row existed, so the law earns its place by numbers rather
than by intent: `ARCHITECTURE.md` laws 17 (one question, one owner), 18 (if one fits another's path they are duplicates and
are joined) and 10 (a duplicate is fixed where it is found).

## 1. The sweep: how many answers each question has

| question | answers found | differ today? | where |
| --- | --- | --- | --- |
| How long may this wait? | 24 constant names in one family (`*WAIT_MS`, `*_TIMEOUT_MS`), 7 of them answering the shared budget | YES - 2 000 / 15 000 / 60 000 / 120 000 in the same family | counted, not redone: the waits are joined by `whatsapp-read-waits-on-a-future`, `email-read-waits-on-a-future`, `component-hosts-share-the-wait`, `stt-question-returns-a-future`, `the-turn-is-drawn-once`'s sibling `the-turn-is-drawn-once` is turn drawing |
| How is a turn drawn? | 2 (`lua/core/cli_view.lua`, `lua/core/chat.lua` replay) | YES - two renderers for one shape | queued: `the-turn-is-drawn-once.md` |
| How does a build get installed? | 3 deciders (`lua/core/update.lua`, `wa update`, `scripts/deploy.sh` + `scripts/upgrade.sh`) | YES - each decides its own precondition | queued: `update-is-one-line.md` |
| What do we do when the database is locked? | 3+ (`lua/core/sqlite_busy.lua`, `backup.lua`'s `busy()` predicate, `backup.lua`'s own `WA_BACKUP_BUSY_TIMEOUT_MS`) | YES - the backup matched any text with "busy" or "locked" while the owner matches named spellings, and used its own patience | **JOINED: `d580fdf1`** |
| How do I run one statement and read the host's answer? | 4 (`agent_control.lua`, `backup.lua`, `completions.lua`, `done_gate.lua`) | YES - four policies around one pcall/decode/refuse body, and four different answers to "nothing came back" | **JOINED: `8801b311`** |
| Where does the node keep its files? | 1 owner (`lua/core/paths.lua`) + 1 re-derivation (`lua/core/tool_progress.lua` `M.dir`, the only place `WASM_AGENT_DATA` is honoured) | PARTLY - the host does not resolve `WASM_AGENT_DATA` at all, so joining would MOVE a behaviour into `paths` for every caller | named, not joined: a blast radius bigger than this task |
| The step retries | 4 (`sqlite_busy.retry` for the database, `spells.lua` for spell steps, `deploy_wait.lua`/`upgrade.sh` for an install, `subagents` for a child) | not measured | counted only |

## 2. The two joins (each its own commit, the callers' rows green before and after)

**`d580fdf1` - the backup takes its lock policy from `sqlite_busy`.** `backup.lua` lost its `busy()` predicate, its
`WA_BACKUP_BUSY_TIMEOUT_MS` knob (15 000) and its own `PRAGMA busy_timeout` number, and gained `sqlite_busy.is_busy` and
the owner's new `patience_ms()`. 4 files, +38 / -24. Rows: `test-backup-live.lua` (56 checks), `test-backup-restore.lua`,
`test-remote-update.lua` (152 checks) - green.

**`8801b311` - one owner for running a statement.** New `lua/core/sql_answer.lua` (`run -> value, why`, never raises);
`agent_control`, `backup`, `completions` and `done_gate` keep their own policy (raise with a prefix, or return the reason)
and call the owner. 4 files, +43 / -21, of which 28 lines are the owner itself. Rows: `test-agent-control.lua` (41 checks)
and `test-ledger-transactions.lua` (197 checks) green.

## 3. The bugs a single owner would have prevented (with the commits)

* `4e4b5a42` *fix(memory): a lock no longer ends a run - waited for, named, and proved under contention* and `04d2696d`
  *fix(telemetry): a record is worth less than the run it describes* are the SAME fix, made twice in two modules, days
  apart, each with its own new test suites (283 and 212 lines). Under law 9 they are one fix.
* `8a7b2131` *feat(sqlite): one contention policy for every store, and a name when the lock cannot be had* created the
  owner - and `backup.lua` still kept its own predicate and its own number for it afterwards. That is the drift law 17
  names, measured: the join above removes a second answer to a question that had an owner for nine days.
* The waits: `whatsapp_index` and `email_index` each carry `WAIT_MS = 2_000` and each hands the caller a job id past it,
  so a slow index read reaches the model as a handle in two independent places (the briefs above own the join).

## 4. What broke, what got harder

* One real break, mine: `backup.lua` used `sql_answer.run` without the `dofile` that defines it; the full suite caught it
  (`attempt to index a nil value (global 'sql_answer')` in `test-backup-live.lua`, `test-backup-restore.lua` and
  `test-remote-update.lua`), it was fixed and all three rows re-run green. That is the cost of joining: the suite is the
  only thing that checks a call site still has its owner.
* `test-done-gate.lua` fails 30 of 89 - identically on the tree WITHOUT this branch (`eca8208a`, run in a detached
  worktree): pre-existing, not caused here, and not fixed here.
* The full `scripts/fast.sh` run on this branch (four suites sharing the node's lock, load average 6-11) also failed
  `landing-queue`, `landing-baseline`, `esc-stops-pty`, `status-limits-pty`, `tmp-cleanliness`, `install-guards`,
  `test-release-sign`, `test-accept-two-process` (hung), `deploy-alive-hold`, `health-waiting-on-op` - the same rows fail
  on a tree that does not contain these changes (a `fast.sh` run of a sibling branch, `eca8208a`, in this session's log),
  and `landing-queue` refuses a worker by design (`lane_token`). No landing baseline is recorded for main yet, so this is
  evidence by comparison, not a recorded baseline.
* An operator knob disappeared: `WA_BACKUP_BUSY_TIMEOUT_MS`. It is documented as gone in `docs/RELEASE-UPDATE.md`, and
  `WASM_AGENT_SQLITE_RETRY_MS` is the one knob for the same question.

## 5. Time

Sweep ~20 min; join 1 ~25 min (the row's own `busy_timeouts` assertion had to move to the owner's knob); join 2 ~30 min
(four call sites, two of them with their own error prefixes to preserve); the full suite one 31-minute run on a loaded
node. The guard row paid for itself immediately: it named 24 private waits instead of the 4 a draft found, and two
answered questions the sweep had missed.

## 6. Verdict: KEEP

Numbers: two joins removed 45 duplicated lines and one undocumented second answer (the predicate), made one operator knob
go away, and turned four error policies into one owner with four policies. The guard row then found 20 second answers my
first draft had missed, two of them whole questions.

Cost: a join can break a call site silently until the suite runs (measured above), and the law does NOT pay where the join
would move a behaviour into the owner for every caller (`tool_progress`'s `WASM_AGENT_DATA`, the turn renderer): those are a
brief, not a subtask. So keep the law with that boundary: **a duplicate is fixed in the task that spots it when the owner
already exists; creating the owner is its own brief.**
