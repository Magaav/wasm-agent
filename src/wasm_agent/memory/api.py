"""Organized, local-first memory.

Two kinds of data, never mixed:

* **Ledger** (``observations``/``conversations``/``messages``/``sessions``/``runs``)
  is the append-only source of truth. It is only written by ingestion helpers.
* **Memories** (``memories``) are explicit facts a user or the agent asks to
  remember. They are editable and soft-deletable, and the model may write them.

Search is FTS5 (BM25). Anything model-derived is rebuildable and does not belong
here; keep it in separate tables so it can be regenerated.
"""
from __future__ import annotations

import json
import re
import uuid

from .store import DEFAULT_DB, Store, sha256, utc_now

_SPLIT = re.compile(r"[^\w]+", re.UNICODE)


def fts_query(text: str) -> str:
    """Turn free text into a safe FTS5 AND-of-quoted-terms query."""
    terms = [term for term in _SPLIT.split(str(text)) if term]
    if not terms:
        return '""'
    return " AND ".join('"' + term.replace('"', '""') + '"' for term in terms)


class Memory:
    def __init__(self, path: str | None = DEFAULT_DB) -> None:
        self.store = Store(path)
        self.conn = self.store.conn

    def close(self) -> None:
        self.store.close()

    def __enter__(self) -> "Memory":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    # ------------------------------------------------------------------ memories

    def remember(self, content, *, scope: str = "global", tags=None, source: str = "user",
                 session_id: str | None = None) -> dict:
        text = str(content).strip()
        if not text:
            raise ValueError("memory_empty")
        if len(text) > 8000:
            raise ValueError("memory_too_large")
        scope = str(scope or "global").strip() or "global"
        tags = [str(tag).strip() for tag in (tags or []) if str(tag).strip()][:16]
        digest = sha256(text)
        existing = self.conn.execute(
            "SELECT * FROM memories WHERE scope=? AND content_sha256=? AND deleted_at IS NULL",
            (scope, digest)).fetchone()
        if existing is not None:
            return self._memory(existing, deduplicated=True)
        memory_id = uuid.uuid4().hex
        now = utc_now()
        with self.conn:
            self.conn.execute(
                "INSERT INTO memories(id,scope,content,tags,source,session_id,created_at,updated_at,content_sha256)"
                " VALUES(?,?,?,?,?,?,?,?,?)",
                (memory_id, scope, text, json.dumps(tags, ensure_ascii=False), source, session_id, now, now, digest))
            self.conn.execute("INSERT INTO memories_fts(content,tags,memory_id) VALUES(?,?,?)",
                              (text, " ".join(tags), memory_id))
        return self.memory(memory_id)

    def memory(self, memory_id: str) -> dict | None:
        row = self.conn.execute(
            "SELECT * FROM memories WHERE id=? AND deleted_at IS NULL", (memory_id,)).fetchone()
        return self._memory(row) if row else None

    def memories(self, *, scope: str | None = None, limit: int = 50) -> list[dict]:
        limit = max(1, min(int(limit), 200))
        sql = "SELECT * FROM memories WHERE deleted_at IS NULL"
        params: list = []
        if scope:
            sql += " AND scope=?"
            params.append(scope)
        sql += " ORDER BY updated_at DESC LIMIT ?"
        params.append(limit)
        return [self._memory(row) for row in self.conn.execute(sql, params).fetchall()]

    def recall(self, query, *, scope: str | None = None, limit: int = 10) -> list[dict]:
        limit = max(1, min(int(limit), 100))
        sql = ("SELECT m.*, bm25(memories_fts) AS rank FROM memories_fts "
               "JOIN memories m ON m.id = memories_fts.memory_id "
               "WHERE memories_fts MATCH ? AND m.deleted_at IS NULL")
        params: list = [fts_query(query)]
        if scope:
            sql += " AND (m.scope=? OR m.scope='global')"
            params.append(scope)
        sql += " ORDER BY rank LIMIT ?"
        params.append(limit)
        return [self._ranked(self._memory(row), row) for row in self.conn.execute(sql, params).fetchall()]

    def forget(self, memory_id: str) -> bool:
        now = utc_now()
        with self.conn:
            changed = self.conn.execute(
                "UPDATE memories SET deleted_at=?, updated_at=? WHERE id=? AND deleted_at IS NULL",
                (now, now, memory_id)).rowcount
            if changed:
                self.conn.execute("DELETE FROM memories_fts WHERE memory_id=?", (memory_id,))
        return bool(changed)

    # -------------------------------------------------------------------- ledger

    def ingest_observation(self, *, source: str, payload, device_id: str = "",
                           observed_at: float | None = None) -> dict:
        raw = payload if isinstance(payload, str) else json.dumps(
            payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        digest = sha256(raw)
        now = utc_now()
        with self.conn:
            inserted = self.conn.execute(
                "INSERT OR IGNORE INTO observations(id,source,device_id,observed_at,payload_sha256,payload,ingested_at)"
                " VALUES(?,?,?,?,?,?,?)",
                (digest, str(source), str(device_id), float(observed_at or now), digest, raw, now)).rowcount
        return {"id": digest, "deduplicated": inserted == 0}

    def record_message(self, *, conversation_id, message_id, body, sender_id: str = "",
                       direction: str = "incoming", sent_at: float | None = None,
                       observed_at: float | None = None, reply_to: str | None = None,
                       media=None, source: str = "observer", kind: str | None = None,
                       title: str | None = None) -> dict:
        conversation_id = str(conversation_id).strip()
        message_id = str(message_id).strip()
        if not conversation_id or not message_id:
            raise ValueError("message_identity_required")
        body = str(body or "")
        now = float(observed_at or utc_now())
        digest = sha256(body)
        with self.conn:
            self._touch_conversation(conversation_id, now, kind, title)
            existing = self.conn.execute(
                "SELECT body_sha256 FROM messages WHERE conversation_id=? AND message_id=?",
                (conversation_id, message_id)).fetchone()
            if existing is None:
                self.conn.execute(
                    "INSERT INTO messages(conversation_id,message_id,sender_id,direction,sent_at,observed_at,"
                    "body,reply_to,media,source,body_sha256) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                    (conversation_id, message_id, sender_id, direction, sent_at, now, body, reply_to,
                     json.dumps(media or [], ensure_ascii=False), source, digest))
                self._index_message(conversation_id, message_id, body)
                created = True
            elif existing["body_sha256"] != digest:
                self.conn.execute(
                    "UPDATE messages SET body=?, body_sha256=?, sender_id=?, direction=?, "
                    "sent_at=COALESCE(?,sent_at), observed_at=?, reply_to=COALESCE(?,reply_to), media=?, source=? "
                    "WHERE conversation_id=? AND message_id=?",
                    (body, digest, sender_id, direction, sent_at, now, reply_to,
                     json.dumps(media or [], ensure_ascii=False), source, conversation_id, message_id))
                self.conn.execute("DELETE FROM messages_fts WHERE conversation_id=? AND message_id=?",
                                  (conversation_id, message_id))
                self._index_message(conversation_id, message_id, body)
                created = False
            else:
                created = False
        return {"conversation_id": conversation_id, "message_id": message_id, "created": created}

    def search_messages(self, query, *, conversation_id: str | None = None, limit: int = 20) -> list[dict]:
        limit = max(1, min(int(limit), 100))
        sql = ("SELECT msg.*, bm25(messages_fts) AS rank FROM messages_fts "
               "JOIN messages msg ON msg.conversation_id=messages_fts.conversation_id "
               "AND msg.message_id=messages_fts.message_id WHERE messages_fts MATCH ?")
        params: list = [fts_query(query)]
        if conversation_id:
            sql += " AND msg.conversation_id=?"
            params.append(conversation_id)
        sql += " ORDER BY rank LIMIT ?"
        params.append(limit)
        return [self._ranked(self._message(row), row) for row in self.conn.execute(sql, params).fetchall()]

    def conversation(self, conversation_id: str, *, limit: int = 50, before: float | None = None) -> list[dict]:
        limit = max(1, min(int(limit), 500))
        sql = "SELECT * FROM messages WHERE conversation_id=?"
        params: list = [conversation_id]
        if before is not None:
            sql += " AND COALESCE(sent_at, observed_at) < ?"
            params.append(float(before))
        sql += " ORDER BY COALESCE(sent_at, observed_at) DESC LIMIT ?"
        params.append(limit)
        rows = self.conn.execute(sql, params).fetchall()
        return [self._message(row) for row in reversed(rows)]

    def conversations(self, *, limit: int = 50) -> list[dict]:
        limit = max(1, min(int(limit), 500))
        rows = self.conn.execute(
            "SELECT c.*, (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id) AS message_count "
            "FROM conversations c ORDER BY c.updated_at DESC LIMIT ?", (limit,)).fetchall()
        return [{"id": row["id"], "kind": row["kind"], "title": row["title"],
                 "created_at": row["created_at"], "updated_at": row["updated_at"],
                 "message_count": row["message_count"]} for row in rows]

    # ------------------------------------------------------------------ sessions

    def start_session(self, *, session_id: str | None = None, route_id: str = "",
                      objective: str = "", parent_session_id: str | None = None) -> str:
        sid = str(session_id or uuid.uuid4().hex)
        with self.conn:
            self.conn.execute(
                "INSERT OR IGNORE INTO sessions(id,route_id,objective,parent_session_id,started_at) VALUES(?,?,?,?,?)",
                (sid, route_id, str(objective)[:2000], parent_session_id, utc_now()))
        return sid

    def finish_session(self, session_id: str) -> None:
        with self.conn:
            self.conn.execute("UPDATE sessions SET ended_at=? WHERE id=? AND ended_at IS NULL",
                              (utc_now(), session_id))

    def record_run(self, *, run_id: str, session_id: str, turn_id: str = "", status: str = "",
                   outcome: str = "", reply: str = "", started_at: float | None = None,
                   ended_at: float | None = None) -> str:
        with self.conn:
            self.conn.execute(
                "INSERT INTO runs(id,session_id,turn_id,status,outcome,reply,started_at,ended_at) VALUES(?,?,?,?,?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET turn_id=excluded.turn_id, status=excluded.status, "
                "outcome=excluded.outcome, reply=excluded.reply, ended_at=excluded.ended_at",
                (run_id, session_id, turn_id, status, outcome, str(reply)[:20000],
                 float(started_at or utc_now()), ended_at))
        return run_id

    def link_run(self, run_id: str, entity_type: str, entity_id: str) -> None:
        with self.conn:
            self.conn.execute("INSERT OR IGNORE INTO run_links(run_id,entity_type,entity_id) VALUES(?,?,?)",
                              (run_id, entity_type, entity_id))

    def session(self, session_id: str) -> dict | None:
        row = self.conn.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        if row is None:
            return None
        runs = self.conn.execute("SELECT * FROM runs WHERE session_id=? ORDER BY started_at", (session_id,)).fetchall()
        return {**dict(row), "runs": [dict(run) for run in runs]}

    # --------------------------------------------------------------------- misc

    def stats(self) -> dict:
        count = lambda sql: self.conn.execute(sql).fetchone()[0]  # noqa: E731
        return {
            "database": str(self.store.path),
            "journal_mode": self.conn.execute("PRAGMA journal_mode").fetchone()[0],
            "memories": count("SELECT COUNT(*) FROM memories WHERE deleted_at IS NULL"),
            "conversations": count("SELECT COUNT(*) FROM conversations"),
            "messages": count("SELECT COUNT(*) FROM messages"),
            "observations": count("SELECT COUNT(*) FROM observations"),
            "sessions": count("SELECT COUNT(*) FROM sessions"),
            "runs": count("SELECT COUNT(*) FROM runs"),
        }

    # ------------------------------------------------------------------ internal

    def _touch_conversation(self, conversation_id: str, now: float, kind: str | None, title: str | None) -> None:
        self.conn.execute(
            "INSERT INTO conversations(id,kind,title,created_at,updated_at) VALUES(?,?,?,?,?) "
            "ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at, "
            "kind=CASE WHEN excluded.kind<>'unknown' THEN excluded.kind ELSE conversations.kind END, "
            "title=CASE WHEN excluded.title<>'' THEN excluded.title ELSE conversations.title END",
            (conversation_id, kind or "unknown", title or "", now, now))

    def _index_message(self, conversation_id: str, message_id: str, body: str) -> None:
        self.conn.execute("INSERT INTO messages_fts(body,conversation_id,message_id) VALUES(?,?,?)",
                          (body, conversation_id, message_id))

    @staticmethod
    def _memory(row, *, deduplicated: bool = False) -> dict:
        item = {"id": row["id"], "scope": row["scope"], "content": row["content"],
                "tags": json.loads(row["tags"] or "[]"), "source": row["source"],
                "session_id": row["session_id"], "created_at": row["created_at"],
                "updated_at": row["updated_at"]}
        if deduplicated:
            item["deduplicated"] = True
        return item

    @staticmethod
    def _message(row) -> dict:
        return {"conversation_id": row["conversation_id"], "message_id": row["message_id"],
                "sender_id": row["sender_id"], "direction": row["direction"],
                "sent_at": row["sent_at"], "observed_at": row["observed_at"],
                "body": row["body"], "reply_to": row["reply_to"],
                "media": json.loads(row["media"] or "[]"), "source": row["source"]}

    @staticmethod
    def _ranked(item: dict, row) -> dict:
        if "rank" in row.keys():
            item["rank"] = row["rank"]
        return item
