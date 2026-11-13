# Harness evaluator

`wa eval` freezes a task an operator actually gave a session, replays it against a candidate binary where
nothing real is reachable, and prints metrics. It **gathers benchmark evidence**; it does not gate a
release, does not decide and does not change the agent.

The engine and its material live under [`harness-evaluator/`](../harness-evaluator/README.md), which is the
reference for the verbs, the isolation, the privacy rule and what moved there. The Lua side is four
modules: `lua/core/harness_evaluator.lua` (store, capture, metrics, verdicts, report),
`lua/core/harness_evaluator_replay.lua` (the isolated replay), `lua/core/harness_evaluator_reviewer.lua`
(the landing reviewer) and `lua/core/harness_evaluator_cli.lua` (the operator's door, dispatched from
`lua/core/init.lua`).

Quick reference:

```
wa eval capture <session-id> --category code-fix --check human
wa eval run --all --bin ~/.local/bin/wa --timeout 600 --model
wa eval report
wa eval verdict <run-id> pass "checked by hand on the real task"
wa eval reviewer change/x --brief brief.md
wa eval reviewer mark change-x-001 accepted
wa eval reviewer miss change/x "it missed the bypass"
```

Two facts worth stating because they were measured rather than assumed:

* **A replay has no model unless you give it one.** `--model` passes only the model-route variables into
  the scratch home; without it the child boots with no provider and the run records that, so the numbers
  describe the harness (boot, prompt, tool loop, ledger) and not an answer.
* **Code mode is on in a replay.** It was forced off while the hook fired once per outermost tool call;
  since the nested-dispatch fix (`825ce08f`, `docs/HOOKS.md`) a call inside a script crosses the same hook
  boundary, so a script cannot perform an effect the sink never sees - and forcing it off measured the
  direct tool loop, not how the node is worked. The run record says `isolation.code_mode` for every run.

## The landing reviewer

`wa eval reviewer <branch>` starts a session that shares nothing with the caller - its own home, its own
ledger, no memory, no notes, no history - and has it review the branch before it lands: the brief, the
diff against the base, and every file the diff touches. Its instruction text is fixed byte for byte
(`M.INSTRUCTION`) and its model is pinned (`deepseek-v4.1-flash`, with no `--model` on the door), because
the text and the model are the two things whose change would invalidate every number in the store. The isolation is the replay's, reused:
a scratch root outside the node home, `env -i` with an allowlist, the sink that refuses effects and
connectors, the PATH guards, code mode on as in a replay. The review reads a discarded clone of the
branch tip.

It is **not a gate**. It prints the findings and the final `REVIEW <branch> <sha> findings=<n>` line, exits
0 whatever the findings are, and `scripts/landing-queue.mjs` never reads its store. The operator marks each
finding accepted or rejected (`wa eval reviewer mark`), records what the reviewer missed after the landing
(`wa eval reviewer miss`), and `wa eval report` prints per review - branch, sha, findings, tokens, time -
and the totals: findings, accepted rate, misses, cost.

One switch turns it off: `reviewer = off` in the node's config file (`<config>/env`, the one file the host
reads) or `WA_REVIEWER=off` in the environment; the door then says it is off and exits 0 - with or without
a branch named. Measured on this
node with no vault in the environment, a review cannot answer: the child boots, runs its own session and
the record says `no_review` with zero model calls - which is what a fast-path row proves, because the
answer path needs a model and a fast-path row has none.

Tests: `scripts/test-harness-evaluator.lua`, `scripts/test-harness-evaluator-replay.lua`,
`scripts/test-harness-evaluator-privacy.lua`, `scripts/test-harness-evaluator-reviewer.lua` (all four are
fast-path rows).
