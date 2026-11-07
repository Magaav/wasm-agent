# Email connector — IMAP in, SMTP out, as one service component

The mailbox as a channel, built the way the WhatsApp connector is (`docs/SERVICE-COMPONENTS.md`): one
pinned `.wasm` + manifest, the host supplies the outside world, the guest owns the protocol and the state,
and every outside effect is granted by name. Code: `rust/components/wa-email` (component),
`rust/wa-email-outbox` (send seam), `rust/wa-email-index` (record + query seam), and the tools in
`rust/wa-capabilities/src/email_{send,query}.rs`.

## What runs where

| piece | where | why |
| --- | --- | --- |
| IMAP (search / fetch), SMTP (submit), MIME parse, index, outbox worker | **guest** (`rust/components/wa-email`) | they are the connector's own rules, and they are pure enough to test natively against fake servers |
| TLS, DNS, TCP | **host** (`wa:email/transport`, `docs/KERNEL.md`) | the guest never sees a certificate or a key, exactly like the WhatsApp websocket |
| durable store | **host** (`wa:kernel/kv`, the component's own namespace) | the index and the sync state |
| secret | **host** (`wa:kernel/credentials`) | the password is a *vault name* in the config; the value never appears in config, logs or answers |
| the agent's questions and sends | **host** (`wa:queue`: `email.outbox`, `email.query`) | a send is a job, a question is a job: the architecture, not a side channel |
| the event | **host** (`wa:bus`: `email.received`) | a fact, so a subscriber that misses it is not a lost message: the index still has it |

```text
IMAP  --fetch-->  mime::parse  -->  r/<MAILBOX>/<uidvalidity>/<uid>  (kv)
                                    b/<sha256>                        (attachment bytes, bounded)
                                    email.received                    (bus, metadata only)
email.outbox  -->  validate + rate limit  -->  compose  -->  SMTP  -->  done(message id)
email.query   -->  search / read / media over the same kv           -->  done(bounded answer)
```

## Configuration (the service definition's `config`)

| key | default | meaning |
| --- | --- | --- |
| `imap` | required | `{host, port: 993, tls: true}` |
| `smtp` | required | `{host, port: 465, tls: true}` |
| `mailbox` | `INBOX` | the folder that is polled and indexed |
| `user` | required | the IMAP/SMTP account name (usually the address) |
| `credential` | required | the **vault name** of the password (`wa:kernel/credentials`); a `password` key in the config is refused by name |
| `from` | required | the addr-spec this connector sends as |
| `poll_seconds` | `60` | one poll round per interval (5..3600) |
| `max_per_round` | `50` | most messages fetched in one round |
| `rate` | `{per_minute: 6, per_day: 100, min_interval_ms: 2000}` | the connector's own send budget (the node policy is the first gate) |

`net` grants are the definition's, not the manifest's: the manifest declares `net: []`, and the operator
grants exactly two addresses, `imap-host:993` and `smtp-host:465`. A host outside the grant answers
`refused` at connect, and that refusal is the only answer that names the host.

TLS is required. `tls: false` is allowed only for a loopback host (`localhost`, `127.x`, `::1`), which is
what the tests use; a plaintext session to anything else is refused at config time
(`email_tls_required`) before a socket is opened.

## What the tools do

| tool | shape |
| --- | --- |
| `email_search` | `{q?, from?, subject?, mailbox?, since?, until?, has_attachment?, limit?}` — at least one filter; accent-folded; ranked; bounded (`truncated`, `matched`) |
| `email_read` | `{mailbox?, uid?, before?, limit?}` — newest first with `has_more`/`next_before`, or one message |
| `email_media` | `{uid, mailbox?}` — attachment metadata and the media handle; never bytes |
| `email_send` | `{to, cc?, subject, body, in_reply_to?, attachments?}` — validate, policy (`email.send`), enqueue; answers a job id |
| `email_send_status` | `{id}` — `queued`/`sending`/`done(message_id)`/`dead(reason)` |

A refusal is a stable word, never a silent success: `email_send_bad_to`, `email_send_bad_cc`,
`email_send_bad_subject` (a control character would be a header injection), `email_send_body_too_long`,
`email_send_rate_limited`, `email_search_empty_query`, `email_read_bad_limit`, `email_query_failed`, and
the connector's own `email_auth_failed`, `email_tls_required`, `email_credential_missing`.

## Rules the code enforces

* **Credentials only from the vault.** `Config::parse` refuses a `password`/`secret` key by name
  (`email_credential_in_config`) and never echoes it. The password lives in `Secret`, whose `Debug`,
  `Display` and the log redactor's output are masked; a server line that echoes it (535 answers do) is
  logged with it removed. A credential with a CR/LF is refused before it can break an IMAP `LOGIN` or an
  SMTP `AUTH` line.
* **No message text in any log.** `telemetry::Line` only accepts numbers and short codes, so a subject, a
  body, a filename or an address cannot be handed to a log by construction. The audit target of a send is
  `email:<n>rcpt:<digest>` — counts and digests.
* **An address is an addr-spec.** `wa_email_outbox::Mailbox` accepts `local@domain` only (dot-atom local,
  hostname domain): a display name, a comma list, a bare word, a control character or a non-ASCII address
  is refused with a code. That is also what makes header injection impossible on the send path.
* **Bounded.** Body text 40k characters, subject 900, attachments 3 × 24 KiB in the payload, one fetched
  message 4 MiB (`Imap::with_bound`), the index answer 60 KiB with trailing items dropped visibly, the
  search scan 4000 records. A component with a memory grant does not discover a mailbox's size by
  crashing.
* **Idempotent.** `index_record` keys a message by `mailbox/UIDVALIDITY/UID`, so a refetch after a dropped
  connection is not a second record; a UIDVALIDITY change starts a new key generation instead of
  overwriting the old one. A send's dedupe key is `sha256(to|cc|subject|body|in_reply_to)`.

## Lifecycle

Start: parse config, read the credential, report `starting`, then loop:
(1) one IMAP round — connect, login, select, `UID SEARCH UID <floor+1>:*`, `UID FETCH … BODY.PEEK[]` one
message at a time (PEEK, so the connector never marks mail read), index, publish, store the new floor;
(2) up to 8 outbox jobs; (3) up to 8 query jobs; (4) `wait_for(poll_seconds)`.
`lifecycle.stopping()` ends the loop between rounds; the component reports `degraded` with the error word
while a session is failing and `ready` once a round completes.

Reconnect: a dropped connection is `email_connection_closed` and retryable, with the supervisor's backoff
(1 s doubling to 60 s, reset after 10 healthy minutes). A refused credential is **not** retried on a
schedule: it reports `degraded`/`email_auth_failed` and waits at the ceiling until an operator changes the
vault.

## Known limits (this pass)

* No IMAP `IDLE`: a round is "search, fetch what is new, stop", and the wait between rounds is the
  component's own timer. That is what lets one loop serve the outbox and the queries between polls; IDLE
  needs a connection task that can be cancelled, which is the follow-up.
* `AUTH LOGIN` only (PLAIN/XOAUTH2 not implemented); a server that does not offer it answers
  `email_smtp_no_auth` rather than falling back to an anonymous relay.
* Attachment *download* from the index is not a tool yet (`email_media` names the handle); outbound
  attachments are small and ride the job payload.
* `email.send` is not in `policies/default.json` yet: a node without the rule answers "not ruled" and the
  check is inert, exactly as `whatsapp.send` was before its rule landed.

## Testing

```
cd rust && cargo test -p wa-email-outbox -p wa-email-index      # the two seams
cd rust/components/wa-email && cargo test                      # 54 native tests, in-process fake servers
cd rust/components/wa-email && cargo test --test idle_cost -- --nocapture
WA_BIN=... bash scripts/test-email-connector.lua               # contract copies, manifest, catalogue
```
The fake IMAP and SMTP servers are in-process (no port, no thread, no real mailbox): receive → indexed →
searchable, send → delivered → `done(message id)`, a dropped connection → reconnect without duplicates, and
a refused credential → a clear error with no secret in any line are all measured there (`REPORT.md` has
the exact results and the idle-cost numbers).
