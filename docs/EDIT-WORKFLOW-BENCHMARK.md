# Edit-workflow benchmark

This is an **opt-in paid-model experiment**, not a test gate and not an automatic
agent score. It replays one real coding task from a frozen revision to compare source
discovery instructions while keeping the model, settings, tools, repository and
independent verifier fixed.

The fixture is the WhatsApp copilot request for two job-owned controls:
`WA_WHATSAPP_GRACE_SECONDS` and `WA_WHATSAPP_MAX_AGE_SECONDS`. The organic run on
2026-09-25 exceeded twenty minutes, used shell source inspection before one fabricated
selection receipt, and was cancelled before delivery. Its uncommitted patch is evidence
for the verifier contract, not the expected implementation and not a correctness oracle.

## Why ordinary parallel subagents are insufficient

Subagents of one node share that node's current working directory. They are appropriate
for parallel read-only investigations, but independent writers would race on the same
files and graph root. `scripts/experiment-edit-workflow.cjs` therefore creates one
detached checkout, home, database and graph per attempt, then starts one real wasm-agent
subagent in each checkout. Solver attempts overlap. Verification runs afterwards, one at
a time, so concurrent Cargo builds do not choose the fastest arm.

The three solver profiles expose the same tool schemas:

| arm | only intended difference |
| --- | --- |
| `control` | ordinary bounded-task instruction |
| `source-first` | editable source must come from `read`/`read_many`, never `cat`/`sed` output |
| `graph-first` | `graph overview`, retrieval and final impact are required before ordinary discovery/finalization |

Every graph is pre-indexed, including the controls. A fresh read-only shadow with the
opposite navigation emphasis reviews each resulting patch in parallel. Shadow prose is
retained as review evidence; it does not override the deterministic verifier.

## Run

Build the candidate binary first. Real inference requires an explicit acknowledgement.
The `--provider` flag chooses paid versus mock inference; `--wasm-provider` selects
wasm-agent's actual route. For Pi's GPT-6 subscription route, point `--lua-root` at
the current source checkout so every frozen arm uses the same updated transport code:

```sh
WASM_AGENT_REASONING=high node scripts/experiment-edit-workflow.cjs \
  --wa rust/target/release/wa.exe \
  --base bad2cdc \
  --provider real --confirm-paid yes \
  --wasm-provider openai-sub --lua-root . \
  --model gpt-6-luna \
  --n 1
```

The `openai-sub` route uses Pi's `openai-codex` OAuth login and the installed Pi adapter;
it does not use an OpenAI API key or the OpenCode Go forwarder. The runner discovers
Pi under `npm root -g`; set `WASM_AGENT_PI_PACKAGE` to its package directory if it is
installed elsewhere. The Pi package version, selected model, and `WASM_AGENT_REASONING`
are recorded in the manifest/report. `--lua-root` is shared by all solver and reviewer
nodes; it keeps transport/runtime differences out of the arm comparison.

`--n 1` is a pilot. Use at least three interleaved attempts per arm before discussing a
fixture-specific tendency, and do not use this one repository task to select a global
default. `--provider mock` proves orchestration/accounting only; its candidates must fail
verification.

Ctrl-C or a termination signal stops the active experiment process trees and writes
`interrupted.txt`. An abrupt terminal or host kill may not deliver a signal; check for
remaining `experiment-edit-workflow` and `experiment-tool-choice` processes before
assuming paid inference stopped.

Artifacts default to `~/.wasm-agent/benchmarks/edit-workflow-<timestamp>/` and include:

- the frozen commit and arm manifest;
- SHA-256 hashes of the harness scripts and candidate binary, since an uncommitted
  pilot cannot be reproduced from its commit alone;
- each isolated worktree (retained for inspection);
- solver and shadow ledgers plus stdout/stderr;
- candidate patch and bounded copies of untracked files;
- independent verification checks and Cargo logs;
- `report.json` with child/model/tool latency, tokens, priced cost or an explicit
  unknown value, tool/failure counts, first tool, graph/read/bash/edit counts,
  verifier verdict, shadow report, and resource use per verified completion.

The report refuses comparability when the model, settings, tool schema hash or advertised
tool list are missing or differ across arms. A verified completion also requires the
solver to finish normally and leave the frozen commit checked out. A process completion
or confident reply is never correctness. The review agent reads the saved tracked diff
and the list of untracked paths before inspecting source; the harness removes this
temporary review file when reviews finish.

## Independent verifier

`scripts/lib/experiment-edit-verify.cjs` is run only after the solver settles. It injects
a temporary Rust integration test that the model never sees, checks the two-name allowlist,
value bounds, `grace <= max`, invalid placements, artifact export/import, shipped defaults,
source evidence of sentinel propagation, `git diff --check`, and compilation of the sentinel. It
removes its temporary source before reporting.

The verifier is intentionally task-specific. A different real task needs a different
external outcome contract; reusing this one would turn patch resemblance into a quality
claim.

## Interpretation and risks

Primary metric is resource use per **verified completion**, including failed attempts.
Report correctness and review blockers beside wall time, model time, tool time, tokens and
cost. Source-first or graph-first is faster only when it passes the same external checks.

Known limits:

- one historical task cannot justify a default;
- profile instructions make this a subagent experiment, not proof of main-agent behavior;
- parallel provider calls reduce time-of-day drift but may share upstream contention;
- graph indexing is kept equal and visible, but graph usefulness depends on language and task;
- verifier compilation is serialized and excluded from solver completion latency;
- fresh homes are cold; repeat separately if warm-session behavior matters;
- graph-first may help Rust relationship awareness while adding useless work for JSON/data files.
- sentinel propagation currently has a conservative source check plus compilation, not
  an external runtime assertion; interpret a pass with that limit in mind.

Do not force graph discovery globally from this result. Promote a policy only after several
verified task classes and organic runs show better completion cost without worse correctness
or evidence access.

## Cleanup

The experiment retains worktrees because a failed candidate is evidence. After review,
remove each with `git worktree remove --force <artifact>/worktrees/<arm>-<run>`, then run
`git worktree prune`; deleting the artifact directory alone leaves linked-worktree metadata.
