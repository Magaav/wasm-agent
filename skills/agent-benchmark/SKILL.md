---
name: agent-benchmark
description: Run a matched coding task in disposable Pi and wasm-agent sandboxes, then compare verified outcomes, traces, time and usage. Use when benchmarking agent harnesses or testing a proposed coding-loop change.
---

# Agent benchmark

Use `node scripts/agent-benchmark.mjs <fixture.json>` from this repository. The
fixture pins the source revision, original task, model, time limit and independent
oracle. The runner starts both agents from the same tracked tree in separate Docker
containers, retains their transcripts, logs, diffs and verdicts, and removes the
containers and working directories on normal completion or error. A machine crash
can interrupt cleanup; check the report and Docker state before another run. Read the runner's JSON
report before drawing conclusions.

Before a paid run, prove that the oracle fails on the starting revision and passes
on a known repair. Keep the repair and oracle outside both agents' workspaces.
Predeclare an experimental time and spending limit. This is a benchmark control,
not a deadline for the production coding loop. Use the same provider route, model, reasoning
level, prompt, starting source and available external data. Record unavoidable
differences in instructions and tool schemas as part of the harness treatment.

Judge task completion from the hidden oracle and the diff, never from an agent's
final sentence. Count failures, timeouts, retries and unpriced calls. Compare tool
and model steps to explain a result; do not treat fewer tokens or steps as success
when the repair is wrong. One paired task is a diagnostic pilot, not a ranking.

The agent processes need an OS container: Pi runs Node and both agents run shell
commands. Each agent's Docker network is internal; a separate fixed forwarder
reaches only `opencode.ai:443`. The real credential exists only in that forwarder;
agent containers receive a dummy key. Open web access invalidated the first pilot when
Pi retrieved the historical gold patch from GitHub, so do not remove this fence.
The current WASM plugin ABI cannot host either entire coding agent.
WASM is appropriate for a future deterministic scorer with no filesystem or network
imports; it must receive test receipts, not execute an untrusted agent. Do not call
a copied worktree a security sandbox.

Only benchmark traces leave the scratch area. Raw traces may contain code, prompts
and tool output; keep them private. Confirm no benchmark containers remain after a
run. If cleanup fails, surface their names and refuse to claim isolation. The
runner never installs, deploys, pushes, or connects to the live node or window.

The pinned first fixture is `benchmarks/agent-benchmark/ui-diff-topic.json`: a
historical wasm-agent task that took 358 seconds. Build the cached image once with
`docker build -f benchmarks/agent-benchmark/Dockerfile -t wa-agent-benchmark:observation .`,
then set the fixture's `image` to that tag. The image supplies `wa-ui-observe`
for real headless Chromium rendering and optional probes, and `wa-ui-contracts`
for deterministic review leads about removed UI classes, elements and events.
These tools are visible to agents; the independent oracle stays hidden. Give all
lanes the same tool hints through optional `sharedInstructions`. Optional
`graphTreatment` adds a third `wasm-graph` lane and is appended only there.
When an agent makes local commits, run `wa-ui-contracts --base "$(git rev-list
--max-parents=0 HEAD)"` so the audit still compares with the pinned starting tree.
Run `node scripts/agent-benchmark.mjs --check <fixture.json>` without a model key
to validate the source, baseline and known repair first. The current runner's
oracle adapter is the historical `scripts/test-ui.ps1`; add a fixture-specific
adapter before benchmarking another kind of task. Run
`python scripts/agent-benchmark-report.py <trace-dir> <fixture.json>` to summarize
retained traces without printing their prompts.
Set `OPENCODE_API_KEY` in the caller environment. The runner gives it only to
the forwarder; agent containers receive `benchmark-placeholder`. Never ask an
agent to print environment variables or credentials. A post-run trace scan
deletes any file containing the real key and marks the trial failed.
