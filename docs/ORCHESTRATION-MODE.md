# Explicit orchestration mode

`/orchestration` toggles one operator conversation between direct work (default
off) and native worker routing. `/ochestration` is a spelling alias. The command
menu shows the last authoritative on/off state; unavailable state is unknown,
never guessed off. Mode changes are deterministic, owner-checked and revisioned.
Mode is not placement policy: no fleet policy, scheduler ceiling or job is enabled.
Task-owned workers stay local to the selected node and inherit its provider/model.
Their clean worktree allocation uses the explicit mode's ordinary integration path,
not the disabled historical wave factory; workspace binding/dirty-source/owner checks
remain. There is no new cumulative task-time/token cap; provider/operation safety
bounds and the existing native concurrency/queue ceiling remain.

On: the coordinator first assesses the request with its ordinary conversation
context and routes the turn before it changes anything. Three routes, decided by the
coordinator - not by a router and not by the harness:

- a quick conversational exchange is answered here directly, with no child;
- a read-only inspection or a short one-step task is done here, after
  `route_task` records route="direct" with the task in the coordinator's own words;
- a concrete implementation or multi-step change is routed "delegate" and handed to
  the native subagent facade with its resolved goal, relevant context, acceptance
  criteria and requested model/reasoning.

A short continuation such as “go” is resolved against the pending task, or clarified
if genuinely ambiguous. No pre-inference router may turn the raw continuation into a
fresh child task, and nothing here starts a child: the route is a decision and the
child is authored by the coordinator. Blind delegation is a failure, not the goal, and
a concrete implementation routed "direct" is a misroute rather than a shortcut. The
exact original user row and the coordinator's tool/receipt remain in the parent ledger;
the child receives only the authored bounded handoff, not automatic parent-history or
memory injection. In this mode `subagent` and `route_task` are declared in the
coordinator's own tool list from the start (no `tool_search` discovery); a child has
neither.

Mode also has a hard floor, checked in the tool dispatch path rather than in the
prompt. A direct effect that is the work itself - `write`/`edit` and their batch
forms, a mutating `bash`/`shell` command, `operation` start, `spell_run`, a worktree
change, `integrate` - is refused with `orchestration_route_required` until the turn
has a recorded route, and with `orchestration_delegate_required` after route="delegate"
until the child is admitted. Both refusals carry no effect and name the required
next step (the route, or the `subagent` `start` handoff with the `orchestration-worker`
profile, bounded prompt and context). Read-only assessment stays allowed and needs no
route: reads, search, graph, diagnosis and a shell command the mode classifies as
read-only are not effects. The floor reads the mode state, the route record and the
admission record only - never the user's text - so it is not a router and never
creates a child. A route or an admission lifts the floor for that turn (the run id and
the newest user row both identify it, so a steering note or a resumed run does not
revoke it); a new user turn requires a new decision. The route is recorded durably and
emitted as an `orchestration_route` telemetry event, so a misroute can be audited.
Direct mode is unchanged: with the mode off the floor does not apply at all.

The reserved `orchestration-worker` profile cannot be overridden or used from a
mode-off/foreign/guest/remote context. After admission the parent returns without
waiting for worker inference and remains available. Off: the direct loop runs.
Turning off does not cancel admitted tasks. Child/completion/Sentinel notices grant
no new work authority. Children have no subagent tool. Ambiguous admission is
retained, never automatically retried or silently replaced by direct execution.
Attachments travel as retained image refs in the explicit handoff.

Workers implement the assigned scope, self-review honestly, run focused checks,
commit with provenance, sync/refactor conflicts in their own tree, and land through
`integrate` in the canonical main checkout. Integration serializes by repository,
requires a clean owned tip and canonical main, proves merge-tree against fresh
origin/main, uses a named ordinary merge, pushes without force/hook bypass and
reads the remote ref back. Conflicts are a no-effect refusal for the worker to
resolve and recheck; semantic conflicts requiring human judgement remain blockers.
Unknown integration effects are journalled and never replayed. No full release
gate unless explicitly requested. Remote protection remains authoritative.

Workers report back; the coordinator does not steer them while running. Follow-up
work is assigned only after a report. The coordinator alone decides installation
readiness and owns `/update`, UI asset publication and Sentinel. Worker profile
instructions and tool admission exclude these effects; child shells also retain
the existing in-turn installer guard. Sentinel mutating CLI
invocations refuse inherited child provenance. Unrestricted shell is not an OS
sandbox: privileged deliberate marker/file manipulation remains outside that
cooperative boundary and is never an approved workaround.

Off retains the operator-selected direct workflow. This explicit opt-in exception
does not restore the historical parallel factory, independent-review requirement,
watchers or full release gates. Workers use the same focused self-review rules;
self-review never becomes independent review. See [EXECUTION.md](EXECUTION.md),
[SUBAGENTS.md](SUBAGENTS.md), [CONCURRENCY.md](CONCURRENCY.md), [MEMORY.md](MEMORY.md)
and [SENTINEL.md](SENTINEL.md) for the existing ownership and effect boundaries.

Focused proof: `test-orchestration-mode.lua` tests defaults, owner/guest/child/CAS
and corrupt-state refusal, and the routing floor itself - the three routes (a question
answered with reads and no child, a short direct task after route="direct", a concrete
implementation refused after route="delegate" and handed on), a direct `write` and a
mutating `bash` refused with `orchestration_route_required` before any route, `read` and
read-only shell commands never refused, the floor lifted by a recorded route or an
admission, a new user row re-arming it, a child's own dispatch never refused, `subagent`
and `route_task` declared from the start in mode-on and absent without it, and direct
mode unchanged; `test-orchestration-routing.cjs <built-wa> <evidence>`
uses actual native worker execution, a local mock provider and private linked Git/
bare remote to prove contextual coordinator inference across all three routes, that the
coordinator's first `write` is refused before it routes, that route="delegate" then
refuses the same `write` until the child exists,
that the same `write` succeeds after the receipt, that a raw “go” stays in the original ledger, and that the child receives a resolved
task. The coordinator returns while held child work continues independently. `test-worker-integrate.cjs` checks real remote
readback/clean trees; `test-worker-integrate-refusals.lua` proves no-effect dirty/
conflict refusal and held unknown post-merge push, without replay. Native shell
marker and `test-child-supervisor.cjs` exercise child supervisor denial before
requests/jobs/service effects. `test-orchestration-ui.cjs <evidence>`, then
`--post`, verifies the command balloon, alias, target/single-flight, preserved
worker drafts and evidence hashes; the required UI suite includes it. Private
mock fixtures are not live paid-model or installation proof.
