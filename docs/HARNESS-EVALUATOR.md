# Harness evaluator

`wa eval` freezes a task an operator actually gave a session, replays it against a candidate binary where
nothing real is reachable, and prints metrics. It **gathers benchmark evidence**; it does not gate a
release, does not decide and does not change the agent.

The engine and its material live under [`harness-evaluator/`](../harness-evaluator/README.md), which is the
reference for the verbs, the isolation, the privacy rule and what moved there. The Lua side is three
modules: `lua/core/harness_evaluator.lua` (store, capture, metrics, verdicts, report),
`lua/core/harness_evaluator_replay.lua` (the isolated replay) and `lua/core/harness_evaluator_cli.lua`
(the operator's door, dispatched from `lua/core/init.lua`).

Quick reference:

```
wa eval capture <session-id> --category code-fix --check human
wa eval run --all --bin ~/.local/bin/wa --timeout 600 --model
wa eval report
wa eval verdict <run-id> pass "checked by hand on the real task"
```

Two facts worth stating because they were measured rather than assumed:

* **A replay has no model unless you give it one.** `--model` passes only the model-route variables into
  the scratch home; without it the child boots with no provider and the run records that, so the numbers
  describe the harness (boot, prompt, tool loop, ledger) and not an answer.
* **Code mode is off in a replay.** The replay hook fires once per outermost tool call, which is what makes
  a refusal reachable at all; a tool call nested inside a code-mode script does not cross that boundary, so
  leaving code mode on could perform an effect while the run reported none. The run record says
  `isolation.code_mode` for every run.

Tests: `scripts/test-harness-evaluator.lua`, `scripts/test-harness-evaluator-replay.lua`,
`scripts/test-harness-evaluator-privacy.lua` (all three are fast-path rows).
