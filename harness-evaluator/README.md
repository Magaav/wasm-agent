# Harness evaluator

An engine inside wasm-agent that **gathers benchmark data from frozen real tasks**. It freezes a task an
operator actually gave a session, replays it against a candidate binary where nothing real is reachable,
and prints metrics.

It does not gate a release, does not decide and does not change the agent. Until it is proven reliable, a
human checks the UX by hand on a real task; the numbers this engine prints are evidence **beside** that
check, never a verdict. A real task's success is a `human` check until somebody records one with
`wa eval verdict`.

## The verbs

```
wa eval capture <session-id> [--turn N] [--id ID] [--category NAME]
                            [--check human|cmd:<shell>|file:<path>[=<text>]]
                            [--dir <workspace>] [--note TEXT]
wa eval list
wa eval run <task-id>|--all --bin <wa> [--model] [--timeout SECONDS] [--keep-scratch]
wa eval report [--all] [--compare <run-a> <run-b>]
wa eval verdict <run-id> pass|fail "<note>"
wa eval reviewer <run-id> [--findings N] [--accepted N] [--misses N] [--cost TEXT]
```

`capture` freezes one user task from the node's own session store: the prompt, the workspace it started
from (the git commit plus the uncommitted patch, or a small directory as a tarball), the mode/role and the
tools the session really called, the model and provider the run used, the connector reads it performed (as
**recorded** answers, never live access) and what the session did with it - rounds, tokens in/out, cache
read, tool errors, effects attempted, files changed, the final answer, wall time.

`run` replays it. `report` prints ids, categories and counts. `verdict` records a hand verdict;
`reviewer` stores the shape a future landing reviewer will fill in (findings, accepted, misses, cost) -
storage and report only, no reviewer exists here.

## Where the numbers come from

One function, `M.metrics` in `lua/core/harness_evaluator.lua`, reads a window of a ledger. It reads the
same rows both times: `messages` for the transcript and `harness_events` (`model_call` and `tool` spans)
for rounds, normalized token usage, cache read/write, model, provider and tool outcomes. Nothing is
instrumented a second time, so a captured outcome and a replayed outcome are the same numbers. A value
that could not be observed stays `nil` with a named rule, never a zero: "no usage recorded" and "zero
tokens" are different facts.

A tool is visible twice in a ledger (a transcript row and a telemetry span). Counting both would double
every error and every effect, so one source wins - the spans when the run recorded any - and the record
says which (`tool_source`).

## What replay isolates, and how it was measured

* a `mktemp -d` scratch root with a marker file, refused if it resolves inside the node's home;
* the child gets `env -i` and an **allowlist**: its own `HOME`, its own ledger, `PATH`, the sink, no node
  environment, no rendezvous, no relay, no vault - unless the operator passes `--model`, which travels
  only the model-route variables. Without it a run records `provider_unavailable` instead of reaching the
  node's account;
* **effects never leave**: a replay `PreToolUse` hook refuses every connector and effect tool and records
  the attempt as "would have done"; `tool_call`'s nested dispatch is matched by the *inner* name found in
  its arguments, because the hook engine fires once per outermost call and a nested call is exactly where
  an effect would otherwise slip past (`12/11`: with that entry missing, the model reached `whatsapp_read`
  through `tool_call` and the sink never saw it);
* connector reads answer from the **recording** captured with the task: the blocked result carries the
  recorded answer as additional context, which is what the model sees;
* `PATH` guards refuse `git push`/`fetch`/`pull`/`clone`, `ssh`, `scp`, `sftp`, `rsync` and `gh`, so a bash
  call cannot do what a tool is not allowed to do. Local git still works;
* **code mode is off** in a replay, always, and the record says so: a tool call nested in a code-mode
  script does not cross the hook boundary, so leaving it on could perform an effect while reporting none.

The three fast rows prove the parts separately, from inside the processes that would do the damage:
`scripts/test-harness-evaluator.lua` (capture, metrics, catalogue, verdict, report),
`scripts/test-harness-evaluator-replay.lua` (scratch home, the child's own ledger, the installed hook and
sink, a dispatched connector read coming back `hook_denied` with the recorded answer, the guards) and
`scripts/test-harness-evaluator-privacy.lua` (below).

## Privacy

A frozen task is real operator work: prompts, message text, mail, machine names, paths. It lives **only**
under the node's own state directory, `<config>/evaluator` (on this node `~/.wasm-agent/evaluator`):

```
<config>/evaluator/
  tasks.json                  the range: id, category, check, source session and turn
  tasks/<id>/task.json        the frozen task (prompt, workspace, recording, outcome)
  tasks/<id>/workspace.patch  the uncommitted diff it started from (or workspace.tgz)
  runs/<run>/run.json         metrics, isolation facts, outcome, verdict, reviewer shape
  runs/<run>/ledger.json      the replay's own transcript, as evidence
  runs/<run>/sink.json        what the replay blocked
```

Never committed, never pushed, never published, never printed whole: `wa eval report` prints ids,
categories and counts, and no code path in the engine writes a task outside that directory. The
repository holds the engine and synthetic test fixtures only.

That rule is enforced, not documented:

* `.gitignore` ignores `.wasm-agent/`, `harness-evaluator/tasks/` and `harness-evaluator/state/`;
* `.githooks/pre-commit` refuses a **staged** path under an evaluator state directory - the case a forced
  `git add -f` (or a global ignore file that disagrees) would still reach;
* `scripts/test-harness-evaluator-privacy.lua` runs the shipping hook's own bytes in a scratch repository,
  proves `git add` is refused on the ignored path, proves no tracked path in this repository is under an
  evaluator state directory, and proves the report prints the task's id but not its text.

## The range

`tasks.json` starts empty: freeze the sessions this node actually ran (`wa sessions` lists them), pick a
spread of categories (code fix, refactor, ops/deploy, WhatsApp read/answer, mail, research, multi-node) and
record what "success" means for each. A task whose success needs a human says so (`--check human`) - that is
the honest default for a real task, and the verdict is what turns it into evidence.

## What moved here

The repository's existing evaluation material lives under this directory now:

| moved | to |
|---|---|
| `fixtures/benchmarks/` | `harness-evaluator/fixtures/benchmarks/` |
| `benchmarks/agent-benchmark/` | `harness-evaluator/benchmarks/agent-benchmark/` |
| `skills/agent-benchmark/` | `harness-evaluator/skills/agent-benchmark/` |
| `scripts/agent-benchmark*.mjs`, the pilot/binding/results/docker modules, `scripts/check-agent-benchmark*`, `scripts/fixtures/benchmark-*` | `harness-evaluator/scripts/` |

What stayed, and why: `fixtures/twin-frames.json` is the terminal twin-render fixture (not evaluation
material); `benchmarks/codemode` and the `*-spike` trees are driven by the code-mode reference suites as
well, so both suites keep reading one copy; `scripts/agent-benchmark-ui-observe.mjs` is the UI probe
harness forty UI tests run; `scripts/test-agent-benchmark-*.lua` are fast-path rows that must live where
`scripts/fast.sh` finds them. Their paths were updated, not their behaviour; the two node rows the fast path
runs (`agent-benchmark-forced`, `agent-benchmark-proxy`) pass, and the node tests that need a binary or an
explicit evidence root still require one - measured identical on the canonical checkout.
