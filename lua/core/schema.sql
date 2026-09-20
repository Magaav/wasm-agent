-- wasm-agent memory schema (SQLite, WAL). Ledger = source of truth; *_fts = index.
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS memories (
  id             TEXT PRIMARY KEY,
  scope          TEXT NOT NULL DEFAULT 'global',
  content        TEXT NOT NULL,
  tags           TEXT NOT NULL DEFAULT '[]',
  source         TEXT NOT NULL DEFAULT 'user',
  session_id     TEXT,
  created_at     REAL NOT NULL,
  updated_at     REAL NOT NULL,
  deleted_at     REAL,
  content_sha256 TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS memories_scope_idx ON memories(scope, deleted_at);
CREATE UNIQUE INDEX IF NOT EXISTS memories_dedupe_idx
  ON memories(scope, content_sha256) WHERE deleted_at IS NULL;
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
  content, tags, memory_id UNINDEXED, tokenize = 'unicode61 remove_diacritics 2');

CREATE TABLE IF NOT EXISTS observations (
  id TEXT PRIMARY KEY, source TEXT NOT NULL, device_id TEXT NOT NULL DEFAULT '',
  observed_at REAL NOT NULL, payload_sha256 TEXT NOT NULL, payload TEXT NOT NULL,
  ingested_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS observations_time_idx ON observations(observed_at);

CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL DEFAULT 'unknown', title TEXT NOT NULL DEFAULT '',
  created_at REAL NOT NULL, updated_at REAL NOT NULL);

-- The external inbox/ledger (WhatsApp, mail). It is `ledger_messages`, not `messages`: the naming
-- contract (ARCHITECTURE.md section 6) gives "message" to the agent's own transcript rows, which are the
-- `messages` table further down. Two tables cannot share one name, and this is the ledger - the word
-- docs/MEMORY.md already used for it, and the one its tools are named after (`search_messages`).
CREATE TABLE IF NOT EXISTS ledger_messages (
  conversation_id TEXT NOT NULL, message_id TEXT NOT NULL,
  sender_id TEXT NOT NULL DEFAULT '', direction TEXT NOT NULL DEFAULT 'incoming',
  sent_at REAL, observed_at REAL NOT NULL, body TEXT NOT NULL DEFAULT '',
  reply_to TEXT, media TEXT NOT NULL DEFAULT '[]', source TEXT NOT NULL DEFAULT 'observer',
  body_sha256 TEXT NOT NULL,
  PRIMARY KEY (conversation_id, message_id));
CREATE INDEX IF NOT EXISTS ledger_messages_conversation_idx ON ledger_messages(conversation_id, observed_at);
CREATE INDEX IF NOT EXISTS ledger_messages_time_idx ON ledger_messages(observed_at);
CREATE VIRTUAL TABLE IF NOT EXISTS ledger_messages_fts USING fts5(
  body, conversation_id UNINDEXED, message_id UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2');

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY, route_id TEXT NOT NULL DEFAULT '', objective TEXT NOT NULL DEFAULT '',
  parent_session_id TEXT, started_at REAL NOT NULL, ended_at REAL);

CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, run_id TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT '', outcome TEXT NOT NULL DEFAULT '', reply TEXT NOT NULL DEFAULT '',
  started_at REAL NOT NULL, ended_at REAL);
CREATE INDEX IF NOT EXISTS runs_session_idx ON runs(session_id, started_at);

CREATE TABLE IF NOT EXISTS run_links (
  run_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
  PRIMARY KEY (run_id, entity_type, entity_id));

-- ---------------------------------------------------------------- transcript
-- The agent's OWN dialogue: one row per stored message (a user turn, an assistant turn, a tool
-- result, a summary). Deliberately separate from `ledger_messages`, which is the external inbox.
-- `runs` stays an effect/settlement record; `messages` is the conversation, and `trace` on each
-- assistant message is the observability payload.
--
-- It was called `turns`, which was the ambiguity ARCHITECTURE.md section 6 settles: a *turn* is one
-- speaker's contribution, a *run* is the ask-and-answer, and a *message* is one stored row - which
-- is what this table holds.
CREATE TABLE IF NOT EXISTS messages (
  id           TEXT PRIMARY KEY,
  session_id   TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  role         TEXT NOT NULL,
  content      TEXT NOT NULL DEFAULT '',
  tool_calls   TEXT NOT NULL DEFAULT '[]',
  tool_call_id TEXT NOT NULL DEFAULT '',
  tool_name    TEXT NOT NULL DEFAULT '',
  tokens       INTEGER NOT NULL DEFAULT 0,
  ms           INTEGER NOT NULL DEFAULT 0,
  ok           INTEGER NOT NULL DEFAULT 1,
  debug        INTEGER NOT NULL DEFAULT 0,
  trace        TEXT NOT NULL DEFAULT '[]',
  created_at   REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_session_idx ON messages(session_id, seq);
CREATE INDEX IF NOT EXISTS messages_time_idx ON messages(created_at);
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
  content, session_id UNINDEXED, message_id UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2');

-- ------------------------------------------------------------- replication
-- An append-only journal of local mutations. Peers pull/push "everything after
-- cursor N", so sync is a diff, not a dump; applying an entry is idempotent and
-- entries carry their origin so they are never echoed back.
CREATE TABLE IF NOT EXISTS journal (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  kind       TEXT NOT NULL,
  entity_id  TEXT NOT NULL,
  op         TEXT NOT NULL DEFAULT 'upsert',
  origin     TEXT NOT NULL DEFAULT '',
  payload    TEXT NOT NULL,
  created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS journal_time_idx ON journal(created_at);

CREATE TABLE IF NOT EXISTS sync_cursors (
  peer_id    TEXT PRIMARY KEY,
  cursor     INTEGER NOT NULL DEFAULT 0,
  updated_at REAL NOT NULL
);
