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

## Toward the master chat (plan, 29/10)

**Status: plan (29/10).** Nothing here is implemented by this document. Each step below lands with
its own measurement; a step that does not move its number is not kept.

The goal: one `wa` conversation, reachable from any device, that turns what the operator says into
parallel work - evolving this repository, evolving other repositories, and the general loops (web,
mail, WhatsApp, search) - across subagents and peer nodes, without the operator managing any of it.
This mode is the current attempt and is not reliable yet; this section is the plan to make it so.

### Words, fixed

- **Gate** means the full release gate (`scripts/test.sh`, `finish.mjs gate`, `wave-release.mjs`). It
  runs only when a human asks for a release. Landing work is **focused checks plus `integrate`**
  (`gate_verified:false`). See `AGENTS.md`. Gate timings (`MERGE-SPEED.md`, `FACTORY.md`) are not the
  cost of landing and must not be used to plan waves.
- **Wave**: the set of subagents one operator request fans out into.
- **Deploy**: the sentinel installing a build of clean `main` (`wa-sentinel request deploy`, which runs
  `scripts/deploy.sh`). It is the only way a build reaches a node - no hand builds, no hot copies.

### Who owns what

| part | owns | never does |
| --- | --- | --- |
| master chat (the node, orchestration mode) | understanding the request, routing (direct / delegate), authoring child briefs, choosing repo, task class and device, accepting results | build, land or deploy itself; wait on a child |
| subagent | one scoped task in its own worktree (or none, for general loops), focused checks, a report | merge `main`, deploy, edit outside its scope |
| sentinel (`wa-sentinel`) | everything serial, everything that must outlive or replace the node: requirement checks and provisioning, incremental builds, deploy with proof and rollback, the worktree pool, reaping, the heavy-build slot | decide what work to do |
| peers (rendezvous) | executing work placed on them; their own sentinel does their local mechanics | accept work from anything but an authenticated master |

### Task classes

| class | workspace | done means |
| --- | --- | --- |
| self-evolution (this repo) | pooled worktree | focused checks, `integrate` to `main`, sentinel deploy |
| other own repositories | pooled worktree | focused checks, `integrate`, that repository's own deploy |
| repositories whose `main` is someone else's production | pooled worktree | a **draft PR**; the master chat never merges there |
| general loops (web, mail, WhatsApp, search) | none | sentinel jobs (schedule/event/file) start subagents in code mode; outward effects go through the operator approval route |

### What the first attempt taught (wasm_the_first lineage, 18/09 - 23/10)

633 commits carry `Agent: wasm-agent node=wasm_the_first`. Verified from source:

- **Children die with the node.** "one lane was killed by a deploy restart"; a child running at a
  restart "reads `unknown`, with no replay" (`SUBAGENTS.md:257`); a deploy waited behind the
  coordinator's own turn ("busy after 60s", `FACTORY.md:363`).
- **Reports cannot be trusted as text.** Three deliveries settled `report: absent`; one worker deleted
  27 lines of another lane's doc out of scope; "Four of eight concerns were changed by verification"
  (`FACTORY.md:383`).
- **State leaks.** The 01/10 audit: 72 worktrees (36 dirty), 1,374 of 1,380 bindings still allocated
  (`WAVE-CONVERGENCE.md:554`); a run died at 1.9 GB free disk.
- **"Runs do not record why they ended"** (`ORCHESTRATION.md:132`).
- **A mode in prose does nothing.** Before `a32cca16` the coordinator could do the whole task itself;
  a bare "go" was once delegated with no coordinator inference (`ef1a7196`).
- The parallel factory (worker → reviewer → merge lane → gate) was retired on 05/10 (`b3003d54`, no
  reason in the commit). Its landing ceiling (~4/hour) was the gate, which is now release-only.

Hypotheses from reading the code, not yet confirmed by data. Neither the sandbox node nor `openclaw`
holds the 10/10 - 23/10 coordinator records (checked 29/10: no route, admission or completion rows on
either; openclaw's database ends 02/10), so the coordinator database that produced those worker
merges is still to be found:

1. A child's completion notice is stored as a user row (`completions.lua:300-303`), and the route floor
   keys on the newest user row (`memory.lua:1050`, `orchestration_mode.lua:119`), so every child report
   may force a new `route_task` before the coordinator can act - a loop that grows with parallelism.
2. After admission the floor lifts for the whole turn (`subagents.lua:624,630`), so the coordinator can
   edit the files its running child owns.
3. The mode is a per-session flag with no `enabled_at` or build commit, so "it did not orchestrate"
   cannot be told apart from "the mode was off" or "the binary predated the mode".

### Plan, in order

Each step names the number it must move.

1. **One rebuild path through the sentinel** (in flight). Host syncs `main` into the node's clone by git
   bundle (fast-forward only), then `request deploy --expected-sha`. The sentinel checks requirements in
   well under a second (stat/version files, no cargo, no network), provisions what is missing (pinned
   toolchain, Node, code-mode assets), builds incrementally on the persistent target, proves on a
   scratch port, installs `wa`, `wa-sentinel`, `ui/` and the MCP runtime scripts, restarts gracefully,
   rolls back on failure, and writes `build-status.json` (the CLI draws it). *Number:* edit-to-running
   time for a one-line Lua change and a one-line Rust change.
2. **Children survive deploys.** Blue/green node: the sentinel starts the new build as a second
   instance (`INSTANCES.md`), moves the chat and new runs to it, and lets the old one drain its live
   children before it exits. Until then, a deploy waits for running children. *Number:* children lost
   to a deploy (target 0) and deploy wait while a wave runs.
3. **Child reports handled by data.** A completion notice never counts as a user turn for the route
   floor (fix hypothesis 1 once the data confirms it). Acceptance reads the deterministic packet
   (`completions.lua:96`: branch, pushed, ahead, dirty) and the diff, never the prose; a missing report
   is a settled state with that packet, not a hang. *Number:* route calls per child report; reports
   absent.
4. **Scope locks.** A child's declared paths are locked until it settles: the coordinator and other
   children get a refusal naming the owner. *Number:* out-of-scope edits.
5. **Resources are reserved and reaped.** One heavy-build slot per node (revive the lease queue in
   `scripts/gate-lane.mjs`), a disk floor (`check-disk-floor.sh`, `jobs/disk-reclaim.json` - built,
   not shipped), and a sentinel reaper for merged/abandoned worktrees and bindings. *Number:* leaked
   worktrees and bindings after a wave (target 0).
6. **Observable mode and outcomes.** Record `enabled_at` and the build commit with the mode; emit a
   toggle event; every run records why it ended; a test that a mode-on session sends `subagent` and
   `route_task` in its tool list. *Number:* unexplained run ends (target 0).
7. **Warm worktree pool.** The sentinel keeps per-repository worktrees with warm build caches and hands
   one out in milliseconds; a fresh worktree's first `cargo test` otherwise compiles everything.
   *Number:* time from spawn to a child's first focused check.
8. **Placement across devices.** The master chat places work on peers through the rendezvous; each
   peer's sentinel runs its own mechanics. *Number:* waves completed per hour across nodes.

### Speed already measured on this node (29/10)

- Code mode: the first script in a process cost ~2.6 s (Cranelift compiling QuickJS); later scripts
  ~115 ms. Fixed by caching the compiled module (`52e6a17a`); to be re-measured after deploy.
- Web search: DuckDuckGo answers bursts with a 202 challenge, which a code-mode fan-out produces;
  fixed by falling back to Bing RSS and caching repeated queries (`0f793908`).
- Image builds compiled every dependency each time (no cache); BuildKit cache mounts added in the
  sandbox Dockerfile, and normal rebuilds move to the sentinel path (step 1).
