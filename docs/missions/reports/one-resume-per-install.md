# one-resume-per-install - ready-1 (r8c 1 blockers + r8c 2 loss)

STACKED: this branch (change/one-resume-per-install) is on change/deploy-hold-r8c, which is on
change/selfloop-ledger-upgrade-2, on origin/main ffb5153e. Commits from this round, none pushed:

| commit | what |
| --- | --- |
| 718ce523 | r8c 1 BLOCKER: the release collapses the resume queue PER SESSION and leaves a held session alone |
| 04689288 | r8c 1 BLOCKER: the "[deploy] installed" line is decided by installed.txt (tree + bytes), not by host.build_identity |
| b2b78338 | r8c 2 LOSS: a different kept message is APPENDED, bounded, and the row says when the bound cut |
| 4b11bede | the two Lua rows were wired nowhere; they are rows of scripts/test.sh now |

Built and run HERE on avell (16 cores), CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-one-resume-per-install,
cargo build --release --offline with WA_CODEMODE_ALLOW_EMPTY=1 (the code-mode asset bundle is not needed by these
rows; nothing here touches code mode). Every suite run under flock -o ~/Work/missions/.suite.lock.

## The brief's premises, re-measured before writing code

* The supersede really had no session in it (lua/core/deploy_pause.lua, release_due: "... ORDER BY due_at,
  created_at LIMIT 1" inside a pcall), so it kept one row in the whole table. Confirmed by running the brief's
  shape (three paused sessions + one parked) against it: ZERO resume turns released.
* host.build_identity is the binary's commit (rust/wa-host build_info::COMMIT), and scripts/deploy.sh:1975 writes
  lua_tree=$COMMIT / lua_fast_path= into installed.txt. Confirmed.
* Two premises of the previous round were WRONG, and both are part of the blocker:
  1. record_pause stored opts.build = M.build_now() and NEVER wrote it into the pause record, and paused_build read
     record.build. The "installed" branch could not fire from the product's own data; the only test that saw it
     green wrote build= into the record by hand.
  2. In the release path opts.read IS the deploy-marker reader (selfloop.tick passes opts.deploy_marker), so
     paused_build and marker_on_disk were handing a marker reader a path and treating the answer as a pause record
     or a marker. The did-not-happen line therefore never named the marker's target from the tick.

## r8c 1 BLOCKER - one resume row per SESSION (718ce523)

release_due now collapses per session_id (each session keeps its own oldest pending resume - the row the release
then stamps), skips every session in self_wake_pauses on BOTH halves (nothing superseded, nothing made due: a
parked session's resume still fires once, after its own release), and logs a failing collapse by name instead of
swallowing it.

Row: scripts/test-deploy-release-honest.lua section 4 - the brief's shape: THREE paused sessions carrying 2, 3 and
4 queued resume rows plus ONE parked session with two overdue rows (the 24/11 shape). RED before the commit: "ONE
resume turn per paused session: three paused sessions, three turns, and none for the parked one: expected 3, got
0". GREEN after: 60 checks - three turns, one per paused session, each session left with exactly one
pending-or-dispatching row, and the parked session's rows keep their status, time and prompt.

## r8c 1 BLOCKER - the installed line is a fact about the RECORD (04689288)

M.installed_identity reads installed.txt through the one reader of that file (update.installed_record, the reader
change/version-names-the-tree uses) and answers { tree = lua_tree or commit, commit }. record_pause writes
installed_tree/installed_commit into the session's pause record; release_due reads it again and M.install_moved
answers true only for two records that disagree in one field (a scripts-only install moves the tree alone, a
release install names only commit=). "Cannot tell" is nil and is NEVER read as installed. M.build_now and
M.paused_build are gone. marker_on_disk and the pause record read opts.read_file, not opts.read.

Rows, both from the brief:

* scripts/test-deploy-release-honest.lua section 3: the pause record names the tree and the bytes the product read
  (written by record_pause, read back from the real pause-record file); a scripts-only install (tree moves, bytes
  do not) makes the release say "[deploy] installed", naming bbbb5555eeee and "was aaaa1111bbbb"; a marker that
  goes with the record unchanged says "[deploy] the update did not happen", naming the marker's target; and
  install_moved(nil, x) is nil. RED before: "the pause record names the tree this node runs: expected
  aaaa1111bbbb2222, got nil".
* scripts/test-deploy-release-node.sh (a real scratch node, own HOME, port, ledger; a real turn in flight; two cases
  end to end, each counted at the loopback model): a scripts-only install gives the ledger row "[deploy] installed",
  naming bbbb5555eeee, with exactly one resume turn; a marker removed with no install gives "[deploy] the update did
  not happen", naming deadbeefcafe, with exactly one resume turn. GREEN on this branch. RED on the base (my row, the
  base Lua, 0d12413b) - and it reproduces Fable's blocker on a real node: "FAIL: the released row does not say the
  build is installed: [deploy] the update did not happen: nothing was installed." after lua_tree= had moved.

## r8c 2 LOSS - a different kept message is appended (b2b78338)

selfloop.keep_prompt_text(kept, message, limit) appends in order ("\n\n" between messages), adds nothing when the
words are already the last thing kept (the identical-nudge collapse stays), and bounds the row at
M.KEPT_PROMPT_LIMIT (8000): the NEWEST words stay whole, the oldest go, the cut lands on a UTF-8 boundary, and
M.KEPT_CUT_TEXT is the first line so a session reading part of what was kept does not read as if it held all of it.
keep_pending_message answers appended/cut beside the id it reused.

Row: scripts/test-kept-message-one.lua - both messages of a different-message row stay, in arrival order; the same
nudge again adds no copy; a 5000 + 4000 character pair leaves ONE row bounded at the module's limit, keeping the
newest message whole, saying it cut, and dropping the oldest. RED before: "both messages are kept, in the order they
arrived ...: expected finish the mission step / and then report, got and then report". GREEN after: 36 checks.

## Regression rows (all green on this branch)

test-deploy-pause.lua (116 checks), test-deploy-wait.lua (59), test-deploy-resume.lua (25),
test-completion-deploy-wait.lua (16), test-peer-deploy-wait.lua (14), test-session-park.lua,
test-selfloop-no-starve.lua, test-selfloop-pause.lua. Each on its own scratch HOME/WASM_AGENT_HOME under flock -o.

Wiring (rule 3): scripts/test-deploy-release-honest.lua and scripts/test-kept-message-one.lua were written in the
previous round and run by NOTHING; both are rows of scripts/test.sh now (4b11bede), beside the deploy rows.
scripts/test-deploy-release-node.sh was already a fast-path row (check deploy-release-node).

## Findings this round did NOT fix (each needs its own row)

1. A SERVED CONVERSATION PAUSES ONCE AND NEVER AGAIN. lua/core/server.lua's agent_for caches ONE agent per thread,
   deploy_pause.at_boundary sets self.deploy_pause = marker and nothing clears it, so the next turn on that thread
   returns nil before reading the marker. MEASURED while writing the node row: the second pause never happened on
   the same thread (4 requests, no pause) and happened at once on a new thread. wa chat --once workers get a fresh
   process per turn, so this bites the node's own served thread - and it is the opposite direction from the brief's
   over-resume case, so it is not what produced 9a7edd49's three resumes.
2. The over-resume mechanism itself (the SECOND part of the brief, to be MEASURED) is untouched here.

## Texts to approve

1. "[kept] the earlier kept messages were cut here: a kept prompt is bounded at %d characters, and the most recent
   messages are what this row keeps" - NEW (selfloop.KEPT_CUT_TEXT), the first line of a kept prompt that had to
   drop the oldest messages. %d is selfloop.KEPT_PROMPT_LIMIT (8000).
2. "[deploy] installed: this node now runs <tree> (was <tree>)." - the wording is unchanged; the two values are now
   installed.txt's lua_tree=/commit= instead of the binary's build label (which never moved on a scripts-only
   install).
3. "deploy pause: the per-session resume collapse FAILED (the release still runs): <error>" - NEW, an operator log
   line; the same failure used to be swallowed by a bare pcall.
4. Test rows (operator output, not the model's): "  ok: the marker appeared mid-turn on thread <thread> (since
   <epoch>)", "  ok: the ledger row says '[deploy] installed', naming the new tree commit bbbb5555eeee (and not
   'nothing was installed')", "  ok: the ledger row says '[deploy] the update did not happen', naming the marker's
   target", and the failure dump (turn:, wakes:, sessions:, requests:, log:) that scripts/test-deploy-release-node.sh
   prints when a case fails.

## Not done in this round

* The acceptance row of the SECOND part (one model request per paused session per install, two installs two minutes
  apart) is not written; the mechanism is not measured yet.
* The full scripts/test.sh and the fast path were not run as a whole in this round; the rows above were run
  individually under the suite lock.
* docs/KERNEL.md / docs/SELF-LOOP.md are not updated for installed_tree/installed_commit or KEPT_PROMPT_LIMIT.


## ready-2 - the SECOND part, MEASURED (the open mechanism and the acceptance)

Commits after ready-1:

| commit | what |
| --- | --- |
| 6aff331b | the install's own four phases, measured on a node's own files and tick (the answer to "is there a gap") |
| b8118ffd | a conversation pauses again on its NEXT turn (agent:run clears the run's own pause mark), and the acceptance row runs two installs in ONE conversation |

### 1. Is there a phase of a real install in which nothing waits, so release_due fires inside it?

MEASURED, and the answer is NO. A real install's signals, in the order the product writes them
(scripts/test-resume-window.lua walks them with the real files and the node's own tick):

| phase | file that says an install is coming | release_due | paid turns |
| --- | --- | --- | --- |
| the request waits | `sentinel/requests/<id>.json` | 0 | 0 |
| the sentinel has claimed it, nothing else yet | `sentinel/claimed/<id>.json` | **0** | 0 |
| the swap | `deploy-pending.json` (the installer's marker) | 0 | 0 |
| the install is over | `sentinel/done/<id>.json` | **1** | **1** |

The suspected gap - "the request has left the box, the marker is not written yet" - is the CLAIMED lane, and
`lua/core/deploy_wait.lua` reads it (`M.LANES = { "requests", "claimed" }`, and its own comment says why). So a
release that required nothing waiting for two consecutive ticks would change nothing: nothing in that window is
released today. The 41-check row is green here and green on the base by design - it is a measurement row, and it
would only fail if this understanding were wrong.

### 2. Did the live session's three resume deliveries each make a model request?

Measured per KIND of delivery, on the tree as it stands:

* a resume RELEASED by a release makes exactly ONE model request - 2 installs in one conversation, 4 requests total,
  one per paused round and one per resume (scripts/test-deploy-release-node.sh, counted at the loopback stub);
* a resume that is DUE while a deploy waits is offered to the gate and given back with **zero** requests, the same
  row still pending and no duplicate armed (scripts/test-resume-window.lua, section 2);
* a resume re-armed because its dispatch was CUT by the install is a new paid turn, and it carries
  `deploy_pause.resume_prompt`'s own words ("[deploy pending] The deploy this session paused for is OVER, and the
  resume that was armed for it was lost").

That last one names the 18:15:43 message: the recorded text is `M.resume_prompt`'s, not the release's line, so that
delivery was `ensure_resumes` paying a lost resume, not a release. The two later messages (18:18:32, 18:19:00) follow
deliveries at 18:18:24 and 18:18:45 - two releases 21 s apart around ONE install, which is exactly what the base's
`release_due` did: it made EVERY pending resume row of EVERY session due, and a session could hold more than one (a
re-armed lost resume plus a fresh pause). This branch releases at most one row per session and `schedule` keeps one
pending row per session, so that pair collapses to one turn.
Source of the live facts: `deploy-hold-r8a4/r8c-all.txt` and `r8c-live2.txt` (the recorded deliveries and messages).
The live node's own ledger was NOT read: it is not this mission's store to read.

### 3. The acceptance (Fable's cut criterion), clause by clause

| clause | status |
| --- | --- |
| per install, at most ONE resume turn that makes a model request per paused session | **proven** on a real scratch node, requests counted at the stub: 4 for 2 installs, one per paused round and one per resume |
| a resume that finds a deploy waiting at its start ends BEFORE its first model request | **proven**: `scripts/test-deploy-wait.sh` (a served turn refused `deploy_waiting`, the stub called zero times) and `test-resume-window.lua` section 2 (a due resume while the request waits: 0 dispatches) |
| two installs two minutes apart = at most two such turns per session | **proven** with a gap of SECONDS (stricter) in ONE conversation: `COUNT(DISTINCT session_id) = 1`, exactly 2 resume rows, 4 requests |

### 4. What this round found and fixed on the way (it blocked the acceptance)

A served conversation could pause only ONCE in its lifetime: `agent_for` caches one agent per thread,
`deploy_pause.at_boundary` set `self.deploy_pause` on it and nothing cleared it, so every later turn of that thread
returned before reading a marker. MEASURED: the second install of the same thread paused nothing (4 requests, no
pause) while the same install on a fresh thread paused at once. `agent:run` clears the mark at the start (b8118ffd),
which is what "one pause per run" always meant, and the acceptance row now runs both installs in one conversation.

### 5. Not proven / not done

* Three sessions mid-turn across two installs at once was not measured: each run in these rows pauses one thread at a
  time. What the criterion needs per session is proven; the concurrent version is the same per-session rule applied
  three times, and nothing in the release crosses sessions now.
* The live incident was not re-read from its own ledger (not mine to read); its attribution comes from the recorded
  deliveries/messages plus the code.
* No new model- or operator-facing strings in this part (the run-start reset and the measurement row add none).


## ready-3 - when the fact is UNKNOWN, the release says unknown

Fable's ONE thing before the stack lands: `install_moved` returns nil when the pause record has no
`installed_tree`/`installed_commit` - which is every record written by the code that ran BEFORE this change, and
therefore every session paused by the install that is landing - or when the install record cannot be read, and the
release fell through to the did-not-happen line in both cases: "[deploy] the update did not happen: nothing was
installed", right after it installed.

The release now has THREE answers, never two (`lua/core/deploy_pause.lua`, `release_due`):

| `install_moved` | line |
| --- | --- |
| `true` (an identity moved) | `[deploy] installed: this node now runs <now> (was <was>).` - unchanged |
| `false` (both identities known and equal) | `[deploy] the update did not happen: nothing was installed ...` - unchanged |
| `nil` (one side missing) | `M.unknown_text(now)`, below |

`M.unknown_text` says, verbatim:

```
[deploy] the pause ended: this node runs <now12>. What it ran before the pause was not recorded, so this line cannot say whether an install completed.
This is the same request continuing, not a new one: verify the machine (`wa --version`, `git status`) before you claim anything about what was installed.
```

with `<now12>` = the install record's tree, first 12 characters (`bbbb5555eeee` in the row below), or
`an install whose record could not be read` when that is unknown too (Fable's second form).

Rows in `scripts/test-deploy-release-honest.lua` (81 checks, from 60):

* section 2 - a pause taken with NO pause record and a node with no install record: the released row carries the
  unknown line, names "an install whose record could not be read", and does NOT carry the did-not-happen line nor the
  installed one; the continuation prompt and the one-turn-per-session assertions are unchanged;
* 3e - **a pause record without the two fields** (the shape every record written by the code before this change has:
  asserted as `installed_tree == nil`, `installed_commit == nil` on the product's own record file), with the install
  record readable by the time of the release: the row carries the unknown line naming `bbbb5555eeee`, and neither
  the did-not-happen nor the installed line;
* 3f - a pause record that DOES name the tree, and an install record that cannot be read at the release: the unknown
  line, naming that the record could not be read, and neither of the other two.

RED before this commit: "the module names the line a release carries when it cannot tell (got nil)". GREEN after:
81 checks. The real scratch-node row (`scripts/test-deploy-release-node.sh`) is unchanged and still green, both cases:
its two pauses DO have records with identities, so its two answers stay "installed" and "the update did not happen".
Regressions green: `test-deploy-pause` 116, `test-deploy-wait` 59, `test-deploy-resume` 25, `test-resume-window` 41,
`test-selfloop-pause` 200, `test-kept-message-one` 36 - each on its own scratch home under `flock -o`.

Texts to approve (continuing ready-1's list):

5. `"[deploy] the pause ended: this node runs %s. What it ran before the pause was not recorded, so this line cannot
   say whether an install completed."` - NEW (`pause.M.unknown_text`); `%s` is the tree's first 12 characters, or
   `an install whose record could not be read`.
6. `"an install whose record could not be read"` - NEW (`pause.M.UNREADABLE`), the `<now12>` of the line above when
   the install record itself could not be read.
   (The second line of the unknown text is the wording the installed and did-not-happen lines already carry, so it is
   not a new string.)

