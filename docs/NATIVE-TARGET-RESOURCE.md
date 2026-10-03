# Native held target resource

The capability retains cooperative exclusion while trusted Lua/Node inspects,
reserves, and executes an external reviewed publication command. Rust supplies
owner identity, normalized scope, complete resource inventory and OS-held leases;
it neither chooses a Git command nor approves source, policy, a reviewer or an
external effect. Operation/subagent inventories, source review, reservation,
exact Git generations and CAS remain separate consumer checks.

## Callable contract for the wave JavaScript consumer

Calls use the existing `host.resource(action, JSON.stringify(args))` Lua boundary
and return one JSON string. A trusted Lua driver must keep the **same native
thread and process** alive across the sequence. A new CLI process per call, a
Node-created receipt, or `wa-operation Manager.identity()` cannot hold authority.
The driver begins through the existing `resources.begin(ctx)` / `claim` with
`session:<ctx.session_id>`. Only successful session admission captures native
resource context, from the actual durable claim: principal, session, resource
run UUID and resource-store boot. The transport's numeric run id is a different
identity. Target calls re-read the exact session claim and require it to remain
owned, active and certain, including its native-created claim generation. They
take **no caller owner/boot/PID/creation fields**.

The only scope arguments are `{git_common_dir, ref}`. Lua/Node supplies the Git
common directory obtained from its verified repository and a full exact ref such
as `refs/heads/main`. Rust resolves the existing native directory through
symlinks/junctions, uses `/` separators, folds Windows path case conservatively,
validates the full ref, and hashes the common directory to a resource key. Exclusion
conservatively covers all refs there, including case and symbolic aliases; the
receipt retains the exact requested ref. This does not prove
that the directory is Git metadata or that the caller selected the intended
repository: the reviewed consumer verifies those facts. Ref expressions,
wildcards, pagination, filtering and unknown argument fields are refused.

| Action | Arguments beyond scope | Result / effect |
| --- | --- | --- |
| `target_inspect` | none | A fresh complete SQLite snapshot with `schema:1`, `kind:"target-resource-inventory"`, `scope`, `complete`, `admissible`, all `claims`, and all `conflicts`; no target acquisition |
| `target_hold` | none | Acquires the scope's OS-held SQLite exclusive lease, then re-inspects inside an immediate claims transaction; refuses incomplete/conflicting ownership; commits a durable target claim and returns `{ok:true, receipt, inventory}` |
| `target_check` | exact `receipt` object | Requires an actual native-held lease, exact exported receipt, unchanged context, full durable target identity and a fresh admissible inventory; returns `{ok:true, held:true, receipt, inventory}` |
| `target_release` | exact `receipt`, nonblank inspected `evidence` | Performs the same validation, records evidence in history, deletes only that exact target claim, then drops the held lease; returns `held:false` |

`receipt` contains `schema:1`, `kind:"held-target-resource"`, `key`, `receipt_id`,
`principal`, `session`, `run`, `boot`, `session_claim_id`, actual `process_id`, OS `creation_stamp`,
and normalized `scope`. Windows creation identity is `windows-filetime:<u64>`
from `GetProcessTimes(GetCurrentProcess())`; Linux is
`linux:<kernel-boot-uuid>:<process-start-ticks>`. Unavailable creation observation
prevents target acquisition. Other platforms retain old APIs but cannot issue a
held target receipt. Caller JSON can compare a receipt only with a capability
already held natively; copying it cannot create, adopt or recover that capability.

Consumers must require exact schema/kind, `ok:true`, `complete:true`, `identities_complete:true`,
`admissible:true`, and zero conflicts. A storage/query error returns
`{ok:false,error}` through the existing host wrapper; a hold/check conflict also
returns its fresh inventory. Missing fields, empty/malformed responses and an
unknown capability are refusals. A partial query is never interpreted as no
conflicts. The returned inventory names every durable claim, including legacy
claims; there is no cap, pagination or hidden-owner omission.

Each claim retains `key/principal/session/run/boot/uncertain` and adds `identity`,
`identity_complete`, `liveness`. Newly created claims have side-table process
identity and a type: `session`, `named`, or `target`. Session claims serialize
conversation execution and alone are not publication claims. Named claims have
unknown target scope and conservatively conflict. Typed target claims conflict
on the common directory; only the actual native-held owner's exact receipt is excluded
from that conflict. Missing identity, unverifiable liveness and any uncertain
claim refuse admission. This is deliberately conservative across the resource
store: an unrelated legacy/named/uncertain claim can block target admission.

Liveness remains the existing OS-held resource-boot SQLite lease, never a PID,
timeout or creation stamp inference. `held`, `held_or_unavailable`,
`lease_released`, and `unverifiable` describe lease observation; a released lease
does **not** prove descendant drain, absence of external effects, execution
success, or safe retry. `complete` means the complete registry query succeeded;
`identities_complete` separately reports whether every returned owner has known
identity/liveness. Neither is a complete inventory of operations/subagents/external
writers. Missing identities are still returned, with named conflicts and refusal.

The driver acquires before the JS consumer's fresh source/conflict inspection
and consumption reservation, retains the lease while `host.exec` / an owned
operation executes the verified JS closure, validates its actual settlement and
effect readback, then checks and explicitly releases. The fixture demonstrates
fresh native and external SQLite inspection plus reservation and Git CAS while
the native lease remains held. Returning `{held:true}` alone is not authorization
to let the owner exit and later publish. A production consumer must bind its
reviewed closure, publication generations and operation settlement separately.

## Preservation and trust boundary

Old API inputs/fields and reconcile/recover owner denial remain intact. New
metadata is written only for newly inserted claims; reentrant admission never
upgrades historical identities. Claim receipt rows are read from SQLite, not
echoed caller session values. `finish` refuses while that run retains a native
target lease, so ordinary settlement cannot silently drop a target. `uncertain`
and `recover` retain their old semantics, evidence and audit history. An uncertain
target fails checks/releases; a crash drops OS locks but retains durable claims
as conflicts for explicit existing reconciliation. No automatic replay, drain
claim, historical migration or cleanup is introduced. In particular the original
33b4 record is neither changed nor furnished with fabricated creation/drain proof.

Authority is **cooperative trusted Lua/Node admission in one resource home**.
The existing `claim` interface takes identity from trusted Lua policy; it is not
an independently authenticated public endpoint. Arbitrary Lua, SQL writes,
operator shell, nonparticipating Git writers, another resource home, filesystem
replacement and privilege are outside this exclusion contract. It is not an OS
sandbox or an atomic guard against arbitrary Git writers. Git CAS still protects
the exact expected ref generation. The scope/ref/path normalization itself is
not a repository policy decision. Windows case folding may conservatively alias
case-sensitive directories; no availability/performance improvement is claimed.

## Executed focused tests

Use Git Bash explicitly on Windows, with native binary/Lua/home paths:

```sh
CARGO_BUILD_JOBS=2 RUST_TEST_THREADS=2 cargo test --offline --manifest-path rust/Cargo.toml -p wa-host resources::tests -- --nocapture
CARGO_BUILD_JOBS=2 cargo build --offline --manifest-path rust/Cargo.toml -p wa-host
node scripts/test-native-target-resource.cjs <native-built-wa-path>
node scripts/test-resource-claims.cjs <native-built-wa-path>
```

Set a unique native `CARGO_TARGET_DIR` when another lane builds. The Node harness
sets `WASM_AGENT_LUA_ROOT` to the source tree, private runtime homes/transcript
databases, no provider endpoints, and uses actual separate processes, OS creation
observations, SQLite leases, one owned fixed source-pinned external Node effect,
a private consumption reservation and scratch Git CAS. It preserves crash owner
rows and reports hashes/log paths. Rust tests additionally exercise foreign and
replaced context/target owner, modified receipt/scope, partial/missing queries,
uncertainty and original API semantics. The source-pinned fixture is not an
independent reviewer approval; delivery review and production consumer review
remain separate. No production stores, publication, install, restart or deploy
is performed. These focused tests do not replace the combined full gate.
