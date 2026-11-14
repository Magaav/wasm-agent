# Grant policy — rate limits, approvals and audit for capability calls

Status 12/11: library built and tested (`rust/wa-grant-policy`, 40 unit tests + doctest) and **wired
into `wa-host`** (`node_policy.rs`): the check runs before every sensitive `wa:kernel` host call and
before every outbound wasi-socket connect, the audit trail is written under a bounded directory, and
`host.policy_status` answers with the decisions.

**A node with no policy file runs in manifest mode** (`Mode::Manifest`): the manifest grant stays the
only gate, exactly the behaviour before this layer existed, and each decision is counted and audited
as `manifest_mode`. Default-deny for a sensitive capability applies only when a policy file is
loaded and names no rule for that component/capability. That is why upgrading a node cannot take
capabilities away from a component that works today, and it is why the policy layer turns on by
*finding a file* - see [Manifest mode](#manifest-mode-a-node-with-no-policy-file) and
[The shipped default](#the-shipped-default-policiesdefaultjson).

What is still open is listed at the end: approvals
have no operator path, the wasip1 (`wa_sock`) runner is not checked, and the per-chat check needs
`wa:channel/messages`. This document is the schema, the decision rules, and the wiring. Context:
[KERNEL.md](KERNEL.md) (capability seams), [COMPONENTS.md](COMPONENTS.md) (manifest grants),
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md) (the long-lived runner).

## Why a second layer

A manifest grant answers *may this component ever open a socket to this host*. It cannot answer *how
often*, *to which chat*, or *who did it at 03:12*. Those are the questions a real channel asks before
it writes to a person's phone. So the two layers stack, they do not replace each other:

| layer | owner | question | change cost |
| --- | --- | --- | --- |
| manifest `capabilities` + registry grant | component author + operator | may it at all? | reinstall/repin |
| grant policy file | operator, per node | how often, to whom, with a record? | edit one JSON file, reload |

The policy can only narrow: a rule naming `evil.example:443` does nothing when `net` never granted
that address. Enforcement order is grant (`component_capability_not_declared:*`) then policy.

## Schema (version 1)

One JSON file per node. Unknown fields **inside a rule**, an unknown `version`, an empty pattern, a zero
rate and a zero cap are **load errors** — a typo (`per_minutes`, `require_aprovall`) must not silently
disable a limit. The *top level* is not strict, on purpose: `features`, `mesh`, `vault`, `models` and
whatever the next section is called are carried for the crate that owns them (see "Sections this crate
does not read").

```json
{
  "version": 1,
  "sensitive_capabilities": [],
  "components": {
    "wa-whatsapp": {
      "note": "an explicit requested send may go to any chat, under the release caps",
      "capabilities": {
        "whatsapp.send": {
          "sensitive": true,
          "require_approval": false,
          "allow": ["*"],
          "deny": ["chat:*@broadcast", "chat:*@newsletter", "chat:*@status"],
          "rate": { "per_minute": 20, "burst": 20 },
          "per_target": { "per_minute": 6, "burst": 6 },
          "daily_cap": 500
        },
        "net.dial": {
          "allow": ["web.whatsapp.com:443", "*.whatsapp.net:443"],
          "rate": { "per_minute": 60, "burst": 120 }
        },
        "credentials.read": {
          "allow": ["WA_WHATSAPP_TOKEN"],
          "rate": { "per_minute": 4 },
          "require_approval": true
        },
        "kv.write": { "allow": ["journal/*", "session/*"], "rate": { "per_minute": 240, "burst": 480 } },
        "http.request": { "allow": ["*.whatsapp.net:443"], "rate": { "per_minute": 20 } }
      }
    }
  }
}
```

The same file ships as a parsed fixture: `rust/wa-grant-policy/examples/whatsapp-policy.json` (a test
fails if it stops parsing or stops meaning what the table below says). Its kv prefixes (`journal/*`,
`session/*`) are illustrative; **`policies/default.json`** is the file this release installs and it
lists the prefixes `wa-whatsapp` actually writes - copy that one for a new node
([The shipped default](#the-shipped-default-policiesdefaultjson)).

The WhatsApp rule is the owner's decision of 06/11: **an explicit requested send may go to any chat**,
like the old connector could, under a global 20/min, a per-chat 6/min and a daily 500 cap, with every
decision audited. What is denied outright is the class of address nobody means to message: a status /
list broadcast (`chat:*@broadcast`), a channel (`chat:*@newsletter`) and `chat:*@status`.

The target is always the exact JID the producer names (`chat:5511999999999@s.whatsapp.net`,
`chat:72103978127547@lid`, `chat:120363000000000001@g.us`), because the one caller is
`host.whatsapp_send`, which knows the chat before dispatch (`docs/HOST.md`). That is why the
`chat:self` / `chat:alerts` aliases of the first default are gone: they named nothing a caller could
check. Narrowing is one edit — replace `"*"` with the chats that are allowed:

```json
"allow": ["chat:120363000000000001@g.us", "chat:5511999999999@s.whatsapp.net"]
```

Transcript posting and the own-chat alert log are not governed by this rule: they are automatic
behaviour with their own gates (`post_transcripts` + `post_allow` + holds inside the component,
`alerts` for the log) and they write opaque frames, which the global cap still charges — see
[The honest gap](#the-honest-gap-per-chat-limits-and-an-opaque-frame).

| field | type | default | meaning |
| --- | --- | --- | --- |
| `version` | `1` | — | schema; anything else is refused |
| `sensitive_capabilities` | `string[]` | `[]` | extra capabilities this node treats as sensitive |
| `components.<name>.note` | `string` | — | operator text, never read by the engine |
| `components.<name>.capabilities.<cap>` | rule | — | one rule per capability string |
| `effect` | `"allow"` / `"deny"` | `"allow"` | `deny` refuses every call before targets/rates |
| `allow` | pattern[] | `[]` | targets this capability may reach; **empty means any** |
| `deny` | pattern[] | `[]` | targets refused; evaluated **before** `allow` |
| `sensitive` | `bool` | see below | forces the rule's sensitivity, overriding both lists |
| `require_approval` | `bool` | `false` | `NeedsApproval` until a person approves one use |
| `rate` | `{per_minute, burst?}` | — | capability-wide token bucket (burst defaults to one minute) |
| `per_target` | `{per_minute, burst?}` | — | one bucket per distinct target |
| `target_rates` | `{pattern, per_minute, burst?, exempt_from_global}` | `[]` | first match **replaces** `per_target` for that target |
| `daily_cap` | `uint` | — | calls per capability per UTC day |

Patterns (`pattern.rs`): no `*` → exact (case sensitive); a single trailing `*` → prefix
(`chat:*`); otherwise glob where `*` matches any run including empty (`*@g.us`, `*.whatsapp.net:443`).
There is no escape for a literal `*`; targets are ids and addresses, so that case does not exist.

Sensitivity — a sensitive capability is audited on every call and **denied with `no_policy` when the
component has no rule for it**. Defaults: `credentials.read`, `net.dial`, `http.request`,
`whatsapp.send`, `exec.run`, `kv.write`. Everything else (log, lifecycle, kv reads) needs no rule.

## Sections this crate does not read

`policy.json` carries more than capability rules: `features` (`docs/FEATURES.md`), `mesh`
(`docs/MESH.md`), `vault`, `models` (`docs/MODEL-GATEWAY.md`), and one day something else. Only this
crate's own sections are interpreted here, and the strictness rule follows the blast radius:

| what is in the file | what happens |
| --- | --- |
| `version`, `sensitive_capabilities`, `components` | validated field by field; a typo is a load error |
| a section this crate knows by name (`features`) | carried as JSON, read by the crate that owns it |
| any other top-level section (`mesh`, `vault`, `models`, a future one) | **carried** (`PolicySet::sections`), read by nobody here, and it changes no rule |
| a carried section whose owner is registered in this process | validated by that owner (`wa-mesh-core` owns `mesh`); an unusable one is recorded in `PolicySet::section_errors`, logged, and reported in `host.policy_status` under `policy.sections.errors` — the rules beside it stay in force |

**Why.** On 08/11, 03:51–04:10, a node on openclaw had a `mesh` section hand-added to its `policy.json`,
and every component rule answered `deny(no_policy)` — `wa-whatsapp`'s `net.dial` refused with its rule
right there in the file. Before this, *any* unknown top-level member was a load error, so the whole file
did not load; a file that does not load is `Mode::Policy` with an **empty** policy, i.e. default deny
everywhere. A section that a *different* crate reads must never be able to refuse a rule this crate
enforces.

Two properties, both tested (`cargo test -p wa-grant-policy`, `-p wa-governance`, `-p wa-mesh-core`):

* a valid `mesh` section (or any unknown future section) leaves every rule readable and enforced;
* an **invalid** section fails loudly — `host.policy_status` carries the error by name and the node logs
  one line — and never silently: the rules are neither dropped nor guessed at. `mesh.enabled: "yes"` is
  refused by the mesh's own validator; `"mesh": "on"` is `not_an_object`.

A top-level typo (`"componets": {...}`) is therefore carried rather than refused, and that is the one
cost of the design: it shows up in `policy.sections.carried` in `host.policy_status`, and the rules it
should have carried are absent — so it fails closed *and* visibly, which is the direction a half-written
file has to fail in.

## Decisions

`check(component, capability, target, now_ms)` and `enforce(... , sink)` return one of:

| answer | audit word | meaning for the host |
| --- | --- | --- |
| `Allow` | `allow` | perform the call; the budget was charged in this call |
| `Allow` (no policy file) | `allow` + reason `manifest_mode` | perform the call: the manifest grant is the only gate; nothing was charged |
| `Deny(reason)` | `deny` | refuse: `KError::Refused(reason)`, never perform the call |
| `RateLimited { retry_after_ms, reason }` | `rate_limited` | refuse for now; the exact wait is known |
| `NeedsApproval(reason)` | `needs_approval` | ask the operator; then `approve(...)` and call again |

In manifest mode the decision is `Allow` (the crate's `DecisionCode` stays `allow`, and the record's
`reason` is `manifest_mode`), because a manifest-mode call has no budget to charge and no rule to
break: the manifest grant already answered the only question being asked. The operator view counters
it apart from `allow` (`decisions.manifest_mode`), so "the policy layer is not on" is visible rather
than inferred from a zero.

Reasons (`snake_case`, stable): `no_policy`, `policy_denied`, `target_denied`, `target_not_allowed`,
`approval_required`, `capability_rate_limited`, `target_rate_limited`, `daily_cap_reached`,
`audit_unavailable`.

Evaluation order, because it decides which reason a caller sees and because **a refused call never
charges budget**: rule lookup (default deny for sensitive) → `effect: deny` → `deny` patterns →
`allow` patterns (a rule with a non-empty `allow` and no target is refused) → approval → daily cap →
capability bucket → per-target bucket → allow, then charge. Both buckets are charged in the same
call, so a call that passes the global cap and fails the per-chat cap spends nothing.

Buckets are exact integers (`tokens·ms` units, one token = 60 000 units), so a rate of 7/min still
gives a deterministic `retry_after_ms` and a snapshot round-trip cannot change a limit. The clock is
injected (`now_ms`, epoch milliseconds); a clock that moves backwards refills nothing. `retry_after`
is the exact wait, rounded up to whole ms, and the daily window is the UTC day of `now_ms`.

State — buckets, daily counters, pending approvals — is in memory and serialisable:
`snapshot_json()` / `restore_json()`. Keys are `sha256` digests of the target, so a snapshot (and a
core dump of it) contains no chat id, no secret name, no kv key. Per-target buckets are bounded
(`DEFAULT_MAX_TARGET_BUCKETS` = 4096, least recently used evicted): a hostile target space cannot
grow memory without bound, and eviction is fail-open for that one target only — the capability-wide
bucket still bounds the total. The global buckets are never evicted.

## Audit

Every sensitive call is recorded (allow included) and so is every refusal of any capability.
`AuditRecord` — one JSON object per line: `{schema, ts_ms, component, capability, target, decision,
reason, retry_after_ms?}`. The target is `sha256:<32 hex>` by default (`TargetMode::Digest`),
`<redacted>`, or — only by explicit opt-in — the target verbatim; a call without a target records
`-`. Message text cannot appear: payloads are never passed to the audit API. Component, capability
and target are capped at 160 characters so one record cannot grow without bound.

Two sinks ship, both behind `trait AuditSink { fn write(&mut self, &AuditRecord) -> Result<(), AuditError> }`:

* `MemoryAudit` — bounded ring (default 10 000), counts what it dropped;
* `FileAudit::open(path, max_bytes)` — JSONL, flushed per record, rotated by size to `<path>.1` (one
  backup generation, rotation counter exposed). Flushed, not `fsync`ed: it survives a process crash,
  not a power cut.

A write failure is returned. The engine keeps it in `audit_errors()` for the host to log, and by
default **refuses a sensitive call it could not audit** (`deny(audit_unavailable)`, budget
uncharged). `set_fail_closed_on_audit(false)` is the documented opt-out for a node whose audit disk
is best-effort.

**Bounded store, as built.** The host places the file sink in a bounded directory
(`<state>/audit/`, 32 MiB quota, `store.rs`), rotates it at 8 MiB with one backup generation, reports
the directory's usage and percentage in `host.policy_status` and `host.telemetry`, and puts the 80 %
crossing on the node's log. The trail is therefore bounded by construction (at most ~16 MiB of
records) and its size is visible instead of being discovered by `df`.

**Still open:** a SQLite table (`audit(ts_ms, component, capability, target_digest, decision,
reason)`, indexed by `ts_ms`, pruned to a row budget or a day budget) served by the kernel component
that owns policy state. Reading it must page (`WHERE ts_ms < ? ORDER BY ts_ms DESC LIMIT ?`), never
scan, and the pruning must count what it pruned — dropping evidence silently is worse than a bigger
file. The `AuditSink` trait is the seam and needs no change.

## How the host wires it

The host side is `rust/wa-governance/src/node_policy.rs` (one engine, one pair of sinks, the counters); the
call sites are `service_components.rs` (the `wa:kernel@0.1` imports), `service_components_v2.rs` (the
same imports on `wa:kernel@0.2` / WASI 0.3), `components.rs` (the outbound wasi-socket path of request
components) and `services.rs` (the supervisor). The numbered list below is
the design, kept because it is the reasoning; the paragraphs after it are what the tree actually does
where it differs.

1. **Loaded once per node, lazily on the first check or the first `host.policy_status`.**
   `WA_GRANT_POLICY`, default `<home>/.wasm-agent/policy.json`. **A file that is absent is
   [manifest mode](#manifest-mode-a-node-with-no-policy-file)**: the manifest grant is the only gate,
   decisions are counted and audited as `manifest_mode`, and one warning is written on the node's log
   at load. A file that is present and parses is policy mode: a sensitive capability with no rule is
   refused with `no_policy`. A file that does not parse (or cannot be read) is also policy mode, with
   an empty policy plus one line on the node's log and the error in `host.policy_status` — the node
   starts, the capabilities the policy governs are refused, and nothing is guessed at: a half-written
   `policy.json` is not evidence that the operator wants no limits. Budgets are restored from
   `WA_GRANT_POLICY_STATE` (default `<home>/.wasm-agent/grant-policy.state.json`, missing = fresh)
   and written back every five minutes by the telemetry ticker.
2. **One engine, one sink pair.** `Mutex<Engine>` plus a tee sink: `FileAudit` at
   `<home>/.wasm-agent/audit/grant-policy.jsonl` (8 MiB rotation, one backup generation) and a
   `MemoryAudit` ring of the last 512 records. The audit directory is a `BoundedDir` (32 MiB,
   `store.rs`), so its usage is reported and its 80 % crossing is on the node's log. A file sink that
   cannot be opened makes a sensitive call `deny(audit_unavailable)`: fail-closed, as the crate
   defaults, visible in the log and in `host.policy_status`.
3. **Clock.** `now_ms` is `SystemTime::now()` read once per call; nothing in the library reads a
   clock, and no lock is held across anything that could block on a guest.
4. **One check per sensitive host call, after the manifest grant** (`service_components.rs` for the
   `wa:kernel@0.1` contract, `service_components_v2.rs` for `@0.2`):

   | WIT call | capability | target passed to the policy |
   | --- | --- | --- |
   | `websocket.connect(url, origin)` (0.1 and 0.2) | `net.dial` | `url` authority |
   | `websocket.send(data)` (0.1) / `socket.send(data)` (0.2) | `net.send`, then the interim `whatsapp.send` | the socket's authority |
   | `http.start(request)` (0.1) / `http.send(request)` (0.2) | `http.request` | `url` authority |
   | `kv.set` / `kv.delete` / `kv.delete_prefix` (both) | `kv.write` | the key (or its prefix) |
   | `kv.get` / `kv.scan` (both) | `kv.read` | the key (or its prefix) |
   | `credentials.get(name)` (both) | `credentials.read` | `name` |
   | `speech.start(...)` (0.1) / `speech.recognize(...)` (0.2) | `stt.start` | none |
   | `log.write`, `lifecycle.*` (both) | never checked | a log line cannot exceed anything a person sees |
   | `host.whatsapp_send` (a **host** capability, not a guest import: `rust/wa-capabilities/src/whatsapp_send.rs`) | `whatsapp.send` | `chat:<exact jid>` |

   Both runners call the same three functions (`service_components::{gate, target_of,
   authority_target}`), so a policy file cannot mean two different things depending on which
   contract a component speaks. Only the mapping of an answer onto the guest's error is per runner,
   because `bindgen!` generates a distinct `wa:kernel/types.error` per bindings module: the table
   itself is `service_components::gate_verdict`, and each runner names its own error type for its
   three cases (`gate_decision` in each file).

   An address target (`net.dial`, `http.request`) is lowercased before the check
   (`service_components::authority_target`), because host names are case-insensitive and the manifest
   grant already compares them that way: write address patterns in lowercase. Without it a client's
   `WSS://WEB.WHATSAPP.COM/...` would pass the manifest and fail a rule the same operator wrote.

   Result mapping, in one function (`service_components::gate_verdict`): `Allow` → proceed;
   `Deny(no_policy | policy_denied | target_denied | target_not_allowed | audit_unavailable)` →
   `KError::Refused(reason)`; `RateLimited` with `retry_after_ms < 1000` → `KError::Again` (the guest
   already retries that), otherwise `Refused(reason)`; `NeedsApproval` → `Refused("approval_required")`.
   A 0.2 stream item is not a call, but one delivered `socket.messages()` frame is recorded as
   `websocket.recv` so both contracts answer the same query.
5. **The wasi-socket path.** Request components (MCP servers, the `wasi:cli` world) reach the network
   through wasi sockets, not `wa:kernel`. There the manifest grant is already a per-address check, so
   the policy is applied only for a rule the operator actually wrote for that component
   (`node_policy::check_if_ruled`): `TcpConnect` and `UdpSend` uses are checked against `net.dial`,
   binds are not. A policy file that names no rule for a component therefore cannot break a component
   the manifest granted, while a rule that names it is enforced per address. One check per address
   means a name that resolves to several addresses is charged several tokens — a known over-count,
   bounded by the rule's own rate.
6. **Two `whatsapp.send` paths, and why they differ.** An *opaque* frame (`websocket.send`) carries
   ciphertext, so the authority is the only target the host sees: `node_policy::check_opaque_send`
   charges `whatsapp.send` per outbound frame **only for a rule that names no chats** (`allow` and
   `deny` both empty) — which is exactly how an operator writes "global cap only". A rule that lists
   chats is not guessed at from an opaque frame: the frame is not refused by it. The *explicit* send
   (`host.whatsapp_send`, `rust/wa-capabilities/src/whatsapp_send.rs`) is the path that names the chat, because
   the producer knows it before anything is dispatched, and it calls
   `node_policy::check_whatsapp_send(component, Some("chat:<jid>"))` — so for an explicit send the
   per-chat and daily limits are real, and the frame the component later writes is *also* still charged
   by the opaque-frame rule. One send, two gates, no path that skips both.
7. **Audit errors** are drained every minute into the node log with the sink name only (never a
   target) and counted in `host.policy_status`, so a silent stop of the audit trail is visible.
8. **`host.policy_status()`** (read-only) answers: the policy path and load error, component and rule
   counts, budget counts (capability buckets, per-target buckets, daily counters, pending approvals),
   the decision counters (`checks`, `allow`, `deny`, `rate_limited`, `needs_approval`,
   `audit_errors`), the audit sink's written/rotated/dropped numbers with the directory's usage, and
   the last 32 refusals as `{ts_ms, component, capability, reason}` — **never a target**, so the view
   cannot become a second place a chat id leaks into.

### WASI 0.3 interface decisions (`docs/WASI-INTERFACES.md`)

The 0.2 runner does not link WASI wholesale any more: every `wasi:` import of a component is graded by
[WASI-INTERFACES.md](WASI-INTERFACES.md) and linked only if the tier allows it. That adds a second
family of decision points, and they are audited exactly like the `wa:kernel` ones:

| decision | when | capability | target |
| --- | --- | --- | --- |
| filesystem preopen | once per preopen per run | `wasi.filesystem` | the guest path (`/data`) |
| environment name | once per granted variable per run | `wasi.env` | the variable name |
| stdin | once per run, when the manifest declares it | `wasi.stdin` | none |
| socket address | once per granted address per run | `wasi.sockets` | the address (`127.0.0.1:8080`) |
| keyvalue | once per run, when `storage` is declared | `wasi.keyvalue` | none |
| config | once per run, when `config` is declared | `wasi.config` | none |
| any `wasi:` import the scope does not cover | once per refused start | `wasi.import` | the interface name |
| outbound connect / datagram | **per call** (`wasmtime`'s socket address check) | `net.dial` | the address |
| bind / listen | **per call** | `net.bind` | the local address |
| keyvalue `get`/`exists`/`list-keys` | per call | `kv.read` | the key (or its prefix) |
| keyvalue `set`/`delete` | per call | `kv.write` | the key |
| config `get`/`get-all` | per call | `config.read` | the key |

Those eight names (`wasi.filesystem`, `wasi.env`, `wasi.stdin`, `wasi.sockets`, `wasi.keyvalue`,
`wasi.config`, `wasi.import`, and `net.bind`) are **sensitive by default** (`wa_grant_policy::
DEFAULT_SENSITIVE`): on a node with a `policy.json`, a component that was granted one of them still
needs a rule, or the interface is refused with `no_policy`. On a node with no policy file (manifest
mode) nothing changes: the manifest grant is the only gate and each decision is audited with
`manifest_mode`. `config.read` is deliberately **not** sensitive: it is the component's own
non-secret configuration, readable exactly as `wa:kernel/service.run(config)` already gives it.

Which is why a node upgrading to this binary with a `policy.json` should add the rules it means:

```json
"wa-whatsapp": {"capabilities": {
  "wasi.env": {"allow": ["WA_MODE"]},
  "wasi.keyvalue": {},
  "wasi.config": {},
  "wasi.stdin": {}
}}
```

`{}` means "any target, no rate" — the documented way to keep a capability. A component that reaches
no WASI interface needs none of these lines.

Two refusals are decided **before** the policy engine is asked: a preopen of `/` or of the node's own
home/state/component directory, and a hostname written where a socket address is required. They go
through `node_policy::record_deny`, which writes one audit record with the caller's own reason word
(`filesystem_root`, `node_home`, `state_root`, `component_dir`, `absolute`/`relative_segments`,
`address_not_an_ip`, `manifest_not_declared`) and counts the decision as a denial. Without that path
the trail would show only the refusals a *rule* produced, and a component trying to widen its own
declaration would leave no trace.

### Manifest mode: a node with no policy file

Before the policy layer existed, a service component's `kv.write`, `net.dial`, `credentials.read`
and `http.request` were governed by the manifest grant alone. The crate's own default - an **absent**
file means an empty policy, which means default-deny for the six sensitive capabilities - would have
turned that upgrade into an outage: the first binary that speaks the policy layer would have refused
the running wa-whatsapp the moment it wrote a Signal session, dialled WhatsApp or downloaded media,
with nothing but `no_policy` in the log and no file to point at.

So the wiring answers the question the crate does not: **the policy file's presence is what turns
the policy layer on** (`node_policy::Mode`).

| on disk | mode | an unruled sensitive capability | counted as | audited as |
| --- | --- | --- | --- | --- |
| no `policy.json` | `manifest` | **allowed**, by the manifest grant | `decisions.manifest_mode` | reason `manifest_mode` (the six capabilities a policy file would audit) |
| `policy.json` parses | `policy` | refused `no_policy` | `decisions.deny` | the refusal |
| `policy.json` broken/unreadable | `policy` | refused `no_policy` (empty policy, error in `policy_status`) | `decisions.deny` | the refusal |

Only *no file at all* selects manifest mode. A file that is there and cannot be understood selects
policy mode with an empty policy, because a half-written policy is not evidence that the operator
wants no limits - silently falling back to "manifest alone" would remove every limit the operator
was in the middle of writing.

Manifest mode is not a switch that turns the policy off: it is what a node that never wrote a policy
file *is*. The moment the file exists, every sensitive capability it does not name is refused. An
operator keeps today's behaviour for one capability by writing a rule with no limits (`"kv.write": {}`
means "any target, no rate"), and keeps it for every component by writing the rules the node's
components need. There is still **no node-wide switch that turns the policy off**, because a switch
that silently disables a limit is the failure this layer exists to prevent.

Manifest mode does not fail closed on an audit write error either: the file sink failing is counted
(`decisions.audit_errors`) and logged, and the call proceeds, because the manifest grant is the only
gate. Policy mode keeps the crate default, where a sensitive call that cannot be audited is refused
with `deny(audit_unavailable)`.

### The shipped default (`policies/default.json`)

The release ships a default policy so that the first node to receive the policy layer gets rules it
can read and edit instead of a bare default-deny. It is **the WhatsApp stage 1** of the table above
plus the fixtures of this tree:

| component | rules |
| --- | --- |
| `wa-whatsapp` | `whatsapp.send` (any chat, ≤20/min in total, ≤6/min per chat, daily cap 500; `@broadcast`, `@newsletter` and `@status` denied); `net.dial` + `http.request` to the three host families its manifest grants; `kv.write` on the key prefixes its store writes (`dev`, `id/`, `ses/`, `pk/`, `spk/`, `sk/`, `sync/`, `ver/`, `mac/`, `lid/`, `tc/`, `tx/`, `fence/`); `credentials.read` for `WA_WHATSAPP_TOKEN` |
| `mcp-whatsapp` | `net.dial` + `http.request` on loopback (its manifest grants nothing else), `credentials.read` for `WA_MCP_WHATSAPP_TOKEN` |
| `svc-echo`, `svc-echo-v1` | `net.dial` + `http.request` on loopback and their own `kv` namespace (fixtures; the wasip1 module of the same name is not policy-checked yet) |
| `mcp-echo` | named, no rule needed: it declares no net and no secret |
| `example-new-component` | a template entry to copy for a new component, with the rules written out |

Two properties of that file are load-bearing. The patterns **mirror the manifests**: a rule can only
narrow what a manifest already grants, so `net.dial`/`http.request` list exactly the addresses in
`rust/components/wa-whatsapp/manifest.json` and a widening there needs no policy edit. And `kv.write`
lists the prefixes the store actually writes (`src/store.rs` documents them, `src/lib.rs` adds `tx/`,
`src/guest.rs` adds the 0.2 message fence `fence/`),
not a tidier invented namespace: a default that refused `ses/...` would break the running component on
the first message. `cargo test -p wa-governance node_policy::` drives those exact calls, and its
`the_shipped_default_policy_keeps_the_components_this_tree_installs_working` test is the one that
fails if the file and the components drift apart.

`scripts/deploy.sh` installs it as `<state>/policy.json` (`scripts/lib/install-default-policy.sh`,
tested by `scripts/test-install-default-policy.sh`), and brings a release's **new rules** into a file that
already exists. The unit of "a deploy never overwrites the operator's choices" is the **rule**, not the
file:

* a node with **no** policy file gets the default, byte for byte (**manifest mode → policy mode**: this is
  the one deploy action that changes what the running node enforces, so the deploy says so), and the bytes
  it came from are recorded beside it as the **base** (`<state>/policy.base.json`, with its sha256 and
  where it came from in `<state>/policy.base.sha256`);
* an existing file is **merged per rule** (`scripts/lib/policy-merge.mjs`): base = the default this node's
  file was installed from, ours = the node's file, theirs = the default this release ships. A rule the
  node never touched takes the release's version (so a rule the release **added** arrives); a rule the
  node changed and the release did not keeps the node's version; a rule **both** changed is a conflict -
  the node's version wins, the deploy continues, the conflict is printed, and `installed.txt` records it
  as `policy_warnings=`. The file that was replaced is kept at `<state>/policy.prev.json`;
* a node installed before that record existed has no base; then the base is the **oldest** default in
  `policies/default.json`'s git history whose bytes are the node's own file (the release records in
  `policies/shipped/*.json` are tried after it), and when nothing matches the merge is
  **additions-only**: new rules and new components are added, an **existing** rule is never modified —
  adding entries to an `allow` list the operator narrowed would widen the limit the policy exists to
  enforce - and the entries the release has and the node lacks are printed (and recorded) as the
  one-line edit to make;
* a file that is **not JSON**, a directory, a dangling symlink: nothing is written. A file that parses but
  names a field the node's schema rejects keeps the operator's rule exactly as written (this merge is not
  a schema validator); the node still refuses that file until it is fixed, and the deploy does not hide
  it;
* when the merge cannot run at all (`node` is not on PATH, or the tool is not beside the installer — the
  installed copy of `deploy.sh` carries no `scripts/lib/`), a file whose bytes are still a default this
  tree shipped is **refreshed** byte for byte, because nobody's choice is being overwritten; anything else
  is kept and the deploy says why;
* installing it **changes what the node enforces** (manifest mode → policy mode), so the deploy names
  every installed component the file does not mention and says that its sensitive capabilities will be
  refused with `no_policy` until a rule is added. The deploy does not refuse on that - a node with no
  policy file still works - but it never lets it be a surprise.

**A node that already has its own `policy.json`** (the common case: it was installed by an earlier
release and then edited, or the operator wrote it) gets the new rules a release ships, and keeps its own.
The `whatsapp.send` rule of `wa-whatsapp` this section is about, as the release ships it:

```json
"whatsapp.send": {
  "sensitive": true,
  "allow": ["*"],
  "deny": ["chat:*@broadcast", "chat:*@newsletter", "chat:*@status"],
  "rate": { "per_minute": 20, "burst": 20 },
  "per_target": { "per_minute": 6, "burst": 6 },
  "daily_cap": 500
}
```

An operator who wants only some chats keeps a narrower `allow` list
(`["chat:120363000000000001@g.us"]`) — that is the knob, and a send to any other chat answers
`whatsapp_send_policy_denied` with `reason: "target_not_allowed"`. A node whose file was never edited ends
up on the release's own bytes (its bytes are still a default this tree shipped) and the deploy says so; a
node that edited this rule **and** had it changed by the release keeps its own version and reads the
conflict on the deploy log and in `installed.txt`.

The reason the unit is the rule, and not the file, is measured. openclaw, 07/11: `policy.json` had been
installed from an older shipped default, a later release added `ix/*` to `wa-whatsapp`'s `kv.write` allow
list, and the deploy kept the node's (unedited) file whole — so the new rule never arrived and every
index write was refused until it was added by hand. Keeping the whole file when only one rule was the
operator's is what was wrong.

After the file exists, adding a component is: install it, then add a rule for each capability its
manifest declares (`example-new-component` in the shipped file is the shape). Until then its
`kv.write`, `net.dial`, `http.request`, `credentials.read`, `whatsapp.send` and `exec.run` answer
`refused(no_policy)`.

### The honest gap: per-chat limits and an opaque frame

The kernel sees `websocket.send(data)` — ciphertext. It cannot read the chat id inside, so a
per-chat rule (`per_target`, `target_rates`) cannot be enforced by the host today: at most the
authority (`web.whatsapp.com:443`) is visible, and that is not the chat. Two ways to close it, in
order of preference:

1. **`wa:channel/messages`** ([KERNEL.md](KERNEL.md) already lists it): the host builds the envelope
   from an explicit `chat` argument, so the target is in the clear at the boundary and the limit is
   real. A compromised guest can lie about a chat id it can see anyway, but it cannot send to a chat
   it did not declare, which is the property that matters.
2. **The same crate compiled into the guest** (`wa-grant-policy` has no wasmtime, no OS, serde only),
   with the policy text from non-secret `config`. That catches bugs and runaway loops but not a
   hostile guest — it is advisory, and must be described as advisory.

Until one of them lands, what the host *can* enforce is real and worth having: the global message
cap needs only the `send` call, not the chat.

## Risks, and what a measurement cannot settle

* **The numbers are a guess.** 20/min and 6/min come from "no accidental spam", not from a
  measurement of WhatsApp's tolerance. The knob is there so the number can be lowered without a
  code change; a measurement of ban rate vs rate would settle it, and we have none.
* **Digest collisions.** 128-bit truncation; with 4096 live buckets and a bounded history the
  probability is not a practical concern, but a collision merges two chats' budgets. Full 256-bit
  hex is a one-line change if that ever matters.
* **Clock changes.** A wall clock that jumps forward (NTP, suspend/resume) refills every bucket.
  Monotonic time would avoid it but cannot be compared across a restore; the snapshot keeps wall
  time on purpose, and a jump is bounded by the daily cap, not by the buckets.
* **Fail-closed audit** can turn a full disk into a stopped channel. That is the intended trade and
  is one setter away from the other policy; the operator must know which one the node runs.

## What is not wired yet

* **Approvals have no operator path.** `Engine::approve` / `revoke_approvals` exist and the engine
  honours them; there is no `services` tool action, CLI verb or panel that grants one, so a rule with
  `require_approval` currently refuses (`approval_required`) until one is added. One use per
  approval, ttl default 15 min; the call is `NodePolicy::approve` from a master-only path.
* **The wasip1 runner** (`services.rs` `wa_sock.connect`, used by core modules such as
  `svc-echo-wasip1`) is not policy-checked: its `connect` sits inside the linker closure another
  stream owns. It needs the same shape as the wasi-socket check (grant, then `net.dial` per
  `host:port`).  Both `wa:kernel` contracts are checked (`service_components.rs`, and
  `service_components_v2.rs` for `@0.2`).
* **Per-chat limits on *automatic* sends** still need `wa:channel/messages` (`wit/kernel` 0.2, another
  job): transcript posting and the alert log write opaque frames, so only the global message cap is
  real for them. For an **explicit** send they are real today, because `host.whatsapp_send` names the
  chat (`node_policy::check_whatsapp_send`).
* **The policy file is a single node file.** The profile stack in [KERNEL.md](KERNEL.md) (base → node
  → user → patch) still says a policy should be a layer, not a file an LCM edits in place; nothing
  here decides that.

## Open questions

* Who owns the policy file when nodes are managed centrally — the profile stack in
  [KERNEL.md](KERNEL.md) says base → node → user → patch; the policy should be a profile layer, not a
  file the LCM edits in place.
* Do approvals belong to the node or to the person? An approval granted on a phone at 03:00 is a
  different thing from one granted by an operator on the node.
* `net.send` as a capability name is new; if `wa:channel/messages` lands, `whatsapp.send` can name
  the chat directly and `net.send` shrinks to "any outbound frame", which may not deserve a limit of
  its own.

## WASI 0.3 / wasmtime 50 note

Everything here is synchronous and cheap except the audit write (one `write` + `flush`). The 0.1
call sites are the synchronous `wa:kernel` host functions, so the write happens in the guest's own
call. The 0.2 runner (`service_components_v2.rs`) already calls the same `check` from inside an
`async fn`; it does not await while the engine guard is held either (the guard is taken and dropped
inside `node_policy::check`), so a policy check never sits on a guest's future. What is still open
is the audit *write* on the async path: the 0.1 restart path is unchanged and the write is the same
one-write-one-flush it always was. If that shows up in a measured `host_call_duration_micros` for
`websocket.send`/`http.send` on the 0.2 runner, the fix is the one described below: with WASI 0.3
native async the host hands records to a dedicated writer (bounded channel, drop-oldest counted,
`AuditSink` gaining an async or fire-and-forget form) while `Engine` stays a plain `Mutex<Engine>` —
no `await` is ever held with the guard, and `check`/`enforce` keep their signatures. Nothing in the
library needs to change shape for that: it has no clock, no I/O of its own, and no wasmtime types.
