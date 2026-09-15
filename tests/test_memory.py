"""Memory foundation: ledger, explicit memories, FTS, idempotent migrations."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from wasm_agent.memory import Memory  # noqa: E402
from wasm_agent.memory.api import fts_query  # noqa: E402


class MemoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "memory.db"
        self.memory = Memory(self.path)
        self.addCleanup(self.memory.close)

    def test_schema_and_stats(self):
        stats = self.memory.stats()
        self.assertEqual(stats["journal_mode"], "wal")
        self.assertEqual(stats["memories"], 0)
        self.assertEqual(stats["messages"], 0)

    def test_remember_and_recall(self):
        saved = self.memory.remember("Laura prefers invoices on the 5th", tags=["laura", "billing"])
        self.assertFalse(saved.get("deduplicated"))
        hits = self.memory.recall("laura invoices")
        self.assertEqual([hit["id"] for hit in hits], [saved["id"]])
        self.assertEqual(hits[0]["tags"], ["laura", "billing"])

    def test_recall_respects_scope(self):
        self.memory.remember("global fact about acme", scope="global")
        self.memory.remember("scoped fact about acme", scope="conversation:1")
        scoped = self.memory.recall("acme", scope="conversation:1")
        scopes = {hit["scope"] for hit in scoped}
        self.assertIn("conversation:1", scopes)
        self.assertIn("global", scopes)

    def test_remember_deduplicates_within_scope(self):
        first = self.memory.remember("same fact")
        second = self.memory.remember("same fact")
        self.assertEqual(first["id"], second["id"])
        self.assertTrue(second["deduplicated"])
        self.assertEqual(len(self.memory.memories()), 1)

    def test_forget_removes_from_search(self):
        saved = self.memory.remember("temporary fact")
        self.assertTrue(self.memory.forget(saved["id"]))
        self.assertEqual(self.memory.recall("temporary"), [])
        self.assertIsNone(self.memory.memory(saved["id"]))

    def test_empty_and_oversized_memories_rejected(self):
        with self.assertRaises(ValueError):
            self.memory.remember("   ")
        with self.assertRaises(ValueError):
            self.memory.remember("x" * 8001)

    def test_observations_are_deduplicated(self):
        first = self.memory.ingest_observation(source="observer", payload={"id": "e1", "body": "hi"})
        second = self.memory.ingest_observation(source="observer", payload={"id": "e1", "body": "hi"})
        self.assertFalse(first["deduplicated"])
        self.assertTrue(second["deduplicated"])
        self.assertEqual(self.memory.stats()["observations"], 1)

    def test_messages_search_and_conversation_order(self):
        self.memory.record_message(conversation_id="c1", message_id="m2", body="second message",
                                   sender_id="bob", sent_at=200.0, kind="dm", title="Bob")
        self.memory.record_message(conversation_id="c1", message_id="m1", body="first message",
                                   sender_id="bob", sent_at=100.0)
        ordered = self.memory.conversation("c1")
        self.assertEqual([m["message_id"] for m in ordered], ["m1", "m2"])
        hits = self.memory.search_messages("first")
        self.assertEqual([hit["message_id"] for hit in hits], ["m1"])
        conversations = self.memory.conversations()
        self.assertEqual(conversations[0]["id"], "c1")
        self.assertEqual(conversations[0]["title"], "Bob")
        self.assertEqual(conversations[0]["message_count"], 2)

    def test_message_upsert_reindexes_edited_body(self):
        self.memory.record_message(conversation_id="c1", message_id="m1", body="original")
        changed = self.memory.record_message(conversation_id="c1", message_id="m1", body="corrected")
        self.assertFalse(changed["created"])
        self.assertEqual(self.memory.search_messages("original"), [])
        self.assertEqual(len(self.memory.search_messages("corrected")), 1)

    def test_sessions_and_runs(self):
        session_id = self.memory.start_session(route_id="chat", objective="help client")
        self.memory.record_run(run_id="r1", session_id=session_id, status="completed",
                               outcome="completed", reply="done")
        self.memory.link_run("r1", "conversation", "c1")
        self.memory.finish_session(session_id)
        session = self.memory.session(session_id)
        self.assertEqual(session["objective"], "help client")
        self.assertIsNotNone(session["ended_at"])
        self.assertEqual(session["runs"][0]["id"], "r1")

    def test_reopen_is_idempotent(self):
        self.memory.remember("persisted")
        self.memory.close()
        reopened = Memory(self.path)
        self.addCleanup(reopened.close)
        self.assertEqual(len(reopened.recall("persisted")), 1)

    def test_fts_query_is_syntax_safe(self):
        self.memory.remember('quotes " and operators OR NOT')
        self.assertEqual(len(self.memory.recall('quotes" OR NOT')), 1)
        self.assertEqual(fts_query(""), '""')


if __name__ == "__main__":
    unittest.main()
