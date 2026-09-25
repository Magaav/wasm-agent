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
Predeclare a time and spending limit. Use the same provider route, model, reasoning
level, prompt, starting source and available external data. Record unavoidable
differences in instructions and tool schemas as part of the harness treatment.

Judge task completion from the hidden oracle and the diff, never from an agent's
final sentence. Count failures, timeouts, retries and unpriced calls. Compare tool
and model steps to explain a result; do not treat fewer tokens or steps as success
when the repair is wrong. One paired task is a diagnostic pilot, not a ranking.

The agent processes need an OS container: Pi runs Node and both agents run shell
commands. Each agent's Docker network is internal; a separate fixed forwarder
reaches only `opencode.ai:443`. Open web access invalidated the first pilot when
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
`docker build -f benchmarks/agent-benchmark/Dockerfile -t wa-agent-benchmark:0.87.1 .`.
Run `node scripts/agent-benchmark.mjs --check <fixture.json>` without a model key
to validate the source, baseline and known repair first. The current runner's
oracle adapter is the historical `scripts/test-ui.ps1`; add a fixture-specific
adapter before benchmarking another kind of task. Run
`python scripts/agent-benchmark-report.py <trace-dir> <fixture.json>` to summarize
retained traces without printing their prompts.
Set `OPENCODE_API_KEY` in the caller environment; the runner passes it to the
containers without writing it to their workspaces or traces.
