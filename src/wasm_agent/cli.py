"""wasm-agent command line.

Local-first and dependency-free: every command opens the SQLite database at
``--db`` (or ``$WASM_AGENT_DB``, or ``~/.wasm-agent/memory.db``) and exits.
"""
from __future__ import annotations

import argparse
import json
import sys

from . import __version__
from .memory.api import Memory
from .memory.store import DEFAULT_DB


def _emit(value, as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, ensure_ascii=False, indent=2, default=str))
        return
    if isinstance(value, list):
        if not value:
            print("(empty)")
        for item in value:
            print(_line(item))
    else:
        print(_line(value))


def _line(item) -> str:
    if not isinstance(item, dict):
        return str(item)
    if "content" in item:
        tags = (" [" + ", ".join(item.get("tags") or []) + "]") if item.get("tags") else ""
        return f"{item.get('id', '')[:12]}  {item.get('scope', '')}{tags}  {item.get('content', '')}"
    if "body" in item:
        when = item.get("sent_at") or item.get("observed_at")
        return f"{item.get('conversation_id', '')}  {item.get('sender_id') or '-'}  {item.get('body', '')}"
    return json.dumps(item, ensure_ascii=False, default=str)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wasm-agent", description="Portable agent memory.")
    parser.add_argument("--db", default=None, help=f"database path (default: {DEFAULT_DB})")
    parser.add_argument("--version", action="version", version=f"wasm-agent {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init", help="create or migrate the database").add_argument("--json", action="store_true")

    p = sub.add_parser("remember", help="store an explicit memory")
    p.add_argument("text")
    p.add_argument("--scope", default="global")
    p.add_argument("--tag", action="append", default=[])
    p.add_argument("--source", default="user", choices=["user", "agent"])
    p.add_argument("--session")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("recall", help="search explicit memories")
    p.add_argument("query")
    p.add_argument("--scope")
    p.add_argument("--limit", type=int, default=10)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("memories", help="list explicit memories")
    p.add_argument("--scope")
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("forget", help="soft-delete a memory")
    p.add_argument("memory_id")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("search", help="search the message ledger")
    p.add_argument("query")
    p.add_argument("--conversation")
    p.add_argument("--limit", type=int, default=20)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("conversation", help="read one conversation")
    p.add_argument("conversation_id")
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("conversations", help="list conversations")
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--json", action="store_true")

    sub.add_parser("stats", help="database counts").add_argument("--json", action="store_true")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    memory = Memory(args.db)
    try:
        if args.command == "init":
            _emit({"database": str(memory.store.path), "schema_version": memory.store.migrate(),
                   "journal_mode": memory.conn.execute("PRAGMA journal_mode").fetchone()[0]}, args.json)
        elif args.command == "remember":
            _emit(memory.remember(args.text, scope=args.scope, tags=args.tag,
                                  source=args.source, session_id=args.session), args.json)
        elif args.command == "recall":
            _emit(memory.recall(args.query, scope=args.scope, limit=args.limit), args.json)
        elif args.command == "memories":
            _emit(memory.memories(scope=args.scope, limit=args.limit), args.json)
        elif args.command == "forget":
            _emit({"forgotten": memory.forget(args.memory_id)}, args.json)
        elif args.command == "search":
            _emit(memory.search_messages(args.query, conversation_id=args.conversation, limit=args.limit), args.json)
        elif args.command == "conversation":
            _emit(memory.conversation(args.conversation_id, limit=args.limit), args.json)
        elif args.command == "conversations":
            _emit(memory.conversations(limit=args.limit), args.json)
        elif args.command == "stats":
            _emit(memory.stats(), args.json)
        else:  # pragma: no cover - argparse enforces the choice
            build_parser().print_help()
            return 2
    finally:
        memory.close()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
