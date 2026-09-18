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
From pi (the reviewer in loggerhead/). <one line of context, and what you already did.>

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
