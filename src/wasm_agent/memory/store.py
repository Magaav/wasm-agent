"""SQLite store: one file, WAL, idempotent schema migration."""
from __future__ import annotations

import hashlib
import os
import sqlite3
import time
from pathlib import Path

SCHEMA_VERSION = 1
SCHEMA_PATH = Path(__file__).with_name("schema.sql")
DEFAULT_DB = Path(os.environ.get("WASM_AGENT_DB") or (Path.home() / ".wasm-agent" / "memory.db"))


def utc_now() -> float:
    return time.time()


def sha256(value: str) -> str:
    return hashlib.sha256(str(value).encode("utf-8")).hexdigest()


class Store:
    """A single-file SQLite database in WAL mode.

    Plain SQLite on purpose: no service, no cloud, no lock-in. The schema uses
    stable ids, ``updated_at`` and soft deletes so a change-log replication layer
    can be added later without a migration.
    """

    def __init__(self, path: str | os.PathLike | None = None) -> None:
        self.path = Path(path).expanduser() if path else DEFAULT_DB
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(self.path))
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self.migrate()

    def migrate(self) -> int:
        self.conn.executescript(SCHEMA_PATH.read_text(encoding="utf-8"))
        row = self.conn.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
        current = int(row["value"]) if row else 0
        if current < SCHEMA_VERSION:
            self.conn.execute(
                "INSERT INTO meta(key,value) VALUES('schema_version',?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (str(SCHEMA_VERSION),),
            )
            self.conn.commit()
        return SCHEMA_VERSION

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> "Store":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()
