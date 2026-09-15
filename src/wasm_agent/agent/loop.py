"""The agent turn loop: model + memory tools, persisted to the session ledger."""
from __future__ import annotations

import json
import uuid

from .tools import TOOLS, dispatch

SYSTEM_PROMPT = (
    "You are wasm-agent, a concise, local-first assistant with durable memory.\n"
    "- When the user asks you to remember something, call `remember` and confirm briefly.\n"
    "- When the user asks about past conversations or facts, use `recall` (remembered facts) "
    "and `search_messages`/`conversation` (the message ledger).\n"
    "- Never invent facts. If memory has nothing, say so plainly.\n"
    "- Keep replies short."
)

MAX_TOOL_ROUNDS = 8


class Agent:
    def __init__(self, memory, provider, *, session_id: str | None = None,
                 route_id: str = "cli", system_prompt: str = SYSTEM_PROMPT) -> None:
        self.memory = memory
        self.provider = provider
        self.session_id = memory.start_session(session_id=session_id, route_id=route_id,
                                               objective="interactive chat")
        self.messages: list[dict] = [{"role": "system", "content": system_prompt}]

    def turn(self, text: str) -> str:
        if not self.provider or not self.provider.configured:
            return self._local(text)
        self.messages.append({"role": "user", "content": text})
        reply = ""
        for _ in range(MAX_TOOL_ROUNDS):
            result = self.provider.complete(self.messages, TOOLS)
            calls = result.get("tool_calls") or []
            assistant: dict = {"role": "assistant", "content": result.get("content") or None}
            if calls:
                assistant["tool_calls"] = calls
            self.messages.append(assistant)
            if not calls:
                reply = result.get("content") or ""
                break
            for call in calls:
                function = call.get("function") or {}
                name = function.get("name") or ""
                try:
                    arguments = json.loads(function.get("arguments") or "{}")
                except (TypeError, ValueError):
                    arguments = {}
                try:
                    output = dispatch(self.memory, name, arguments)
                except Exception as exc:  # tool errors are data, not crashes
                    output = {"error": f"{type(exc).__name__}: {exc}"}
                self.messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "name": name,
                                      "content": json.dumps(output, ensure_ascii=False, default=str)})
        else:
            reply = "(tool loop limit reached)"
        self._persist(text, reply)
        return reply

    def _persist(self, request: str, reply: str) -> None:
        run_id = uuid.uuid4().hex
        self.memory.record_run(run_id=run_id, session_id=self.session_id, turn_id=run_id,
                               status="completed", outcome="completed", reply=reply)
        self.memory.link_run(run_id, "session", self.session_id)

    def _local(self, text: str) -> str:
        """Deterministic fallback when no model provider is configured."""
        query = text.strip()
        memories = self.memory.recall(query, limit=5) if query else []
        messages = self.memory.search_messages(query, limit=5) if query else []
        lines = []
        if memories:
            lines.append("memories:\n" + "\n".join(f"- {m['content']}" for m in memories))
        if messages:
            lines.append("messages:\n" + "\n".join(
                f"- {m['conversation_id']} {m['sender_id'] or ''}: {m['body']}" for m in messages))
        if not lines:
            lines.append("No provider is configured and nothing in memory matched.")
        return "\n".join(lines)

    def close(self) -> None:
        self.memory.finish_session(self.session_id)
