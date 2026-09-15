-- wasm-agent memory schema (SQLite, WAL).
--
-- Ledger tables (observations, conversations, messages, sessions, runs) are the
-- append-only source of truth. The *_fts tables are search indexes. Anything
-- model-derived (summaries, embeddings, profiles) is rebuildable and will live
-- in separate tables so it can be dropped and regenerated at any time.

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- Explicit memories: user- or agent-authored facts ("remember ...").
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
  content, tags, memory_id UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2'
);

-- Raw ingestion buffer: exactly what a source emitted, deduplicated by hash.
CREATE TABLE IF NOT EXISTS observations (
  id             TEXT PRIMARY KEY,
  source         TEXT NOT NULL,
  device_id      TEXT NOT NULL DEFAULT '',
  observed_at    REAL NOT NULL,
  payload_sha256 TEXT NOT NULL,
  payload        TEXT NOT NULL,
  ingested_at    REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS observations_time_idx ON observations(observed_at);

-- Normalized world ledger.
CREATE TABLE IF NOT EXISTS conversations (
  id         TEXT PRIMARY KEY,
  kind       TEXT NOT NULL DEFAULT 'unknown',
  title      TEXT NOT NULL DEFAULT '',
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
  conversation_id TEXT NOT NULL,
  message_id      TEXT NOT NULL,
  sender_id       TEXT NOT NULL DEFAULT '',
  direction       TEXT NOT NULL DEFAULT 'incoming',
  sent_at         REAL,
  observed_at     REAL NOT NULL,
  body            TEXT NOT NULL DEFAULT '',
  reply_to        TEXT,
  media           TEXT NOT NULL DEFAULT '[]',
  source          TEXT NOT NULL DEFAULT 'observer',
  body_sha256     TEXT NOT NULL,
  PRIMARY KEY (conversation_id, message_id)
);
CREATE INDEX IF NOT EXISTS messages_conversation_idx ON messages(conversation_id, observed_at);
CREATE INDEX IF NOT EXISTS messages_time_idx ON messages(observed_at);

CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
  body, conversation_id UNINDEXED, message_id UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2'
);

-- Agent sessions and runs (query old sessions; link them to world entities).
CREATE TABLE IF NOT EXISTS sessions (
  id                TEXT PRIMARY KEY,
  route_id          TEXT NOT NULL DEFAULT '',
  objective         TEXT NOT NULL DEFAULT '',
  parent_session_id TEXT,
  started_at        REAL NOT NULL,
  ended_at          REAL
);

CREATE TABLE IF NOT EXISTS runs (
  id         TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  turn_id    TEXT NOT NULL DEFAULT '',
  status     TEXT NOT NULL DEFAULT '',
  outcome    TEXT NOT NULL DEFAULT '',
  reply      TEXT NOT NULL DEFAULT '',
  started_at REAL NOT NULL,
  ended_at   REAL
);
CREATE INDEX IF NOT EXISTS runs_session_idx ON runs(session_id, started_at);

CREATE TABLE IF NOT EXISTS run_links (
  run_id      TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id   TEXT NOT NULL,
  PRIMARY KEY (run_id, entity_type, entity_id)
);
