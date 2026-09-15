"""Memory tools exposed to the head model (OpenAI function-calling schema)."""
from __future__ import annotations

TOOLS = [
    {"type": "function", "function": {
        "name": "remember",
        "description": "Store a fact the user asked you to remember, so it can be recalled later.",
        "parameters": {"type": "object", "properties": {
            "content": {"type": "string", "description": "The fact to remember, in full."},
            "scope": {"type": "string", "description": "Optional scope, e.g. global or a conversation id."},
            "tags": {"type": "array", "items": {"type": "string"}}},
            "required": ["content"]}}},
    {"type": "function", "function": {
        "name": "recall",
        "description": "Search remembered facts (the memories store).",
        "parameters": {"type": "object", "properties": {
            "query": {"type": "string"}, "scope": {"type": "string"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 50}},
            "required": ["query"]}}},
    {"type": "function", "function": {
        "name": "search_messages",
        "description": "Search the message ledger (WhatsApp/chat history) for literal text.",
        "parameters": {"type": "object", "properties": {
            "query": {"type": "string"}, "conversation_id": {"type": "string"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 50}},
            "required": ["query"]}}},
    {"type": "function", "function": {
        "name": "conversation",
        "description": "Read the most recent messages of one conversation, oldest first.",
        "parameters": {"type": "object", "properties": {
            "conversation_id": {"type": "string"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 200}},
            "required": ["conversation_id"]}}},
    {"type": "function", "function": {
        "name": "list_conversations",
        "description": "List conversations known to the ledger, most recently active first.",
        "parameters": {"type": "object", "properties": {
            "limit": {"type": "integer", "minimum": 1, "maximum": 200}}}}},
]


def dispatch(memory, name: str, arguments: dict):
    if name == "remember":
        return memory.remember(arguments.get("content", ""), scope=arguments.get("scope", "global"),
                               tags=arguments.get("tags"), source="agent")
    if name == "recall":
        return memory.recall(arguments.get("query", ""), scope=arguments.get("scope"),
                             limit=int(arguments.get("limit", 10)))
    if name == "search_messages":
        return memory.search_messages(arguments.get("query", ""),
                                      conversation_id=arguments.get("conversation_id"),
                                      limit=int(arguments.get("limit", 20)))
    if name == "conversation":
        return memory.conversation(arguments.get("conversation_id", ""),
                                   limit=int(arguments.get("limit", 50)))
    if name == "list_conversations":
        return memory.conversations(limit=int(arguments.get("limit", 50)))
    raise ValueError(f"unknown_tool:{name}")
