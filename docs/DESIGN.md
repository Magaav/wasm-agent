# Design

## Goal

Give the agent an **organized** memory: facts it is told to remember, and a
ledger of everything that actually happened, queryable locally and (later) from
every device. Plain SQLite now; replication added later without a migration.

## Two kinds of data

**Ledger — append-only source of truth.** `observations` (raw ingestion,
deduplicated by payload hash), `conversations`, `messages`, `sessions`, `runs`,
`run_links`. Written only by ingestion helpers. Never model-authored.

**Memories — explicit, editable facts.** `memories` with `scope`, `tags`,
`source` (`user`/`agent`), soft delete (`deleted_at`) and a content hash for
dedupe. This is what "remember this" writes and "recall" reads.

**Derived — rebuildable, not yet implemented.** Summaries, embeddings, client
profiles. They will live in their own tables with the model/version and the
ledger watermark they were built from, so they can be dropped and regenerated at
any time. They are never the source of truth.

The rule that keeps memory organized: *the model reads the ledger and writes
explicit memories; it never rewrites the ledger, and derived data is disposable.*

## Schema notes

- Stable, human-meaningful keys (`(conversation_id, message_id)` for messages,
  content hash for observations) make ingestion **idempotent** — re-ingesting the
  same message or observation is a no-op.
- `updated_at` + `deleted_at` + stable ids exist so a change-log/CDC replication
  layer can be added later.
- Search is FTS5 with BM25 ranking and `unicode61 remove_diacritics 2` (good for
  Portuguese). FTS tables are maintained by the API in the same transaction as
  the row write, so they never drift.
- `reply_to` and `media` are modeled now even though today's observer does not
  populate them, so capture can be enriched without a migration.

## Roadmap

1. **Capture enrichment** — the observer currently emits only
   `{conversation_id, message_id, direction, summary, observed_at}`. Add sender,
   message timestamp, full body, reply context, media. Until then the ledger is
   a faithful but thin record.
2. **Ingestion** — map browser events (`message.incoming`) into
   `ingest_observation` + `record_message`; import WhatsApp "Export chat" files
   for history. Browser-scraping backfill is explicitly out of scope (fragile and
   likely against WhatsApp's terms).
3. **Read tools** — expose `remember`/`recall`/`search`/`conversation` and the
   session queries to the agent head model as a small, read-mostly tool surface.
4. **Replication** — a `sync` package: an outbox table appended in the same
   transaction as every write, a cursor table per device, and a signed HTTP
   push/pull against a self-hosted primary. Stable ids + soft deletes make this
   incremental and conflict-light. The same schema keeps working on plain SQLite.

## Secure device binding (design, not implemented)

The center is the authority; devices are granted scoped access and can be
revoked. Trust is in keys, not in the network.

1. The server mints a short-lived, high-entropy **pairing code** for an account.
2. The device generates an **Ed25519 keypair** locally (private key never leaves
   the device) and registers its public key with the code.
3. The server binds `device_id -> public_key` with a **scope** (which account,
   read/write) and returns a long-lived device token the device stores in the OS
   keychain.
4. Every sync request is **signed** by the device key and carries a monotonic
   cursor; the server verifies signature, token, scope and cursor before applying
   or returning changes.
5. Revocation marks the device dead; replicas wipe their local copy on next
   contact.

Transport is TLS. Tokens and keys never appear in logs. Orchestration runs on
the cloud VM for now; the protocol is designed so the primary can be
decentralized later without changing the on-device model.
