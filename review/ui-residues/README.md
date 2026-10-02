# Independent review of `change/ui-residues`

Reviewed tip: `2a5c5ea1339fb94ce819dcf5ebf8c28858245d87` (tree `git rev-parse 2a5c5ea^{tree}`), 1 commit
ahead of local `main` `e2a86bc`, `git merge-tree --write-tree main HEAD` exit 0, `git branch -r --contains
2a5c5ea` empty (not pushed). Files under review: `ui/app.js` (+92), `scripts/test-ui.ps1` (+181),
`scripts/gate-check.mjs` (+16), `scripts/test-gate-check.mjs` (+9).

I did not produce this change. **Independence here is the lane, not the model**: the provider refuses
`gpt-6-luna`, so both the producer and I run on the same model family. What is independent is that I have no
part of the producer's session, that every instrument below is mine, and that the delivered suites were run
unmodified and then mutated.

**Verdict: `narrowed`.** All three claims reproduce, each with its failing case shown first. The incident's
exact shape is fixed and the fix is not vacuous - and the same false alarm still fires, with the same
consequence for the reader's stream, whenever the node's aggregate answer is `alive` rather than `busy`
(Finding 1). The two coverage residues are pinned; a neighbouring one is not (Finding 4). The parser's pin
is real; it is a substring requirement, so a sentence that *denies* the stage is accepted (Finding 5).

Nothing was pushed, deployed, or pointed at the running window or the installed UI. Every browser run serves
a temp copy of `ui/` on its own port.

## Findings

| class | status | finding |
| --- | --- | --- |
| defect | open | **The false alarm survives on `worker: "alive"`.** `runStanding`'s only safety net for "busy but unidentifiable" is `if (worker && worker !== "alive") return "busy-unknown"`, so an answer this page cannot interpret is evidence of death as soon as the aggregate word is `alive` - and `alive` is the *working* state: `health_body()` (rust/wa-host/src/serve.rs) computes `state = if stalled {"stalled"} else if age_ms < 1000 {"alive"} else {"busy"}`, where `age_ms` is the node-thread beat age and `Heartbeat` beats once a second for the duration of a host call. The same healthy run answers `busy` or `alive` depending on which side of the beat the poll lands. Proved end to end (probe B): the notice `the node is no longer running this run (alive). Checking the recorded result for recovery.` is printed, the fetch signal is aborted, the stream is errored (`stopped.`), and what the stream sent next never renders. Also `over` when `worker` is missing entirely (a node older than the field). |
| defect | open | **The `over` verdict ignores the node's own thread list.** The same answer that carries a `POST /chat` thread with `busy_ms: 9100` - the node is executing a chat run right now - is `busy-unknown` when `worker` says `busy` and `over` when it says `alive`. The page aborts a stream while looking at evidence that the node is working. (Same root cause as Finding 1, listed separately because it is the evidence the decision never reads.) |
| narrowing | proved | **A run the node calls `stalled` is never reported over by this check.** With `worker: "stalled"` and this conversation's thread (or the accepted run id, or a live `run_ids` row) present, `runStanding` answers `running`/`busy-unknown`; the pre-change code fell through to the notice. Decision-level only: the page now waits for the stream to die or the node to exit. |
| defect | open | **A live run in the pre-submit baseline is discarded.** `submitted` (the pre-POST `/health` baseline) exists to tell a queued id from an older run, but a *resumed* run (`send(text, {resumeSeq})`) is itself in the baseline, and `identifySubmittedRun` excludes baseline ids too - so a `run_ids` row saying `{conversation: mine, state: "running"}` is ignored and the `worker` word decides (`over` when it is `alive`). Decision-level (probe D + the table), not driven end-to-end. |
| residue | open | **The rule audit cannot enumerate a rule `el.matches` refuses.** The audit collects a rule only when `el.matches(rule.selectorText)` is true, so a rule keyed on `::before`, on `:hover`, or under a media condition that does not hold at the test window is invisible - and if the change does not move the element's own computed style, the property-for-property diff is blind to it too. Proved: a `::before` glyph on the pane's append-file control alone (M7) and a `:hover` rule on the pane's controls alone (M8) both leave the delivered suite **green**, while the glyph renders (screenshot `evidence/m7-pane-attach-glyph.png`, and `getComputedStyle(paneControl,'::before').content == '"!"'` against `none` on the main control). My first attempt at this mutation (`::before` on the pane's *labelled* controls, M5) went **red** - the glyph widened the button and the diff saw `width` - so the residue is narrower than "pseudo-elements are invisible": it needs a control whose box the change does not move. |
| residue | open | **The parser's subject is a substring, not a stage.** `ok   UI structure, but startup recovery was skipped and the mid-run reload never ran` is ACCEPTED, as is `ok   UI structure, startup recovery of another check entirely`. A sentence that denies the stage is read as proof of it. The FAIL guard is also case-sensitive, so `fail: ...` in lower case with exit 0 is accepted (pre-existing, not introduced here). The delivered negative case (`ok   UI structure, and then something else entirely`) is refused, as claimed. |
| note | unproven | **Field reachability of the `alive` shape.** I reproduced the decision and its consequence on the incident's own fixture shape, and grounded `alive` in the node's health code; I did not observe a live node answering `alive` while a run of mine was unidentifiable - that precondition is the owner's log, not mine, so the frequency is unmeasured. Likewise the `mine` lookup matches a run id *number* without checking `conversation`: with the journal installed (serve/scheduler.rs `install`) ids are per-database rowids, so a collision needs a fresh/empty database; I did not prove it in the field. |

## What reproduces, and with what

Every command below was run in this review's own checkout (branch `review/ui-residues`, based on
`2a5c5ea`). `ui/app.js` sha256 at that tip: `f0863052e89b7d5d9a465f68ddb5ca7c2f9b78a9468dde0919f59d0df431cec5`;
`runStanding` extracted from it is 28 lines, sha256
`2039141ee078ca22c1818055f5c71687cf30af48a5cd9790e00982ae81b258b6` (see
`runstanding-table.mjs`, which prints these before it decides anything).

**Claim 1 - the incident, and the alarm being gone.** `node review/ui-residues/probe-runner.mjs
review/ui-residues/probe-incident.js --budget 90000` serves a temp copy of `ui/` with the fixtures and the
delivered seam, holds a real run in flight, and drives the page's own `send()`. Recorded
(`evidence/probe-incident.log`):

- **A, the incident** (`worker: "busy"`, a busy `POST /chat` thread for `some-other-conversation`, no
  `run_ids` for this conversation): `alarmsBefore 0 -> alarmsAfter 0`, no abort (`abortedAfter 0`), status
  `the node is busy with a run I cannot identify; still listening`, and a delta emitted after the ask
  rendered (`streamRendered: true`).
- **C, the control** (idle node, no thread, no run of this conversation): `alarmsBefore 1 -> alarmsAfter 2` -
  a genuinely over run is still reported, so A is not vacuous.
- **S, the timer path** (no seam call at all, 45 s of virtual silence; `ticks: 45`): the unique watchdog
  status text `the node is busy with a run I cannot identify; still listening` appeared *during* the silence
  (a transition - it was not the status at the start), `alarmsAfter` unchanged, and the post-ask delta
  rendered. The 30-second interval fired and produced no false alarm.
- **E, an answer after the run ended**: the ask is in flight (`/health` held), the run ends under its own
  steam (`reply` on screen), then the answer arrives - `alarmsBeforeRelease 1 -> alarmsAfter 1`, no
  "cannot identify" line. The post-await guard works.
- **B, the same shape with `worker: "alive"`**: `alarmsAfter 1` with the notice text above,
  `abortedAfter 1`, `enqueueAfterAbort: false`, `streamRendered: false`, `stopped: true` - the live run's
  stream is aborted.

**Claim 2 - the two coverage residues.** In a clone of the tip, `bash review/ui-residues/mutations.sh`:
M1 `wa-agent-session .chat-control { margin-top: 4px; }` -> `test-ui.ps1 exit=1`, the audit naming
`child append-file -> rules[wa-agent-session .chat-control[margin-top]]`; M2 the same with `letter-spacing`
-> `exit=1`. The same run mutates `runStanding` (M3: `busy-unknown` removed) -> `exit=1` with `the node is
no longer running this run (busy)` - so the incident check is not vacuous in the negative direction either.
M7/M8 are the residues that still slip (Finding 4).

**Claim 3 - the parser.** `node review/ui-residues/parser-cases.mjs` runs the delivered `checkVerdict`:
the delivered negative case refused, the bare prefix refused, the real verdict line and an honest
reordering accepted, my denying/false-subject sentences accepted (Finding 5). M4 (parser back to
prefix-only) -> `node scripts/test-gate-check.mjs exit=1` with
`AssertionError: a line that names no stage of this check is not its verdict`, while
`node scripts/gate-check.mjs run ui-browser exit=0` - the negative case is the only thing that catches it,
exactly as the delivery says.

**The three suites, delivered files unmodified, at this review's tree** (`evidence/baseline-*.log`):

```
$ powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1 -Port 8917 -ClientPort 8817
  ok   UI structure, mid-run reload, startup recovery, the inspect window, and a view window     (exit 0)
$ node scripts/gate-check.mjs run ui-browser
check ui-browser: PASS exit=0 ms=5793.9 log=...ui-browser.log                                 (exit 0)
$ node scripts/test-gate-check.mjs
gate check runner ok (21 checks, 0 skipped)                                                   (exit 0)
```

Mutations run against the delivered suites: **5 red** (M1, M2, M3, M4-test-gate-check, M5) and **3 green
where red was expected** (M7, M8 - the residues above - and M6, the same glyph on the main control). The
tree was clean after every mutation (`git status --short` empty except this untracked review directory).

The logs captured from PowerShell carried CRLF on this host; they were normalised to LF to satisfy the
repository's stored-blob rule (`.githooks/pre-commit`), content otherwise unchanged. The two screenshots
are the browser's own bytes.

## Not done

No push, no deploy, no merge, no restart, nothing pointed at the running window (port 8799) or the
installed UI directory. The three suites were run through the repository's own harness, which starts a
*separate* node with its own temp database, home and ports and serves a temp copy of `ui/`. One unintended
side effect on the desktop, reported rather than hidden: `chrome.exe --version` on this Chrome build does
not print a version, it opens a tab in the user's existing Chrome session - so that tab exists because of
my first, abandoned browser probe. It did not touch the wasm-agent window or the installed UI, and every
later run used `--headless=new` with Edge, as `scripts/test-ui.ps1` itself does.
