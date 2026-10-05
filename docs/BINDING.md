# Bind an existing node (binding protocol 1)

`/bind` and `wa bind` are deterministic local CLI controls, not model prompts.
They preserve the existing node key, ledger, current conversation, local role,
provider credentials and settings. They never install a package, change Git,
expose an inbound port, enable jobs or create a login service. The CLI owns an
outbound-only capability runtime for its lifetime. A separate process must not
attach the same identity concurrently; a per-home native OS lease enforces this.
A pre-existing server's ledger lease also refuses adding a CLI attachment; stop
that server deliberately before binding here, never silently kill/restart it.
Closing the CLI disconnects transport; consent/approval survive until expiry or
revocation. A one-shot `wa bind <service>` stores/submits pairing and then exits;
use `wa bind run` to keep its explicit foreground, model-free transport alive.
`wa bind status` is read-only and never claims the connection lease.

## Human controls

- `/bind [https://service]`: inspect service, display exact operator IDs and key
  fingerprints, confirm full current-user-account file/process authority by typing
  `BIND`, then submit a signed ten-minute pairing request. No noninteractive flag
  silently approves consent. HTTP is permitted only for literal loopback fixtures.
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

Consent lasts 24 hours; pairing lasts ten minutes. Approval never confers network
master or administrator status. A master can discover and initiate peer requests,
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
expiry, revocation/restart and no guest-to-guest execution. Never attack the live
service. Runtime deployment does not authorize accepting/promoting a real device.
The tests do not authenticate first-contact keys beyond HTTPS and human pin
approval, provide an OS sandbox, or prove cancellation of already-running effects.
The Unix host writes private temporary/final binding files mode 0600; Windows
inherits the selected user-state directory's ACL. No new ACL/security sandbox
claim is made.
