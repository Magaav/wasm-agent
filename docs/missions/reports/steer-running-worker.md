# steer-running-worker - a change reaches a worker that is already running

Branch `change/steer-running-worker`, base `8862b600`. Report written from the diff: every claim below names
the commit that implements it (`git show <sha>`) or says it was not verified.

## What the brief got right, and what re-measuring changed

| premise | re-measured | where |
| --- | --- | --- |
| the worker reads brief.md once, piped in at start | true: `stage` writes `prompt.md` once, and the runner launches `"$WA" chat --once "$(cat "$M/prompt.md")"` | `scripts/mission.sh` (stage + the `RUNNER` heredoc), unchanged by this branch |
| a mission worker is a `wa` session the node's steering can reach | true, and it was the whole missing piece: `wa steer <session> "<note>"` writes a `steering_inbox` row for the run in flight, and the run consumes it at its next context boundary, atomically with its read receipt | `lua/core/steering.lua`, `lua/core/steer_cli.lua`, `lua/core/agent.lua:2701` |
| the orchestrator "could not message it (resource_busy)" | `resource_busy` is not a message a caller sees for this: it is a run-failure pattern name. What a caller hits by opening a second turn on a live session is the session **claim** the run holds | `lua/core/run_failure.lua:89`, `lua/core/resources.lua:23` |
| `scripts/mission.sh` is the mechanism, and `~/Work/missions/<name>/run.sh` its runner | true for docs and for this script; but the **live factory driver on this node does not use it**: `drive.sh` launches `~/Work/missions/launch.sh` + `start.sh` (systemd), and the CLI has a third copy of the same loop (`wa mission launch/start/resume/status/stop`, `lua/core/mission.lua`) | `scripts/drive.sh:508`, `lua/core/init.lua:680` |

Three measurements the brief did not have, each of which changed the design:

1. **The CLI prints its session id when the turn ENDS, not when it starts** (`wa: session <id> ok`,
   `lua/core/chat.lua:727`), so during a live turn neither `run.lock` nor `err.log` names the worker: the
   fixture prints `note - run.lock while the turn runs: SESSION=""`. A live session can only come from the
   node's own session list, matched by the mission's title (the first line of `prompt.md`).
2. **`wa mission resume` spawns its runner through `host.exec`, whose child environment is scrubbed**:
   measured in the fixture, the resumed CLI answered "No provider is configured and nothing in memory
   matched" and made **no model request**. A mission's provider settings arrive exactly this way
   (`start.sh` hands the worker wa-serve's `serve.env`), so amend writes its own runner instead (`6f6e422e`
   docs, `84e221eb` code) - see "Not done" for what that says about `wa mission resume` itself.
3. **A brand-new node store makes `start` refuse [unknown]** - `node_presence` cannot read
   `memory.db`, so the first launch on a fresh node is refused until the store exists. The fixture asks the
   node one question (`wa sessions`) to create it, the way the node always does.

## The job, item by item

### 1. One command (`84e221eb`, `6f6e422e`)

```
scripts/mission.sh amend <name> <file|->      # a change from the planner, while the worker is running
```

- **Appends** the text to `<mission>/brief.md` under `## Amendment <UTC> (from the planner)`, and checks
  that every byte that was there before is still there (the append is verified, not promised). `prompt.md`
  is never rewritten, so the worker's prompt prefix - and its cache - is untouched; the fixture asserts
  `prompt.md` is byte-identical across the amend.
- **Delivers** the same text, labelled `[amendment <UTC> from the planner]`, through the product's own
  steering door (`wa steer <session> --json <text>`): a durable `steering_inbox` row for the run in flight,
  consumed at its next context boundary.
- **Finds the session from the node** (`754197cc`), in this order: a run the node says is in flight
  under the mission's title (the first line of `prompt.md`); then a run the node records as working in the
  mission's directory (`session_presence` + `/proc/<pid>/cwd`, which is what covers a mission staged the way
  the factory's own launcher stages one - brief first, no marker); then `run.lock`'s `SESSION`; then the
  `wa: session` line a finished run left in the logs.

### 2. Between turns, finished, and never twice (`84e221eb`)

- Run in flight -> `wa steer`, recorded in `amend.log` with the node's receipt.
- Nothing in flight (between turns, or `done` carries its rc) -> the command **says so** and resumes that one
  session **with the amendment as the message of its next turn** (`amend-run.sh`, written by amend,
  `wa chat --resume <id> --once <label>`), and the turn's rc lands in `done`. The resume is a launch, so it
  runs under the mission's own `start.flock` and writes `launch.pid`.
- **Never two deliveries**: the amendment's identity is 16 hex of sha256 of its text, and `amend.log` keeps
  one line per attempt (`<sha> <stamp> <state> <session> <receipt> <detail>`). Passing the same file twice
  appends nothing and delivers nothing; the second call reports what the **node** says became of the first
  (`read` with the message it became, `queued`, or `deferred`). Only `deferred` (the run settled before
  its boundary, so the worker never consumed it) and `undelivered` are delivered again - with the same stamp.

### 3. The prompt says what an amendment is (`23fac954`, `84e221eb`)

Both prompt builders carry it: `scripts/mission.sh` (`stage`) and `lua/core/mission.lua`
(`prompt_text`), so a worker started by either mechanism is told. The fixture asserts the staged prompt has
it; `scripts/test-mission-verb.sh` asserts the CLI's does.

### 4. The fixture (`84e221eb`)

`node scripts/test-mission-amend.mjs`, 43 checks, wired into `scripts/fast.sh` as `check mission-amend`.
It is not a stub: `scripts/mission.sh` stages and starts the mission itself, the worker is a real
`wa chat --once` process against the fixture's own node store, the amendment is sent by a separate
`scripts/mission.sh amend` process while the turn is held at its first model request, and the proof that the
worker saw it is its **next** model request. The only substitute is the provider: a local SSE fixture (the
shape `rust/wa-capabilities/src/host.rs` parses), so no model and no network.

It proves, among the 43: the note is appended with its stamp and the prompt prefix is untouched; the inbox row
is durable before delivery; the next context boundary sees the note **exactly once**, labelled; it is in the
transcript once as a user row; the receipt is `read` with its message; the same file twice appends and
delivers nothing; a finished worker is resumed and the resumed turn's first user message **is** the amendment;
the refusals (no session, empty note, no brief, usage) append nothing; and a worker whose prompt has no title
marker at all (the factory's launcher shape) is steered too, found through the node's presence record.

**It fails on the base**: run in a worktree of `8862b600` it stops at check 3 - the base prompt has no
`## Amendments` section and the base script has no `amend` verb.

### 5. FACTORY.md (`6f6e422e` cites the docs; the rule itself is outside the repo)

Rule 13 was appended to `~/Work/missions/FACTORY.md` (the factory's own rule file, which is NOT in this
repository - so it cannot be cited by commit; it is a file under `~/Work/missions`, 19 lines added, rule text
in "Texts to approve" below). The repository's knowledge document, `docs/MISSIONS.md`, gained step **4b**,
the two new files in its mission-directory table, and the three measurements above.

## Tests run, and what they were run on

| row | result | note |
| --- | --- | --- |
| `node scripts/test-mission-amend.mjs` | **43 checks passed** | `WA_BIN=/home/victor/.local/bin/wa` (a build of `8862b600`, this branch's base) |
| the same file, in a worktree of `8862b600` | **FAILED after 2 checks** | it discriminates (rule 16) |
| `bash scripts/test-mission.sh` | **282 checks ok** | with the same binary |
| `bash scripts/test-mission-verb.sh` | **49 checks ok** | includes the two new prompt assertions |

Both bash rows ran under `flock -o ~/Work/missions/.suite.lock`. The full fast path was **not** run: only the
rows this change can affect, and the landing's own gate is where the whole thing is judged.

Nothing here built, installed, landed, deployed or touched a peer: no `wa land`, no deploy, no fleet call, no
change under `~/.local/bin` or `installed.txt`, and no test wrote outside its own scratch home.

## Texts to approve

Every model- or operator-facing string this branch adds, verbatim (the `%s` are the arguments):

1. usage line: `  scripts/mission.sh amend  <name> <file|->        # append a change to brief.md AND deliver it to the worker` / `                                                   # running now, at its next context boundary`
2. queued: `mission: amendment %s queued for run %s (session %s, receipt %s): the worker sees it at its next context boundary, once`
3. resumed: `mission: amendment %s appended to %s; the worker is not in flight (state %s; %s), so session %s is RESUMED with it (pid %s): the amendment is the message of its next turn`
4. already read: `mission: already amended: %s (sha %s) was read by the worker at its next context boundary (receipt %s, message %s); nothing was appended and nothing was delivered again`
5. still queued: `mission: already amended: %s (sha %s) is still queued for that run (receipt %s); the worker reads it at its next context boundary, and it is not delivered twice`
6. deferred, delivering again: `mission: %s (sha %s) was never consumed - the run settled before its next context boundary - so the worker is resumed with it now (not appended again)`
7. already resumed: `mission: already amended: %s (sha %s) is what session %s was resumed with, so it is the message of that turn; nothing was appended and nothing was delivered again`
8. undelivered, trying again: `mission: %s (sha %s) is already in %s and was never delivered (%s): delivering it now, without appending it again`
9. receipt unreadable: `mission: cannot tell whether %s (sha %s) reached the worker: the node answered '%s' for receipt %s, and unknown is not delivered` + `mission: nothing was appended and nothing was delivered - read it (wa steer %s --status), then run this command again once the node answers`
10. no session: `mission: %s is in %s, but no session of this mission is running or recorded, so nothing was delivered` + `mission: start it once it is staged (scripts/mission.sh start %s) and run this command again - the text is already there and is not appended twice`
11. bad session record: `the session recorded for %s is not a session id: [%s] - nothing was delivered. run.lock and err.log are what to read`
12. node could not be asked: `mission: %s is in %s, but the node could not be asked whether a run is in flight for session %s ('%s steer %s --status --json' answered nothing), so nothing was delivered` + `mission: read it by hand (wa steer %s --status), then run this command again once the node answers - stop here if that refuses too, because unknown is not a delivery`
13. node refused the note: `mission: %s is in %s, but the node refused the note, so nothing was delivered: %s` + `mission: clear it by hand: read the run (wa steer %s --status) and run this command again when it answers - the text is not appended twice`
14. settled between the reads: `mission: the run settled between the two reads (the node answers no_active_steering_target), so the worker is between turns: it is resumed with the amendment`
15. lock held: `refusing: another 'start', 'clean' or 'amend' of %s is inside its check-and-launch right now (flock -n on %s), so the resume was not attempted. %s is in %s and undelivered: run this command again when that one exits (nothing to clear)`
16. runner unwritable: `cannot write %s/amend-run.sh, so nothing was resumed: %s is in %s and undelivered`
17. empty amendment: `the amendment in %s is empty: nothing to append and nothing to deliver`
18. too large: `the amendment is %s bytes; the steering door takes 32768 including the label, so at most 32000 here - split it into two amendments`
19. no brief: `no brief at %s: amend appends to the brief the worker was started from, and this mission has none to append to`
20. no wa: `no 'wa' on PATH (set WA_BIN): the note reaches the worker through 'wa steer', and a command that cannot deliver says so instead of writing the brief alone`
21. no mission / unreadable file / append failed / prefix changed / usage: `no mission at %s`; `cannot read %s: nothing was appended and nothing was delivered`; `cannot append to %s: nothing was delivered`; `the append to %s changed bytes that were already there - stop and read that file by hand: %s was delivered to nobody`; `usage: mission.sh amend <name> <file|->`
22. the prompt section (both builders): `## Amendments` / `The brief above is what you were started with. A change can arrive WHILE you work: it reaches you as a message that begins "[amendment <UTC> from the planner]", and the same text is appended to brief.md under that stamp. An amendment is NEWER than the brief where the two disagree: act on the amendment, not on the sentence it replaces. Name every amendment you acted on in your report with its UTC stamp, and name the ones you did not act on with the reason.`
23. the note as the worker sees it: `[amendment <UTC> from the planner] <text>`; and the brief's block: `## Amendment <UTC> (from the planner)` followed by the text.
24. FACTORY rule 13, as appended to `~/Work/missions/FACTORY.md` (outside this repository): its heading is `## Rule 13 - a change reaches the worker that is ALREADY RUNNING (Victor 22/11: "yes (steering?)")`, and its body states the command, "never rewrite the brief and never re-prompt the worker with the whole brief again", "an amendment is NEWER than the brief where the two disagree and every amendment acted on is named in the report by its UTC stamp", and "this is steering a RUN, not a new launch".

## How Victor tests it

```
# 1. start any mission (this is the factory's own path on this node, but any of the three works)
scripts/mission.sh stage demo origin/main ~/Work/missions/demo/brief.md
scripts/mission.sh start demo
# 2. while it works, send it a change
echo "use the matrix green for the star" > /tmp/note.txt
scripts/mission.sh amend demo /tmp/note.txt
```

You should see, in that order:

- `mission: amendment <UTC> queued for run <run> (session <id>, receipt <id>): the worker sees it at its next context boundary, once`;
- `~/Work/missions/demo/brief.md` ends with `## Amendment <UTC> (from the planner)` and your note, and the
  rest of the file is unchanged;
- `~/Work/missions/demo/amend.log` has the line `<sha> <UTC> queued <session> <receipt> run=<id>`;
- the worker's own next round has the note in its context, as a user row beginning `[amendment <UTC> from the
  planner]`, exactly once. **Measure it where it is measurable**: `out.log` prints the run's output, not its
  user rows, so the note is not echoed there - read `wa sessions`, then the transcript (or the receipt:
  `wa steer <session> --status` says `read` with the message it became).
- passing the same file a second time prints `mission: already amended: ...` and appends and delivers nothing.

For a worker that has FINISHED: `scripts/mission.sh amend demo /tmp/note2.txt` prints
`... the worker is not in flight (state settled; done says rc=0 ...), so session <id> is RESUMED with it ...`,
`out.log` gains `--- amend-resume <UTC> session=<id>`, and the next turn's first user message is the amendment.

## Not done, and what is still unknown

- **`wa mission` (the Lua CLI) has no `amend` verb.** The brief allowed one command, and `docs/MISSIONS.md`
  names `scripts/mission.sh` as the mechanism ("where the two disagree, the script is what runs"), so the verb
  and its tests live there. A caller whose only surface is `wa` cannot amend yet; that is a gap, not a claim.
- **The `deferred` branch is implemented and not exercised.** It needs a run that settles with a note still
  queued (a boundary that never comes), which the fixture cannot produce without killing a run - and killing is
  exactly what this design avoids. It is the one path in "never two deliveries" without a test.
- **No test on a real mission with a real provider.** The fixture's worker is real but its model is a local SSE
  fixture; a live mission's steering delivery is the same code path (`wa steer` -> `steering_inbox` ->
  `steering.consume`), but it was not re-run against Victor's provider today.
- **`wa mission resume` loses the caller's environment** (measurement 2 above). Not fixed here: it is a
  different file and a different change, and amend avoids it. A mission resumed through `wa mission resume`
  from a shell that configures its provider by environment will answer "No provider is configured".
- **The factory's live driver was not switched.** `drive.sh` still launches `~/Work/missions/launch.sh` +
  `start.sh`, whose `run.sh` is the older copy of the runner. `amend` works on those missions too (it reads
  the recorded session from `run.lock`/`err.log` and the node's list, and its resume is the documented CLI
  form), but nothing in this branch changes the driver, and the driver was not run.
- **Pre-existing, not mine**: `docs/MISSIONS.md` still says the mission fixture is "202 checks" while
  `scripts/test-mission.sh` now reports 282. Left as found.
