# Grant policy — rate limits, approvals and audit for capability calls

Status 05/11: library built and tested (`rust/wa-grant-policy`, 40 unit tests + doctest); **not wired
into the host yet**. This document is the schema, the decision rules, and the wiring the host needs
before the WhatsApp component may post to a real chat beyond its own test chat. Context:
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

**Bounded store later.** The sink trait is the seam: the file sink stays the durable one; a second
sink writes the same record into a SQLite table (`audit(ts_ms, component, capability, target_digest,
decision, reason)`, indexed by `ts_ms`, pruned to a row budget or a day budget) served by the kernel
component that owns policy state. Reading it must page (`WHERE ts_ms < ? ORDER BY ts_ms DESC LIMIT
?`), never scan, and the pruning must count what it pruned — dropping evidence silently is worse
than a bigger file. Until then: rotate at 8 MiB like the service log, and say the count in
`host.components()`.

## How the host wires it (to be done in `service_components.rs`; this document does not edit it)

1. **Load once per node.** `PolicySet::from_file` on the node policy file (`WA_GRANT_POLICY`, default
   `<state>/grant-policy.json`) at `wa serve` start; a load error is fatal for the capability it
   governs, not for the node: `wa` starts, every component's sensitive calls are `no_policy`, and the
   error is in the log. `Engine::restore_json` from `<state>/grant-policy.state.json` (missing file =
   fresh budgets). Snapshot on graceful stop and every N minutes.
2. **One engine, one sink.** `Mutex<Engine>` plus the sink beside it in `Shared`: `FileAudit` at
   `<state>/audit/grant-policy.jsonl` (8 MiB rotation) and a `MemoryAudit` ring of the last 512
   records for `host.components()`. Never `await` while holding the guard (see the WASI 0.3 note).
3. **Clock.** `now_ms` = `SystemTime::now().duration_since(UNIX_EPOCH)`, read once per call and
   passed down; nothing inside the library reads a clock.
4. **One check per sensitive host call**, in the `Host` impls of `service_components.rs`, before the
   effect and *after* the grant check:

   | WIT call | capability | target passed to the policy |
   | --- | --- | --- |
   | `websocket.connect(url, origin)` | `net.dial` | `url` authority |
   | `websocket.send(data)` | `net.send` | the socket's authority |
   | `http.start(request)` | `http.request` | `url` authority |
   | `kv.set` / `kv.delete` / `kv.delete_prefix` | `kv.write` | the key (or its prefix) |
   | `kv.get` / `kv.scan` | `kv.read` | the key (or its prefix) |
   | `credentials.get(name)` | `credentials.read` | `name` |
   | `speech.start(...)` | `stt.start` | `"-"`/none |
   | `log.write`, `lifecycle.*` | never checked | a log line cannot exceed anything a person sees |

   Result mapping: `Allow` → proceed; `Deny(no_policy | policy_denied | target_denied |
   target_not_allowed)` → `KError::Refused(reason.as_str())`; `RateLimited` → either
   `KError::Refused("capability_rate_limited")` or `KError::Again` when `retry_after_ms` is under a
   second (the guest already retries `again`), with the number in the component log;
   `NeedsApproval` → `KError::Refused("approval_required")` and one operator notification, not a
   notification per attempt.
5. **Approvals.** `Engine::approve(component, capability, target, now_ms, ttl_ms)` from the operator
   path (`services` tool / CLI, master only), one use per approval, ttl default 15 min. Pending
   approvals are visible and revocable (`revoke_approvals`).
6. **Same checks in the wasip1 runner** (`services.rs`, `wa_sock`) once it is not being changed by
   another stream: `connect` → `net.dial`, `read`/`write` on an allowed socket → `net.send`.
7. **Audit errors** are drained per tick into the node log with the sink name only (never the
   target), and counted in `host.components()` so a silent stop of the audit trail is visible.

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

Everything here is synchronous and cheap except the audit write (one `write` + `flush`). When the
kernel calls it from inside an async host call, that file write must not sit on a guest's future:
with WASI 0.3 native async the host should hand records to a dedicated writer (bounded channel,
drop-oldest counted, `AuditSink` gaining an async or fire-and-forget form) while `Engine` stays a
plain `Mutex<Engine>` — no `await` is ever held with the guard, and `check`/`enforce` keep their
signatures. Nothing in the library needs to change shape for that: it has no clock, no I/O of its
own, and no wasmtime types.
