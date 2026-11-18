# Mission change/ab-actions — measure JSON tools vs codemode vs CodeAct on real tasks (Victor 18/11: go)

Run AFTER landing round 1 is deployed (it brings the CodeAct default fix). Measurement, not a feature.
Same node, same model (deepseek-v4.1-flash), same task text, fresh session per run, 3 runs per (task, mode).
Modes: (a) plain JSON tool calls (codemode off), (b) WASM_AGENT_RAW_CODE=codemode (code inside one JSON tool),
(c) CodeAct run blocks (the default after the fix).
Tasks - READ-ONLY variants of Victor's real tasks, nothing is sent, booked or written to a person:
  1. email: find the last important email and summarize it (no forward/send);
  2. contacts: find the contact "Laura <3" and her last message (no send);
  3. MCP search: find candidate GitHub repos for a built-in MCP and rank 3 (no install/registry change);
  4. data: from a local fixture (CSV/JSON in the mission dir), compute an aggregate and a top-5.
Record per run: rounds, tool calls, input/output tokens (and cache-hit %), wall time, failed calls, task
success (a written, checkable criterion per task, decided BEFORE running), and which actions the model chose.
Output: a table per task and mode with medians, plus the raw per-run rows. Personal data (email/contact
content, transcripts) stays LOCAL under the mission dir and never enters git; only aggregated numbers and the
task definitions (without personal content) go into docs/measurements/ab-actions-<date>.md.
Decision rule (agreed up front): CodeAct stays default if, on median, it is equal or better on failures AND
on tokens or rounds, without lower success; the JSON path then shrinks to a documented fallback (a separate
mission, envelope text verbatim to Victor first). Also the baseline for change/python-codeact.
