# Managed guest onboarding (protocol 1)

Target: paste one PowerShell command, choose a name while a verified package is
installed in the background, approve remote assistance, and connect outbound as
a guest. No model key, Git checkout, compiler or inbound customer port is needed.
The operator's agent reasons on the operator side and sends signed tool calls.

## Required service boundary

The public bootstrap must refuse a legacy/open registry. A managed rendezvous
has `WASM_AGENT_NETWORK_ADMINS` set to comma-separated **node IDs**, never names.
Its `/service` response advertises protocol 1 and the registered administrator
public keys. Registration defaults to guest; a claimed master role is ignored.
Only a signed, body-bound request from a configured administrator changes a
non-administrator's network role. Registration cannot overwrite a node ID with
another key; node IDs are derived from the public key.

Managed guests pin the administrator IDs **and keys** approved during onboarding.
Every incoming call verifies the signature, freshness, target node ID, active
local consent and that the pinned administrator is still a current service admin.
The relay transports only signed node API routes, not unauthenticated UI routes.
Requests/results are bound to sender and recipient, including across retries.
Guest chat/sync forwarding is disabled: assistance does not require a model on
the guest and must not replicate customer transcripts by default.

Access is explicitly **full Windows-user-account automation**, not a workspace
sandbox: approved file/process tools can reach what that account can reach.
The consent prompt must say this before enabling remote execution. Do not market
a deny list as protection against an authorized operator running arbitrary code.
The owner can revoke with `wa disconnect`; `wa access log` shows recent local
operator/capability/completion records (not a tamper-proof account of shell effects).
Revocation refuses queued/future calls and survives restart. It cannot undo already completed effects or reliably cancel every native
operation already executing. Initial consent expires after 24 hours by default (`-Hours` may be selected by the
owner); `wa connect` renews it with consent. No automatic login task is installed.
Renewal is a local owner action, not a model decision. Disconnecting assistance
does not remove an already promoted owner's local master role.

## Promotion

`wa network role <node-id> master` is an administrator operation, independent of
any model. The registry grants the role first; a signed, target-bound call then
updates the enrolled node's local role. A failed second step is reported as a
partial change, not success. Demotion uses the same command with `guest`.

Promotion does not grant access to every other customer. Each managed recipient
still checks its pinned operator grant. A node owner can edit their own computer;
they cannot obtain a network role merely by changing a local role string.

## Distribution and launch

The bootstrap downloads a versioned ZIP while asking for the name. It verifies
the declared SHA-256, checks archive entry paths, runs the fresh installer and
uses an isolated service data home. It never inherits operator credentials or
overwrites an existing installation. A per-user command shim makes `wa` usable
in the current PowerShell and future terminals. It starts only the new node,
checks its PID/port, registration and outbound relay attachment, and records how
to disconnect it.

A release descriptor identifies the exact package URL/hash and expected service
administrator IDs/keys. Names and URLs alone are not operator identity. HTTPS is
required except explicitly selected loopback test endpoints. Cancellation stops
the background installation job; no consent means no network connection. If an
installation completed before cancellation, report its location rather than
silently claiming nothing happened.

## Operator preparation (not performed by the bootstrap)

1. Build and verify a versioned Windows package. Publish that exact ZIP to a public
   HTTPS release URL only after release approval.
2. Upgrade the rendezvous and exposed operator runtimes through the external
   deployment gate; configure `WASM_AGENT_NETWORK_ADMINS=<operator-node-id>,...`.
   Test the managed boundary before admitting customers. This setting is required
   at every service launch; missing configuration makes `/service` unavailable for
   enrollment. Legacy open mode is not safe for a customer environment.
3. Populate `releases/windows-service.json` with `schema: 1`, `available: true`,
   `version`, `package_url`, the exact lowercase `sha256`, `service`, and an
   `operators` array of approved `{node_id, public_key}` pairs. Do not infer trust
   from a display name or automatically trust every discovered master.
4. Only after merge/publication and service verification, the intended user command is:

   ```powershell
   & ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/bootstrap-windows.ps1)))
   ```

   It is **not a working public installer yet**: the checked-in descriptor is
   deliberately unavailable. For isolated testing, `-ManifestPath` accepts a local
   descriptor and a `file:` package URL; production downloads require HTTPS.

## Deployment gate

Implementation/tests do not authorize publishing a package or upgrading the live
registry. Upgrade the operator/registry through its external lifecycle procedure,
configure the admin IDs, and verify `/service` before advertising the one-liner.
Old unrestricted operator nodes must not remain exposed to newly enrolled peers.
Public GitHub release assets require publishing credentials; missing assets must
produce an explicit failure, never SSH fallback or an unverified download.

Verification uses an isolated registry, administrator and at least two guest homes:
registration and naming without a model; signed file effect; unrelated caller and
wrong target refused; role self-escalation refused; admin promotion/demotion;
relay result ownership; revocation and restart; no customer-to-customer access.
Do not probe these attacks against the live service.
