# Grant policy — rate limits, approvals and audit for capability calls

Status 12/11: library built and tested (`rust/wa-grant-policy`, 40 unit tests + doctest) and **wired
into `wa-host`** (`node_policy.rs`): the check runs before every sensitive `wa:kernel` host call and
before every outbound wasi-socket connect, the audit trail is written under a bounded directory, and
`host.policy_status` answers with the decisions. What is still open is listed at the end: approvals
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

One JSON file per node. Unknown fields, an unknown `version`, an empty pattern, a zero rate and a
zero cap are **load errors** — a typo (`per_minutes`, `require_aprovall`) must not silently disable a
limit.

```json
{
  "version": 1,
  "sensitive_capabilities": [],
  "components": {
    "wa-whatsapp": {
      "note": "stage 1: our own chat plus the alerts chat",
      "capabilities": {
        "whatsapp.send": {
          "sensitive": true,
          "require_approval": false,
          "allow": ["chat:self", "chat:alerts"],
          "deny": ["*@broadcast", "*@newsletter"],
          "rate": { "per_minute": 20, "burst": 20 },
          "per_target": { "per_minute": 6, "burst": 6 },
          "target_rates": [
            { "pattern": "chat:alerts", "per_minute": 1, "burst": 1, "exempt_from_global": true }
          ],
          "daily_cap": 200
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
fails if it stops parsing or stops meaning what the table below says).

This is the WhatsApp component's stage 1: **send only to our own chat** (`chat:self`) plus the
alerts chat, ≤ 20 messages/min in total, ≤ 6/min per chat, alerts exempt from the global cap but
≤ 1/min. Stage 2 — allowlisted chats — only widens `whatsapp.send.allow`:

```json
"allow": ["chat:self", "chat:alerts", "120363000000000001@g.us", "5511999999999@s.whatsapp.net"]
```

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

## Decisions

`check(component, capability, target, now_ms)` and `enforce(... , sink)` return one of:

| answer | audit word | meaning for the host |
| --- | --- | --- |
| `Allow` | `allow` | perform the call; the budget was charged in this call |
| `Deny(reason)` | `deny` | refuse: `KError::Refused(reason)`, never perform the call |
| `RateLimited { retry_after_ms, reason }` | `rate_limited` | refuse for now; the exact wait is known |
| `NeedsApproval(reason)` | `needs_approval` | ask the operator; then `approve(...)` and call again |

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

The host side is `rust/wa-host/src/node_policy.rs` (one engine, one pair of sinks, the counters); the
call sites are `service_components.rs` (the `wa:kernel` imports), `components.rs` (the outbound
wasi-socket path of request components) and `services.rs` (the supervisor). The numbered list below is
the design, kept because it is the reasoning; the paragraphs after it are what the tree actually does
where it differs.

1. **Loaded once per node, lazily on the first check or the first `host.policy_status`.**
   `WA_GRANT_POLICY`, default `<home>/.wasm-agent/policy.json`. An **absent** file is an empty
   policy: ordinary capabilities are allowed and the six sensitive ones are refused with `no_policy`
   exactly as the crate defines. A file that does not parse is the same empty policy plus one line on
   the node's log and the error in `host.policy_status` — the node starts, the capabilities the
   policy governs are refused, and nothing is guessed at. Budgets are restored from
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
4. **One check per sensitive host call, after the manifest grant** (`service_components.rs`):

   | WIT call | capability | target passed to the policy |
   | --- | --- | --- |
   | `websocket.connect(url, origin)` | `net.dial` | `url` authority |
   | `websocket.send(data)` | `net.send`, then the interim `whatsapp.send` | the socket's authority |
   | `http.start(request)` | `http.request` | `url` authority |
   | `kv.set` / `kv.delete` / `kv.delete_prefix` | `kv.write` | the key (or its prefix) |
   | `kv.get` / `kv.scan` | `kv.read` | the key (or its prefix) |
   | `credentials.get(name)` | `credentials.read` | `name` |
   | `speech.start(...)` | `stt.start` | none |
   | `log.write`, `lifecycle.*` | never checked | a log line cannot exceed anything a person sees |

   Result mapping, in one function (`service_components::gate_decision`): `Allow` → proceed;
   `Deny(no_policy | policy_denied | target_denied | target_not_allowed | audit_unavailable)` →
   `KError::Refused(reason)`; `RateLimited` with `retry_after_ms < 1000` → `KError::Again` (the guest
   already retries that), otherwise `Refused(reason)`; `NeedsApproval` → `Refused("approval_required")`.
5. **The wasi-socket path.** Request components (MCP servers, the `wasi:cli` world) reach the network
   through wasi sockets, not `wa:kernel`. There the manifest grant is already a per-address check, so
   the policy is applied only for a rule the operator actually wrote for that component
   (`node_policy::check_if_ruled`): `TcpConnect` and `UdpSend` uses are checked against `net.dial`,
   binds are not. A policy file that names no rule for a component therefore cannot break a component
   the manifest granted, while a rule that names it is enforced per address. One check per address
   means a name that resolves to several addresses is charged several tokens — a known over-count,
   bounded by the rule's own rate.
6. **The interim `whatsapp.send` cap.** `websocket.send` carries ciphertext, so the authority is the
   only target the host sees. `node_policy::check_opaque_send` charges `whatsapp.send` per outbound
   frame **only for a rule that names no chats** (`allow` and `deny` both empty) — which is exactly
   how an operator writes "global cap only". A rule that lists chats is not guessed at from an opaque
   frame: the frame is not refused by it, and the per-chat limits become real when
   `wa:channel/messages` lands and the guest declares the chat through
   `node_policy::check_whatsapp_send(component, chat)` (the exported hook, no caller yet).
7. **Audit errors** are drained every minute into the node log with the sink name only (never a
   target) and counted in `host.policy_status`, so a silent stop of the audit trail is visible.
8. **`host.policy_status()`** (read-only) answers: the policy path and load error, component and rule
   counts, budget counts (capability buckets, per-target buckets, daily counters, pending approvals),
   the decision counters (`checks`, `allow`, `deny`, `rate_limited`, `needs_approval`,
   `audit_errors`), the audit sink's written/rotated/dropped numbers with the directory's usage, and
   the last 32 refusals as `{ts_ms, component, capability, reason}` — **never a target**, so the view
   cannot become a second place a chat id leaks into.

### What changed for a node that had no policy file

Before this wiring a service component's `kv.write`, `net.dial`, `credentials.read` and
`http.request` were governed by the manifest grant alone. Now they are refused with `no_policy` until
the operator writes a rule — the crate's documented default, and the reason a node that runs
wa-whatsapp wants a policy file before it starts it. To keep today's behaviour for one capability,
write a rule with no limits (`"kv.write": {}` means "any target, no rate"); to keep it for every
component, write the rules the node's components need. There is deliberately **no node-wide switch
that turns the policy off**, because a switch that silently disables a limit is the failure this
layer exists to prevent.

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
* **The wasip1 runner** (`services.rs` `wa_sock.connect`, used by core modules such as `svc-echo`) is
  not policy-checked: its `connect` sits inside the linker closure another stream owns. It needs the
  same shape as the wasi-socket check (grant, then `net.dial` per `host:port`).
* **Per-chat limits** need `wa:channel/messages` (`wit/kernel` 0.2, another job). Until then
  `node_policy::check_whatsapp_send` has no caller and only the global message cap is real.
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

Everything here is synchronous and cheap except the audit write (one `write` + `flush`). Today the
call sites are the synchronous `wa:kernel` host functions, so the write happens in the guest's own
call. When the kernel calls it from inside an async host call, that file write must not sit on a
guest's future:
with WASI 0.3 native async the host should hand records to a dedicated writer (bounded channel,
drop-oldest counted, `AuditSink` gaining an async or fire-and-forget form) while `Engine` stays a
plain `Mutex<Engine>` — no `await` is ever held with the guard, and `check`/`enforce` keep their
signatures. Nothing in the library needs to change shape for that: it has no clock, no I/O of its
own, and no wasmtime types.
