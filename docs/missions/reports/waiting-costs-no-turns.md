# waiting-costs-no-turns: the hold is withdrawn, and what replaces it

**Decision (Fable, 28/11): withdraw the hold; the pending answer is the contract.**

## Why, in the rows' own words

Eight rows pinned the tool answer and went red when the hold changed it: the handle a finished script was waiting
on, `pending_backgrounded`, `pending_settled`, `wait(op)` resuming a handle, the CPU-priority lowering report.
Read one of them - `scripts/test-codemode-wait-bound.lua` - and the case is exact: its script's last act is a
`wait` on an op that never settles, and it asserts the answer **is a handle**. That is precisely the case the hold
intercepted. Five green rows turning red is not a test to be rewritten; it is the contract saying no.

## The before, measured (7 days, from the ledger)

- **8,772 `operation` calls inside 942 runs** that lasted over two minutes;
- 423 of those runs made six or more calls, **121 made more than twenty**, and the worst single run made **172**.

That is the polling the hold was meant to remove.

## What removes most of it instead

The **shared wait**, landed 28/11: one wait of 60 s (300 s maximum) per call instead of the model polling an
operation itself. Plus the wake the code already had: an op that settles wakes the session once
(`M.wake_settled` in `lua/core/codemode_pending.lua` + the selfloop tick).

## What to measure after a week on the shared wait

1. the same ledger query (`wct-query.sql`): long runs, `operation` calls inside them, the >20-call tail - the
   before is above, so the after is a subtraction, not an opinion;
2. how many long runs end with a **wake** rather than a model call (the ratio the hold was trying to force to one);
3. whether the >20-call tail shrinks or merely moves: a run that makes twenty awaits of 60 s is six hours, so a
   long tail after this change points at the shared wait's budget, not at a missing hold.

## What is left in the tree

`codemode_pending.hold_before_answer` and its publishing helpers remain defined but are **no longer called** -
dead code kept for one landing so the withdrawal is a small, reviewable diff. Deleting them is the follow-up, and
it is a pure removal with no behaviour to re-measure.
