# ready-r8c

Branch `change/deploy-hold-r8c` from `origin/main` `5a86366d`. Built and tested HERE on avell with
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-r8c`. Three commits, each with its own red/green, never pushed.

| commit | what |
| --- | --- |
| `980fdf9c` | r8c 1, the fix: a pause whose update did not happen says so |
| `d1d52280` | r8c 2: one kept message per session, not seven |
| `3e0a357e` | r8c 1, the REAL scratch-node row, and its `check` line in `scripts/fast.sh` |

## r8c 1 - a pause whose install never swapped anything

MEASURED (`deploy-hold-never-fails-our-load/paused-evidence.log`, 24/11): seven sessions sat 20-37 minutes after a
pause whose install never swapped anything - the 16:48Z and 17:06Z signals were a TEST LEAK writing the node's real
`deploy-pending.json`, not an install - and their resume wakes (`5ffa1bd2`, `d1cd45bc`, `8117d28f`) stayed pending
even through the real installs at 17:12-17:24.

Fix in `lua/core/deploy_pause.lua`: `M.NOT_HAPPENED` ("[deploy] the update did not happen"), `M.not_happened_text`
(names the target commit and how far past the marker's bound the release is), `M.marker_on_disk` (the marker as
data, expiry ignored) and `release_due` PREPENDING that line to the prompt of every resume row it releases.

Rows:

* `scripts/test-deploy-release-honest.lua` (real modules, real marker file, real tick, scratch ledger): a LIVE
  marker holds (control, no turn spent); a marker past its bound releases exactly ONE resume turn that carries the
  line. **RED** on base (the line does not exist; the module has no `NOT_HAPPENED`), **GREEN** here (13 checks).
* `scripts/test-deploy-release-node.sh` (**the row Fable asked for**, wired as `check deploy-release-node`): a real
  scratch `wa serve` (own HOME, port, ledger), a real turn IN FLIGHT (its first answer asks for a slow tool), a real
  marker written into THAT node's data dir mid-turn -> the turn PAUSES (1 model request); the marker is then REMOVED
  with nothing installed -> the node's own tick runs exactly ONE resume turn (one new model request) and the ledger
  row carries "[deploy] the update did not happen", read back with `sqlite3` from the node's own ledger.
  **RED** on base at the last assertion only ("no wake row ... carries the line"), which is the honest shape: the
  pause and the release already worked; the machine's own statement was what was missing. **GREEN** here.

Fences in both rows: the real `~/.wasm-agent` is never touched, the vault and provider variables are cleared, only
this row's ports are bound and only its own pids are signalled.

A finding the node row produced and its comment keeps: a turn that has NOT started is REFUSED by a waiting build
(`deploy_waiting`); the pause is the rule for a turn already in flight - so the row writes the marker mid-turn,
which is also what a deploy does to a node with work on it.

## r8c 2 - seven "kept: the start was refused" rows

Session `99946441` had SEVEN pending rows reading "kept: the start was refused, so this message is the session's
next turn" between 16:35Z and 16:49Z.

* **The writer**: `lua/core/chat.lua`'s `keep_refused_message` (r8a/12 - a message a refused start would have eaten
  must not be dropped). It scheduled a NEW wake on every refused start, so a runner that retried the same request
  seven times queued the same promise seven times.
* **Why r8a3's merge did not fold them**: that merge is `selfloop.withdraw_siblings`, and it folds RESUMES and
  `handle:` wakes of a session when a resume runs. A kept message is neither, so nothing ever looked at them. The
  promise was right; the queue of it was not.
* **Fix**: `selfloop.keep_pending_message(session, owner, prompt, reason, opts)` - a session has at most ONE pending
  kept message; a later refusal RE-ARMS it (words as they stand now, due in `in_seconds`) and answers its id;
  otherwise it schedules one. `chat.keep_refused_message` calls it.
* **Row** `scripts/test-kept-message-one.lua`, driving the REAL writer into the real ledger: seven refusals -> ONE
  row (the first id), the message as its prompt; a different message -> same row, words replaced; after the kept turn
  runs, the next refusal arms a fresh one. **RED** on base: "seven refused starts leave ONE pending kept message ...
  expected 1, got 7". **GREEN** here (23 checks).

## Not proven / not done

* The `--user`/system manager read from r8b is unchanged here; nothing in r8c touches it.
* `deploy-release-node` and `deploy-release-honest` were run individually and the first is wired into
  `scripts/fast.sh`; a narrowed fast-path run was not made in this round.
* The 20-37 minute stall itself was not reproduced against the live node (no permission to touch it): the rows prove
  the release-and-say-so behaviour, not the timing of the incident.
