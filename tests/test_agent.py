"""Agent loop: tool calls, local fallback, session persistence."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from wasm_agent.agent.loop import Agent  # noqa: E402
from wasm_agent.memory import Memory  # noqa: E402


class FakeProvider:
    configured = True
    model = "fake"
    base_url = "test"

    def __init__(self, script):
        self.script = list(script)
        self.calls = 0

    def complete(self, messages, tools=None):
        self.calls += 1
        return self.script.pop(0)


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.memory = Memory(Path(self.tmp.name) / "memory.db")
        self.addCleanup(self.memory.close)

    def test_remember_tool_persists_to_memory(self):
        provider = FakeProvider([
            {"content": "", "tool_calls": [{"id": "c1", "function": {
                "name": "remember", "arguments": '{"content":"Laura likes tea","tags":["laura"]}'}}]},
            {"content": "Got it.", "tool_calls": []},
        ])
        agent = Agent(self.memory, provider)
        reply = agent.turn("remember that Laura likes tea")
        self.assertEqual(reply, "Got it.")
        self.assertEqual([m["content"] for m in self.memory.recall("laura")], ["Laura likes tea"])
        self.assertEqual(provider.calls, 2)

    def test_tool_error_is_returned_to_model_not_raised(self):
        provider = FakeProvider([
            {"content": "", "tool_calls": [{"id": "c1", "function": {
                "name": "recall", "arguments": "not json"}}]},
            {"content": "Recovered.", "tool_calls": []},
        ])
        agent = Agent(self.memory, provider)
        self.assertEqual(agent.turn("recall something"), "Recovered.")

    def test_local_mode_without_provider(self):
        class Unconfigured:
            configured = False

        self.memory.remember("the sky is blue")
        agent = Agent(self.memory, Unconfigured())
        self.assertIn("the sky is blue", agent.turn("sky"))

    def test_session_persists_runs(self):
        provider = FakeProvider([{"content": "hi", "tool_calls": []}])
        agent = Agent(self.memory, provider, session_id="sess1")
        agent.turn("hello")
        agent.close()
        session = self.memory.session("sess1")
        self.assertEqual(len(session["runs"]), 1)
        self.assertIsNotNone(session["ended_at"])


if __name__ == "__main__":
    unittest.main()
