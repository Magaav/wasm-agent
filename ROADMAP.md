# Roadmap — one agent, independent use and assisted automation

## North star

**Install an agent, not an infrastructure project.** It remembers on request,
does useful work, shows the consequences, and can reach authorized machines.
Its identity survives a model change; adding a device adds capabilities rather
than creating an unrelated personality.

An automation professional should be able to apply their expertise, models,
tools and tested procedures to customer tasks through explicitly connected guest
nodes. A customer should be able to receive that help without becoming a developer.

These are two entry paths into one runtime:

| Path | The person buying into the experience | Promise |
| --- | --- | --- |
| Personal | Someone running their own agent | My agent, my model, my work, continuity across sessions and authorized devices. |
| Assisted | A customer working with an automation provider | Help automate my tasks; show me who has access, what they may do, and how I stop it. |
| Operator | The automation professional serving those customers | Reuse my arsenal safely across engagements, with separate customer authority, data, evidence and costs. |

The fleet console serves these journeys. It is not the product's required first
screen, and 32 workers are not a prerequisite for helping one customer.

## Status vocabulary

- **Implemented:** a mechanism exists in the repository; not a release certification.
- **Release gate:** must be demonstrated against the candidate artifacts.
- **Planned:** desired behavior, not something users may rely on yet.

Current mechanisms: local CLI and Windows companion; streaming chat; explicit
memory; resumable sessions and compaction; tool evidence; tracked diffs and
conflict-aware undo; signed nodes, rendezvous and relay; master/guest roles;
skills, spells and plugins; external sentinel; on-demand workers; supervised shell
operations and managed automation jobs. Jobs (Engine, after tools) queue wakes or
allow-listed deterministic actions from event/schedule/file/explicit CDP bindings.
See [operation contract](docs/OPERATIONS.md) and [jobs contract](docs/JOBS.md) for
the precise implemented boundaries, tests and remaining platform/adapter limits.

Windows candidate packaging, a fresh installer and launcher setup/diagnostics now
exist; clean-machine usability and public distribution remain gates. Guest setup
is deliberately disconnected, not a shortcut around authorization.

Missing product boundaries: stable agent identity beyond display metadata;
customer invitations,
consent, scoped authorization, isolation and revocation; trustworthy operational
status and an operator engagement view. Existing concurrency is not yet proof
of safe overlapping conversations. See [release status](docs/release/RELEASE_STATUS.md).

## 0. Establish safe execution boundaries — blocks external use

Reuse the current host, core and UI. Close the authority and ownership gaps
before making connection to the environment easy.

- Reject missing/invalid authority on privileged HTTP routes; explicitly design
  local UI authentication, allowed origins/hosts and request limits.
- Separate authentication session, conversation, run, worker and event-stream
  ownership. Serialize by the actual conversation, including queued requests;
  do not route authority through interpreter-local login caches.
- Route stream events to their own run/subscriber, not a global socket. Prove
  overlapping direct and relayed streams cannot mix.
- Remote authorization must fail closed. Discovery and self-declared `master`
  status confer no customer access. Pin enrolled operator identities by key/id,
  not by a mutable display name alone.
- Native capabilities require an honest authority statement. A workspace picker
  cannot enforce a path boundary on an unrestricted shell. Restrict/disable the
  capability or use an OS-level boundary where confinement is promised.

**Exit evidence:** negative tests for unauthenticated and foreign-origin access,
invalid/stale/replayed peer requests, wrong customer/operator, cross-worker role
leakage, two simultaneous streams and two simultaneous writes to one conversation.
No attack tests against customers or the live operator session.

## 1. Independent Windows-first package and personal setup

Build a coherent versioned artifact from one source revision. No private SSH,
maintainer configuration, checkout or compiler is required to run it. OS/runtime
requirements such as WebView2 must be detected and explained, not assumed.

- Bundle node, shell, required loader/assets and supervision support with a file
  manifest and checksums. Build provenance and package integrity are distinct
  from publisher authenticity and behavior verification.
- Deliver neutral runtime guidance, not this repo's contributor `AGENTS.md`.
- Add thin setup and read-only diagnostics using current configuration/paths.
  Collect a friendly agent name, compatible model settings and workspace choice.
  Mask credentials; do not pass them in CLI arguments or diagnostic exports.
- Distinguish configuration saved, provider validated and first task verified.
  An offline provider must not make local memory unusable.
- Preserve identity, user configuration, memory and sessions on setup rerun.
- Fresh installation is separate from update. Existing installations continue
  through the external upgrade/sentinel boundary; never overwrite a live binary.

**Exit evidence:** clean Windows user, packaged bytes outside the checkout, no
Lua/script overrides, no private host access. Install → setup → tool-backed edit
→ inspect diff → remember a random fact → restart/new session → recall → undo.
A later conflicting edit must survive an attempted undo. Test bad credentials,
missing assets and interrupted runs. `setup`, `doctor` and `ui` are now supplied
by the packaged Windows `bin/wa.cmd` launcher, not by native `wa.exe`. The guest
entry point stages an offline profile and refuses networking; it is not enrollment.

## 2. Invited guest onboarding — first-class assisted automation

This is not an optional afterthought to personal setup. The first assisted pilot
pairs **one operator and two isolated customer environments**, so separation is
tested rather than inferred from a single successful connection.

### Customer journey

1. Download the same independently distributed runtime and choose **Get help**.
2. Accept a short-lived, single-use invitation. See and verify the operator's
   identity, the service being joined and the requested access.
3. Approve the task and access grant. Explain files/apps involved, model-provider
   data flow, remote visibility, retention and who pays. Credentials stay on the
   side that needs them; never copy the operator's provider key to the guest.
4. Connect outbound through the rendezvous/relay. No router changes, SSH account
   or public listener on the customer's computer.
5. Watch progress and review results. Show an unmistakable remote-access state,
   the responsible operator, activity history, pause and disconnect controls.
6. Revoke locally. Restart, reconnect, retries and queued requests must not
   restore revoked authority. Explain actions already performed and whether an
   in-flight native operation can actually be cancelled.

A customer needs no BYOK merely to receive assistance: the operator can reason
on their side and call authorized capabilities on the guest. Local autonomous
reasoning can remain separately configurable. Service outage means unavailable
assistance, not fallback to broader privileges.

### Authorization contract

An invitation is not a permanent permission. Enrollment binds a specific
operator identity to a specific customer/device. Grants state capability,
resource boundary, approval mode and expiry. Changes need renewed consent.

Support attended assistance first. Unattended automation is a **separate,
explicit, expiring grant** for a reviewed procedure—not a permanent administrator
switch. Arbitrary desktop/shell control must be clearly described as broad access
unless a real isolation mechanism limits it.

Guest node status does not demote the human owner: the owner controls the
relationship. Guests cannot discover other customers' private inventories,
read their histories or become transit points into the operator's environment.
Default transcript replication must not mix customer data into a shared memory.

**Exit evidence:** invited customer completes a real automation without developer
help or their own model key; declined/expired/reused invitation does nothing;
wrong operator and customer are refused; pause/revoke survive restart and queued
relay delivery; customer A cannot read or act on B. Verify direct and relay paths,
and perform a threat-model review before inviting real customers.

## 3. Turn expertise into reusable, controlled automation

The operator's arsenal is a library of capabilities and **verified procedures**,
not a growing prompt or a reason to grant every customer every tool.

- Use skills to explain procedures, spells to execute deterministic steps and
  plugins/native adapters for capabilities. Reuse these before adding a framework.
- Managed jobs now provide default-off definitions, revision invalidation, durable
  bounded delivery queues and source/action evidence. Site-specific adapters
  (including WhatsApp), replayable browser event delivery, customer unattended
  grants and immutable procedure packages remain work, not implicit guarantees.
- Promote a successful task into a versioned automation with inputs,
  preconditions, postconditions, authority requirements and failure behavior.
- Keep customer secrets and identifiers out of shared templates and fixtures.
- Preview intended effects; distinguish reversible tracked edits from irreversible
  external actions. Approval is specific to the material operation.
- Expose run history, last verified success, exceptions and operator intervention.
  Scheduled/event-triggered execution needs customer authorization, limits and
  a stop control—not merely an enabled sentinel trigger.

**Exit evidence:** use one reviewed automation for two isolated customers with
different inputs; demonstrate failure, duplicate delivery, cancellation and a
version update requiring fresh approval where permissions change.

## 4. An operator console that knows the work

Keep the avatar and compact chat for everyday use. Add an operator view when the
number of real engagements needs it, reusing the existing UI components.

The console answers: **whose task, on which device, under which grant, what
changed, what is waiting on a person, and what needs recovery?**

- Customer/engagement boundary first; node/session lanes inside it.
- Task assignment, authorization status, last meaningful progress and deadlines.
- Per-run evidence, costs (unknown where unmeasured), outcomes and exports.
- The agent can query the same authorized fleet state; the UI is not the only
  place orchestration knowledge exists.
- Fleet/task state belongs in a durable service, not solely in browser memory.
  Closing the window must not lose a job or change who owns it.
- Bounded concurrency, cancellation, backpressure and per-customer budgets before
  16–32 lanes. A heartbeat is not evidence of task progress or completion.

**Exit evidence:** two customers, multiple nodes, concurrent tasks, browser reload
and a worker interruption; status and evidence remain correctly attributed.
For coding tasks, compare/merge applies to workspace changes; non-coding tasks
need their own observable effects and success checks.

## 5. Extend the reach after the first journeys work

- More operating systems and device surfaces, including mobile pairing.
- Shared agent identity above node keys, models and workspaces, with explicit
  synchronization, privacy, export, deletion and retention policies.
- Capability installation with reviewed permissions and provenance; no marketplace
  of unrestricted code presented as safe because it has a `.wasm` extension.
- WIT/Component Model and a WASI-hosted core where they solve demonstrated
  portability or isolation needs. No migration merely to match the project name.
- Voice and local wake word after useful tasks, visible state and consent work.
- Model routing with explicit cost/privacy policy; switching intelligence must
  not silently send customer data to a newly selected provider.

## Delivery discipline

Each milestone is small integrated slices on short-lived change branches.
The node's home branch stays current; it is not a perpetual release branch.
One writer owns each shared entrypoint during a change. Merged artifacts are
verified again; independent verification is not the implementer's self-report.

Use at most two implementation lanes initially: packaging/onboarding and
execution/guest authorization, with independent verification. Do not expand
lanes just because workers exist. Do not let cosmetic renames or unrelated
features block the first external-user journey.

Measure time to first verified result, return-session success, operator
intervention/rework and verified customer outcomes. Tokens and tool-call counts
are diagnostics, not a score for useful automation.

A milestone is not complete because its demo looked alive. It is complete when
its declared journey and refusal/recovery paths pass against the same candidate.
See the [release contract](docs/release/RELEASE_CONTRACT.md) for the go/no-go gates.
