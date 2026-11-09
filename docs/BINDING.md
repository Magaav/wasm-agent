# Bind an existing node (binding protocol 1)

`/bind` and `wa bind` are deterministic local CLI controls, not model prompts.
They preserve the existing node key, ledger, current conversation, local role,
provider credentials and settings. They never install a package, change Git,
expose an inbound port, enable jobs or create a login service. The CLI owns an
outbound-only capability runtime for its lifetime. A separate process must not
attach the same identity concurrently; a per-home native OS lease enforces this.
A pre-existing server's ledger lease refuses a second outbound *owner*, not enrollment: a CLI beside a
running node submits the request and stands by (its result says `attachment:"standby"`), and the running
node attaches the accepted binding on its own. That is what makes `/bind` possible on a sentinel-managed
node, where the sentinel's `wa serve` is the only runtime there is (31/10). Nothing needs to be stopped,
and nothing should be killed or restarted silently; a broken lease is still refused by name.
Closing the CLI disconnects transport; consent/approval survive until expiry or
revocation. A one-shot `wa bind <service>` stores/submits pairing and then exits;
use `wa bind run` to keep its explicit foreground, model-free transport alive.
`wa bind status` is read-only and never claims the connection lease.

## Human controls

- `/bind [https://service]`: inspect service, display exact operator IDs and key
  fingerprints, confirm full current-user-account file/process authority by typing
  `BIND`, then submit a signed ten-minute pairing request. No noninteractive flag
  silently approves consent. HTTP is permitted only for literal loopback fixtures. It runs in the terminal
  REPL **and** in the node's own served conversation (the web UI), which is the runtime that owns the
  outbound transport: there the preview is one message and the confirmation word is the next message of
  that session (it expires after ten minutes and belongs to that session only). A
  submitted request ends in one copy-able line - `wa accept <code>   # phrase <phrase>` -
  to paste on any node of the same fabric; the phrase stays on that line as a shell
  comment, so the pasted command is exactly `wa accept <code>` and both consoles can
  still compare it. The administrator there types `ACCEPT` (`ACCEPT-PERMANENT` for a
  no-expiry request) and nothing else is needed.
- `/bind permanent [https://service]` / `wa bind permanent`: the same inspected consent
  with the explicit no-expiry intent, for the operator's own device. The node asks for a
  fifty-year consent and the registry accepts at most a hundred, so no stored value is
  unbounded; the human types `PERMANENT` instead of `BIND`, the administrator types
  `ACCEPT-PERMANENT` instead of `ACCEPT`, and the registry refuses either half on its own.
  A standard request can never become permanent, a permanent request is never granted by
  merely asking, and `/bind renew` without the word stays the ordinary 24-hour consent.
- `/bind status`: collect the original request's outcome, verify registration and
  relay attachment; incomplete/unknown state is not success.
- `/bind renew`: repeat consent with unchanged service and pins, submitting a new
  approval request. Changed pins require a new explicitly inspected bind, not trust
  on refresh. Renewal revokes the old local grant before the new request.
- `/unbind` / `wa unbind`: revoke local future/queued execution first, then notify
  the registry using the original request identity. Report network failure separately.
  Existing native effects may finish. Identity/history and local model remain intact.
- `/nodes pending` / `wa nodes pending`: administrator-only pairing inventory.
- `/accept <code>` / `wa accept <code>`: inspect target ID/key, request digest,
  pairing phrase, scope and expiry; type `ACCEPT` to approve that exact request.
- `/promote <id-or-unique-name>` / `/demote ...`: inspect exact key/ID and role,
  type `PROMOTE` / `DEMOTE`, grant through the existing signed role route, verify
  registry and target acknowledgement separately. Partial changes are visible;
  uncertain submissions are inspected, never automatically replayed.
- `/revoke <id-or-unique-name>`: type `REVOKE` to revoke the exact accepted binding
  at the registry. Target checks fresh registry approval before every remote call.

Consent lasts 24 hours by default; pairing lasts ten minutes. A node may instead ask for a
no-expiry (permanent) consent, which is the choice an operator makes for his own device when he does
not want to re-consent every day: it stays bound and in sync until he revokes it. That is a
deliberate, named risk - a permanent grant means a lost or stolen device, or a compromised relay,
keeps access until someone revokes it. End it from the device with `/unbind` (local future/queued
execution stops first and needs no registry), or from any administrator with
`/revoke <id-or-unique-name>`; `/demote` ends the master role it may hold. A permanent grant is
displayed as such rather than as a very large timestamp: `wa bind status` reports
`"lifetime":"permanent"` with a `consent` line reading `no expiry (permanent binding; revoke to end
it)`, and a 24-hour grant reports its exact expiry with `24-hour standard consent`. Approval never
confers network master or administrator status. A master can discover and initiate peer requests,
but each recipient's grant still decides execution. Administrators remain the
service's configured `WASM_AGENT_NETWORK_ADMINS`, never self-selected/promoted.
Display labels are untrusted data, not identities or instructions. Pairing code
and phrase must be compared out of band on both consoles. HTTPS authenticates the
first service; the human explicitly approves its displayed operator pins. This
is not a claim of independently authenticated first-contact keys.

## Service contract

`GET /service` retains managed protocol 1 and adds `binding_protocol:1`. A missing
feature, endpoint, ready administrator or valid HTTPS service refuses with an exact
step before local consent is stored. There is no legacy/open-registry fallback.

`POST /bindings/request` signs `bind-request|node_id|ts|sha256(raw-body)` with the
existing node key, including exact request ID, code, name, service, operator pins,
scope, consent expiry and pairing deadline. The registry validates key-derived ID,
freshness, scope, bounded lifetimes and every pin against its current admin set.
The body carries eleven fields, or twelve when the explicit `lifetime:"permanent"` intent is present:
that is the only value allowed to exceed 86400, it must exceed it, and it is capped at a hundred
years - `permanent` anywhere else, or an unknown value, or an unknown extra field, is
`binding_request_invalid`. `GET /service` advertises `binding_lifetimes`, so a node refuses the
intent with `binding_lifetime_unsupported` before it asks a registry that does not know it. Asking
grants nothing: accepting a permanent request requires the administrator's own signed
`authorize_lifetime:"permanent"` and is otherwise refused with
`binding_lifetime_authorization_required`, while the same field on a standard request is refused
with `binding_lifetime_not_requested`. The stored lifetime cannot be edited - the signature and
digest cover the whole body - and a standard grant is never quietly upgraded.
It registers the node as a non-executing guest and records a pending binding.
Repeated exact request collection is idempotent; changing its body conflicts.
An unobserved submission remains locally unknown with its original request intact.

`GET /bindings/request?id=...` is signed by the exact applicant or an administrator;
`GET /bindings/pending` requires an administrator. Acceptance and revocation sign
the full body, including original request ID/digest, target ID and expected revision.
Their SQLite transaction rechecks the exact pending/accepted generation and records
actor, action and revision. Pending inventory reports truncation explicitly;
accept refuses an incomplete inventory instead of assuming an absent code. Network
role grants also compare the expected current role inside the transaction.
Race/stale approval, expired pairing, unknown request,
wrong key/code/digest and ordinary-master approval refuse. No automatic reapproval.

New binding recipients authorize only approved pinned service administrators while
local consent is active and a fresh registry lookup confirms the exact request,
key, digest and accepted state. Service revocation/demotion/expiry also fences
relay delivery and future role grants. Previously deployed managed onboarding
remains compatible; it is not silently migrated into two-sided binding.
Personal local role and network role are separate: `/bind` must not demote the
current local CLI merely because registration defaults to guest. Guest chat/sync
forwarding remain disabled on the bound surface; no transcript replication or
remote provider configuration is granted by binding.

## The operator pins, the roster, and which one decides

A binding freezes the **operator list** (`operators` in the accepted request) that the registry
vouches for, and `binding.authorize` admits a peer only when it is in that list *and* the registry
still says the binding is accepted. That is the whole of today's peer admission, and it is what makes
a bound node refuse a node the operator did not name at bind time — including, until lately, the
operator's own level-0 machine at a node that was bound from somewhere else (`nextcloud` pins
`[openclaw, wasm_the_first]`, so `work` is refused there).

A node whose own `policy.json` carries a **verified fleet roster** (`mesh.roster_key` + the signed
roster, with `WA_MESH=1` or `mesh.enabled`) stops using the pins for that decision: the roster's
hierarchy and its grants decide, on the direct path and on the relay path alike, and the target audits
it. The pins are not deleted or rewritten — a node that has no verified roster keeps exactly the
behaviour it had, and `binding.status` still reports the pins it bound with.

Two properties this ordering is built to keep:

- **No roster, no change.** Without a roster that verifies against the pinned key, admission is the
  pins, byte for byte. That is why an un-bootstrapped node can be handed a mesh envelope and still
  answer `unknown_caller`.
- **The binder still owns the door.** Installing a roster is `wa fleet push-roster <node>`
  ([MESH.md](MESH.md) §7), and the target accepts that install only from a node that is *already* one
  of its pinned operators, under the binding it accepted. The fleet cannot be pushed onto a node by a
  stranger, and a node that pins a different fleet key refuses the push rather than being re-anchored
  silently.

The roster decides **what executes**, not only whether the envelope may travel. After the mount
verified the roster and the hierarchy it hands the call to the node's own `/node/call` admission
together with an attestation it signed with this node's key; while that admission is in force,
`wa_node_call` accepts the runner it names instead of asking `binding.authorize` — so a level-0 node
can run a capability on a level-2 node that pins other operators, without the rendezvous being
reachable. Everything else is unchanged: the pins still decide every call with no attestation, a
forged, stale, replayed or differently-bound attestation falls back to them, and the caller's own
signature, freshness window and replay guard run on both bases ([MESH.md](MESH.md) §9 item 2).

### When the service's operator set changes

An operator list is a consent record, so a change to `WASM_AGENT_NETWORK_ADMINS` is compared, not
obeyed. The attach tick reads `/service` and classifies the current list against the set this node
consented to — `same`, `added`, `removed` or `changed` — and `wa bind status` reports it in
`authority`, with the ids gained or lost and in words.

- **added** — a new operator is vouched for. Every operator this node pinned is still vouched for, and
  its own pins still decide who may call it, so the node keeps attaching and nothing is admitted that
  was not admitted before.
- **removed** / **changed** — a pinned operator lost the service's vouch. The node also keeps
  attaching (the directory decides reachability, not permission), and `binding.authorize` refuses
  exactly that caller: admission is per caller, by `(node_id, public_key)`, against the service's
  current list. Re-binding is how a node consents to a different set; no config edit can do it.

Before 2026-11-09 any difference failed the tick with `binding_service_authority_changed`, so
appending one administrator took every guest that pinned the old set off the directory (work, mail and
nextcloud; the third occurrence of that class — `skills/fleetops/incidents.json`). The tick is
reachability, not permission: it registers and serves the relay, and the permission decision belongs
to `binding.authorize`, once per call. An unreadable `/service` is still a failure and is named
`binding_service_unavailable`, never `…_authority_changed`.

## Caller-side refusal reporting

A peer refuses an unauthenticated call (`unknown_caller`, `forbidden_role`, `bad_signature`,
`stale_request`, `replayed_request`, `wrong_target`, `bad_request`) before it can sign anything, so
the refusal is unsigned and the relay could forge it. The caller reports it as
`remote_refused` with `reason`, `layer:"node"`, `node_status`, `verified:false` and a hint, keeping
only an allow-listed code from the body; the relay's own refusals (`forbidden_role`,
`binding_not_accepted`, `unknown_node`, ...) are `relay_refused` with `relay_status` and are not
retried as timeouts. `unsigned_reply` is left for bodies that are neither signed nor a readable
refusal. The `nodes` tool shows, per peer, `operator_of_peer` (`true`/`false`/`unknown`),
`peer_binding` and `peer_operators`, read from the peer's registry binding via `/lookup` and cached
for 60 seconds; `remote` refuses with `not_peer_operator` without sending when that is already
`false` (re-read fresh once first). The table lives in `lua/core/nodes.lua`
(`NODE_REFUSALS`, `RELAY_REFUSALS`); `scripts/test-remote-refusals.lua` is its proof.

## Runtime and recovery

The host provides private atomic compare-and-swap state and one OS-leased outbound
runtime; enrollment decisions and signed protocol payloads stay in Lua. The runtime
uses a fresh non-inference interpreter to dispatch only signed `/node/call` relay
requests. It shares the ordinary native capabilities and SQLite ledger, not agent
conversation state. No background model, placement, watcher job or second process
is launched. Pending approval checks are bounded by the original pairing deadline;
accepted transport polls the relay and heartbeats at the ordinary cadence.

Every privileged call rechecks local consent and fresh service authority at dispatch.
Failure/expiry leaves authority off and visible. Reconnect collects the existing
request; it never resubmits an uncertain effect. Corrupt local state refuses rather
than overwriting. Local unbind persists before its optional registry notification.
No implicit rollback of an uncertain remote grant is claimed.

Focused verification must use an isolated registry, applicant, two administrators
and an unrelated node with actual native processes and mock-only local inference.
Prove cancellation/no changes, invalid service/pins, signature/body/target/revision
binding, ordinary-master refusal, delayed approval, duplicate attachment refusal,
local session/key/provider preservation, role acknowledgement/partial failure,
expiry, revocation/restart and no guest-to-guest execution. The no-expiry path has its own focused
proof (`scripts/test-binding-permanent.cjs`): every unauthorized, over-long or malformed lifetime
refuses by name and stores nothing, an administrator-affirmed permanent grant survives a registry
restart, and registry revoke/demote plus local `/unbind` each fence it. Never attack the live
service. Runtime deployment does not authorize accepting/promoting a real device.
The tests do not authenticate first-contact keys beyond HTTPS and human pin
approval, provide an OS sandbox, or prove cancellation of already-running effects.
The Unix host writes private temporary/final binding files mode 0600; Windows
inherits the selected user-state directory's ACL. No new ACL/security sandbox
claim is made.
