# Orchestrating wasm-agent

How to give wasm-agent a task, watch it, and review the result without becoming the
bottleneck. Everything here was learned by doing it — the failures are named, because the
rules only make sense against them.

## The recipe

```sh
# 1. Put it where it belongs. Do not ask it to move itself.
git worktree add ../<task> -b <task> origin/main
cd ../<task>

# 2. Inject one task. `wa chat --session` runs ONE turn.
wa chat --session <session-id> "$(cat brief.txt)"

# or, when the session is being driven from the desktop window (the node serialises
# turns, so this queues behind whatever the human is doing):
curl -sN -X POST -H "x-wa-session: <session-id>" --data-binary @brief.txt \
  http://127.0.0.1:8799/chat
```

Then watch the ledger rather than the process, and review the branch.

## Watching a CLI run

`wa chat` keeps one line on screen for as long as a run is in flight: what it is doing,
for how long, and which step. Each tool call gets a line that says what was run,
whether it worked, how long it took, and what it printed, and the run ends with a footer
carrying its own rounds, tools, tokens, cache hit rate, cost and how full the model's
context window is - the window resolved the way compaction resolves it, not from the
global `WASM_AGENT_LLM_CONTEXT`, which cannot be right for every model. The terminal title
carries the same phase, so a reader looking at another tab can still see it working.

Two renderings, decided once, because a person and an orchestrator read the same process
differently:

- **a terminal** (`TERM`, `COLORTERM`, `WT_SESSION`, `ORCA_TERMINAL_HANDLE`) gets the
  status line rewritten in place, colour, and a spinner frame per event;
- **anything else** — a pipe, a file, a captured transcript — gets one plain line per
  event and no escape sequences. `NO_COLOR` forces the plain rendering, and
  `WASM_AGENT_CLI_VIEW=live|plain` overrules the guess in either direction.

Two limits, stated here because a reader would otherwise misread them as a hang:

- the status line advances **when an event arrives, not on a timer**. The interpreter is
  blocked inside the model call and inside a tool, so nothing in this process can repaint
  while one is in flight; a slow model call shows a count that has stopped moving.
- the answer is **not streamed** in the CLI: content deltas go to the node's SSE sink and
  a CLI run has no sink, so the reply appears when the run ends. Both limits are the same
  missing piece — the host calling back into Lua per chunk — and until it exists the view
  says what it knows rather than what it hopes.

## The four rules that came from getting it wrong

1. **Never start it in a tree you own.** One run was started in the main checkout; it
   switched that tree's branch and committed to `main`. It did the reasonable thing for
   the directory it was in. Placement is enforced by starting the process somewhere
   else — not by asking. Measured afterwards: zero references to the reviewer's tree.
2. **A prompt without an imperative gets restated.** A follow-up message that was all
   statements (all already done) came back as a verbatim echo, because there was nothing
   to *do*. Every task statement must contain an explicit, bounded instruction.
3. **One writer per session.** The desktop window and a CLI process are two
   interpreters on one transcript. Use `POST /chat` to the node so turns queue, or wait
   until the other writer is idle. The ledger's "N seconds ago" is the reliable signal
   for whether a turn is in flight; the process list is not.
4. **The agent's self-report is evidence, not verification.** It committed to `main`
   believing it was finished, and its own bug-hunt reported its stub's faults as
   possible product bugs. Review the artefact: run the tests, break the gate, measure
   the claim.

## The brief template

```
From pi (the reviewer in the canonical checkout). <one line of context, and what you already did.>

## Where you are, and why
You are in <worktree> on branch <branch>, cut from origin/main. This is deliberate: the
failure this task must not repeat is work happening in a tree nobody owns. Do not touch
any other checkout.

## Read first (and actually read them)
AGENTS.md · scripts/worktrees.sh · .githooks/* · git log --oneline -12

## The task
<one bounded task, in the imperative>

## Acceptance criteria (each checkable)
<the properties, as counts/facts/behaviours, not adjectives>

## Constraints
- commit as you go, push the branch, do NOT merge — the human merges
- if you cannot prove something, say so in the report
- write findings to a file and keep individual commands narrow (a previous run died with
  a turn full of process tables)
- run your own artefact against your own branch before you report done

## Report format
Counts, hashes, exit codes, file paths, the session id. No adjectives.

## Scope and failure policy
<what to do when the work finds an unrelated bug: where it goes, and whether fixing it
 silently is allowed (it is not)>
```

The last section exists because a brief without it produced a branch carrying two
unrelated changes, and the reviewer had to split them after the fact.

## What the reviewer does

- **Break it before believing it.** A gate that cannot fail is decoration. Both mutations
  here were caught (`count dropped 99 -> 13`, `exited 1 after its verdict`,
  `emitted no verdict` → `ERROR`), which is the only reason the gate was worth landing.
- **Measure claims with numbers.** "Compaction fired ten times too early" became
  `context=1000000` vs `128000`, a trigger at ~984K instead of ~112K, and the table
  verified against pi's `models-store.json`. Verify against a *second* source when the
  first is the claimant's own.
- **Land verified mechanics; present behaviour changes as decisions.** A gate that
  proves itself can be merged; a change to how much context the agent keeps is the
  user's call, with the numbers attached.
- **Reproduce, don't re-read.** Where a claim needs arithmetic or an exit code, run it.
  Where it needs judgement, judge it.

## What is still missing

- **Runs do not record why they ended.** Two runs died this way and neither left a
  reason: a turn ends with a tool call and no result, which is indistinguishable from a
  killed process — and a truncated reply reads as `answered`. Until a termination reason
  is written down, "why did it stop?" needs an outside observer to answer.
- **`wa status` and the board do not show an agent's task.** Nothing says which worktree
  is working on what, so the human's view of "what is running" is a terminal preview.
