# Opt-in current-ref source repair

This adapter is a separately named current effect contract. It does not activate
production, issue a grant, accept its own source, or repair historical truth.
The original v2 driver, registered inspector, ordinary admission/proof helpers,
hook policy, old waves/tickets/operations and legacy records are unchanged.
Global identity safety and production registry admission remain **false**.

Trusted Lua already holding a successful current session claim may load the
independently reviewed `scripts/wave-current-ref-driver.lua` from its exact sealed
source root and call `run({repo,source_file,grant_file})`. The arguments are paths,
never owner/PID/command authority. No model tool or HTTP route is registered.
The source descriptor retains the v2 full blob/runtime/build closure and adds
`runtime.current_ref_driver`, `runtime.current_ref_consumer` and
`runtime.current_user_task:{source_session,source_record_sha256}`; its independent
Git-anchored source review pins the entire runtime object.
The current gate-decision artifact is additionally pinned by
`runtime.current_user_gate_decision:{source_session,records:[{source_line,
source_record_sha256}],gate_policy:"pre-release-only"}`. The grant's
`user_gate_decision:{path,sha256}` must match actual role-user JSONL records and
text; a copied scheduling boolean is not permission. Root's real records are
4074/4093 beside original ordering record 207; fixtures are explicitly private.

The driver obtains `current_executor_observe` from the existing retained session
claim. The native action does not initialize a store, create a schema, allocate
a workspace, inspect global inventory or write target claims/history. It derives
the current principal/session/resource run/boot/claim generation and actual OS
process creation. Child observations must additionally match the exact in-memory
operation the driver launched: its actual owned process handle, creation stamp,
current resource run and direct native parent. Copied JSON, a PID selector or
durable operation annotations cannot manufacture this retained linkage.

The fixed Node child checks its actual PPID, parent/child creation identities,
current claim generation and held boot lease. Native callbacks use a generated
nonce and increasing sequence, accept only `current-check`, and never select a
command, owner, receipt or resource scope. Source/Node/Git/observer bytes are
pinned before launching reviewed JavaScript, and source closure is rechecked.
There is no generic legacy-ignore flag or caller boolean granting authority.

## Immutable current grant

`grant_file` identifies an immutable Git `{commit,path,sha256,review:{commit,path}}`
envelope. The descriptor is `schema:1,kind:"wave-current-ref-source-grant"`; an
independent `wave-current-ref-source-grant-review` binds its exact bytes and
distinct actual Git actor trailers. Actor role is `delegated-operator`, not an
invented human or native session. Operator-local source descriptors map to
`operator-delegated` grant authority; private fixtures use explicit private labels
and require all fixture source/evidence paths under the OS temporary root.

The grant pins current user task source bytes, line/session/role/text identity,
the independently reviewed source/runtime closure, exact current native execution,
owned direct child policy, canonical repo/common directory/main/ref/origin,
delivery/reviewer/external custody, genuine ordinary full/focused producer proof,
and separately reviewed exact candidate head/tree and parents. Current task scope
is `original-deliveries-then-root-chatfix-then-clean-deploy`; it is not a statement
that old effects are safe. The raw complete registered-inspector snapshot stays
read-only, inadmissible, byte-hashed and independently bound as historical facts.
An explicit risk contract acknowledges that unclassified effects remain possible.
Expiry is bounded to one day and each grant has one 32-hex nonce.

Routine merges consume honest ordinary focused evidence; a declared broad
`focused_scope` (exact changed files, fixed check/case IDs and reason) must exactly
match the independent delivery review. The ordinary producer reader validates
original source/head/tree/runner/log/skip identities. Full evidence is not inferred
as a routine prerequisite; explicit pre-release decisions remain the user's.
This adapter changes no ordinary proof helper and never labels focused proof full.
Declared/imported scopes use the shared `verifyReviewedFocused` export and its
immutable reviewer `Focused-Scope-SHA256` binding. That routine-reader dependency
is independently owned; an older reader refuses `routine_reader_dependency_required`
instead of treating mutable matching fields as review or demanding a full gate.

The fixed effect is `canonical-current-ref-source-cas` with publication
`canonical-local-only`. The shared publication SQLite transaction and an actual
Git update-ref **prepared** transaction are held across fresh validation and
durable uncertain reservation before the expected-main CAS. Case/symbolic aliases
and ordinary ref writers obey that physical lock. A prepared verify transaction
then holds the exact new generation during non-forcing two-tree synchronization
and readback; a writer in the handoff gap changes the expected generation and
refuses. Clean index/worktree, current native context, exact origin and actual
remote main readback are checked. Arbitrary filesystem/SQL writers remain outside
ordinary Git exclusion; this is not an OS sandbox or a global safety certificate.

Only `current-source-consumption.sqlite` records fresh requests. Reservation is
FULL synchronous and commits `uncertain` before the effect. Loss, partial CAS,
failed synchronization, crash, expired input or a consumed nonce never triggers
blind replay. Observed local success is stored as `observed-local`; it is still a
consumed nonce. No old record is reclassified, retired, backfilled or replayed.

## Publication and activation boundary

The adapter never pushes a remote, installs, stops a node/window, changes accounts
or model policy, runs inference, or deploys. Its actual local readback does **not**
authorize the old registered wave/hook path to publish or deploy. Ordinary remote
main publication remains a separate sole merge-lane action: exact origin, ordinary
fast-forward and independently reviewed main-writer policy must apply, and any
held-current-grant recognition must be specifically implemented and independently
reviewed for that effect. This source-only task has not supplied that remote adapter.
Root must obtain independent exact code/descriptor review and a genuine current
native execution/grant before activation; source writing is not approval of a grant.

`test-wave-current-source.mjs` builds the native binary from its actual private
source Git tree, retains the real build log, runs a real focused producer check,
and uses separately labelled private grant/review records, real native contexts,
local canonical Git and a local bare remote. It tests refusal reasons, physical
contention, dirty/index/native generation changes, uncertain nonces and crash
preservation. A containing suspended no-breakaway/kill-on-close Windows Job helper
records queried flags, membership, actual exit and active-process count zero.
Fixture labels never represent human production approval or full application proof.

## Capture and exact invocation, after independent code review

`review/current-source-repair/grant-template.json` is a non-authorizing template;
its nulls refuse. Root must fill source/custody/current-grant and review objects
from actual immutable descriptors, and use the original raw user evidence paths.
Do not copy fixture IDs, an old receipt, or the external Orca handle into native
executor fields. The ordinary source descriptor is prepared/reviewed first.

Within trusted native Lua whose `ctx` already came from actual current admission,
invoke the fixed external driver with a trusted parked capture callback:

```lua
-- ctx is the actual admitted current context, never reconstructed from JSON.
local resources=dofile('lua/core/resources.lua')
assert(resources.begin(ctx).ok) -- or use the current successful held admission
local driver=dofile('scripts/wave-current-ref-driver.lua')
local packet={repo=canonical_repo,source_file=reviewed_source_descriptor,
  grant_file=immutable_grant_envelope}
packet.observe=function(phase,observation)
  if phase=='context' then
    assert(host.write_file(current_observation_file,json.encode(observation)))
    while not host.read_file(current_release_file) do host.sleep(10) end
  end
end
local result=driver.run(packet)
-- Keep failures/uncertainty and the fresh nonce; never auto-replay or retire old records.
```

The callback's `observation.context` and actual process/creation/resource_root
populate the grant executor while that same native run remains parked. Source
descriptor runtime tuples pin user record207 and gate records4074/4093. The
delegated issuer commits the exact descriptor; Code2 independently reviews it
and commits the review. Grant envelope:

```json
{"commit":"<grant commit>","path":"<tracked grant path>","sha256":"<exact raw grant blob SHA256>",
 "review":{"commit":"<independent review commit>","path":"<tracked review path>"}}
```

The review object has `kind:"wave-current-ref-source-grant-review"`,
`verdict:"passed"`, `descriptor_commit`, `descriptor_path`,
`descriptor_sha256`, and distinct `reviewer`; each commit ends with its actual
actor provenance trailer. Write the reviewed envelope and only then release the
parked callback. The driver itself starts the one fixed CLI:

```text
<pinned Node executable> <sealed root>/scripts/wave-current-ref-bootstrap.mjs <canonical repo> <source descriptor file> <grant envelope file> <fresh driver-generated channel>
```

That CLI cannot be invoked independently with supplied JSON authority: its native
parent, exact owned operation/child, channel nonce and source/runtime closure must
all be retained and live. This document/template does not create the admitted
context, authorize Root's grant, or activate production.

Risk: readonly process identity capture adds a bounded OS observation to ordinary
operation launch. Missing observations only narrow the new accessor; ordinary
launch/stop/settlement behavior and serialized operation records remain unchanged.
No performance/default improvement or historical safety is claimed.
