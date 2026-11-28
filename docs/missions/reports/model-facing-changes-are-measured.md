# model-facing-changes-are-measured - one fixed task set, one command, one table

Item taken: `_queue/model-facing-changes-are-measured.md` -> `.taken-wasm-agent` (28/11).

## What a landing gets now

    scripts/model-facing-diff.sh <base> <tip>

One table, one row per task, two sides (base, tip), a cell per fact the model pays for, and a mark per cell:

```
task           side     request    prompt     tools    result      k-in     k-out    rounds      wall
---------------------------------------------------------------------------------------------------------
plain-answer   base       22107     20628       807         0     22107        61         1       765
plain-answer   tip        22189     20710       807         0     22189        61         1       839
               mark           >         >         =         =         >         =         =         =
```

(That is a REAL row, measured 28/11: the tip tree grows the code-mode routing block by 82 bytes and the command names
the cost - request and prompt bytes up by exactly 82, k-in up, nothing else moved. The row asserts that same growth:
`22107 -> 22189 request bytes`.)

Columns: `request` is the FIRST request of the task (the healthy call - a difference is a prompt-cache miss), `prompt` is
the system prompt's content bytes, `tools` the tool declaration array's JSON bytes, `result` the tool-result bytes the
model was handed back, `k-in`/`k-out` kilobytes the provider saw, `rounds` the completion requests, `wall` milliseconds.

Exit 1 when any cell outside wall time is worse, 0 when nothing is - so a brief can hold it as a gate.

## The task set

`scripts/model-tasks/tasks.json`, fixed and in the repo: three tasks that are the smallest versions of what a model
actually does here - `plain-answer` (one round, no tool), `one-tool` (a tool call, then an answer: the tool RESULT is the
thing no prompt-byte probe can see), `refusal` (a task where the right answer is to refuse). Each names its reply script,
so the run is deterministic and needs no account and no network: `scripts/lib/measuring-provider.py` answers and writes one
JSON line per request (bytes in, system/tools/tool-result bytes, reply bytes, timing).

A task set that a model cannot pass proves nothing, so the tasks are worded like real asks and the recorded-reply form is
the only stand-in. Adding a task is adding one object to that file (name, why, prompt, script).

## Any provider in the registry, so the same tasks compare models

    scripts/model-facing-diff.sh <base> <tip> --provider opencode-go     # today
    scripts/model-facing-diff.sh <base> <tip> --provider claude-cli     # when it lands

With `--provider` the SAME task set runs against that provider in the node's registry instead of the replay, which is how
two MODELS are compared on one task set (the orchestrator's ask on 28/11). Its wire is not ours to record, so the byte
columns read `-` and rounds, kilobytes and wall time carry the comparison: that is stated in the command's own header
rather than left to be discovered.

## The two layers, measured rather than assumed

A change can move the model-facing bytes in two places, and the command measures whichever pair you name:

* the LUA tree - `<base> <tip>` swaps the tree and runs both sides on ONE binary. Measured 28/11: growing the code-mode
  routing block moves request/prompt bytes (+82); editing a description in `lua/core/tools.lua` moves NOTHING, because the
  tool catalogue the wire carries is built by the host;
* the BINARY - `--base-bin <wa> --tip-bin <wa>` compares a rebuilt host against the old one, which is the pair that moves
  the system prompt and the tool declaration bytes.

That split is a fact about this architecture, not a shortcut, and it is written in the command's header so nobody reads an
all-`=` table as "nothing changed" when the change was in Rust.

## The row that proves the command

`scripts/test-model-facing-diff.sh`, 14 checks, green: a no-op pair is `=` in every cell but wall time and exits 0; a
scratch commit that grows the routing block is caught (`>` on request and prompt, +82 bytes, exit 1); a tip whose Lua does
not load is marked `?` with the interpreter's own words instead of `same`; a ref that is not a commit is refused by name.
The scratch commits live in DETACHED WORKTREES of this repo - the row creates no branch and writes no ref.

WIRED: the RELEASE GATE (`scripts/test.sh`, right after the description rows). Not the fast path on purpose - three tasks
x two trees cost ~4 minutes, and "did this make things worse for the model?" is a question for a release, not for every
landing.

## What is NOT verified here, said plainly

* No run against a real registry provider: this machine has no account for one, so `--provider` is built and documented
  but has not been proved end to end. The stub path is measured.
* No rebuilt-binary pair: building `wa` twice is a release's job; `--base-bin/--tip-bin` is plumbed and the plumbing was
  exercised with two binaries already on disk (identical trees, so identical bytes - the columns did not move, which is
  the correct answer for that pair, not a proof that a Rust change moves them).
* The 3-5 RECORDED REAL tasks the item asks for beyond the stub tasks: not captured here, because capturing a real
  session needs the account this machine does not have. The task set's file format is the one a capture would write, so
  that is the next step, not a redesign.

## FACTORY (proposal only - factory scripts live outside this tree)

Every brief whose change a model reads runs `scripts/model-facing-diff.sh <base> <tip>` and puts the table in its report.
The FACTORY rule that follows from the item:

    A change is not measured because it was tested. It is measured when the same fixed task set, run against the base and
    the tip, puts a number on every byte the model reads - and any growth of the system prompt or a tool description needs
    Victor's word, with the delta stated.

## Model-agnostic rule, restated in the terms this round could check

Fix LOGIC (wrong count, silent acceptance, lost result); list a MODEL HABIT, do not fix it. This round added no prompt text,
no hint and no example: the only product bytes are a command, a provider, a task set and a row. The one thing it grows is
what a landing must READ, not what a model must say.
