"""Interactive `wa` chat: model + memory, with local slash commands."""
from __future__ import annotations

import sys

from .. import __version__
from ..config import load_env_file, provider_settings
from .loop import Agent
from .provider import ChatProvider, ProviderError

HELP = """commands:
  /remember <text>     store a memory
  /recall <query>      search memories
  /memories            list recent memories
  /search <query>      search the message ledger
  /conversation <id>   read a conversation
  /stats               database counts
  /help                this help
  /exit                quit
anything else is sent to the model."""


def build_provider(model=None, base_url=None, api_key=None) -> ChatProvider:
    settings = provider_settings()
    return ChatProvider(base_url=base_url or settings["base_url"],
                        api_key=api_key or settings["api_key"],
                        model=model or settings["model"])


def _print(value, out) -> None:
    def line(item):
        if isinstance(item, dict) and "content" in item:
            tags = (" [" + ", ".join(item.get("tags") or []) + "]") if item.get("tags") else ""
            return f"{item.get('id', '')[:12]}  {item.get('scope', '')}{tags}  {item.get('content', '')}"
        if isinstance(item, dict) and "body" in item:
            return f"{item.get('conversation_id', '')}  {item.get('sender_id') or '-'}  {item.get('body', '')}"
        return str(item)
    if isinstance(value, list):
        if not value:
            print("(empty)", file=out)
        for item in value:
            print(line(item), file=out)
    else:
        print(line(value), file=out)


def run_chat(memory, *, model=None, base_url=None, api_key=None, session_id=None,
             input_fn=input, out=sys.stdout) -> int:
    load_env_file()
    provider = build_provider(model, base_url, api_key)
    agent = Agent(memory, provider, session_id=session_id)
    mode = f"{provider.model} @ {provider.base_url}" if provider.configured else "local mode (no model configured)"
    print(f"wasm-agent {__version__} — {mode}", file=out)
    print(f"memory: {memory.store.path}", file=out)
    print("type /help for commands, /exit to quit", file=out)
    try:
        while True:
            try:
                line = input_fn("wa> ")
            except (EOFError, KeyboardInterrupt):
                print("", file=out)
                break
            line = (line or "").strip()
            if not line:
                continue
            if line in {"/exit", "/quit"}:
                break
            if line == "/help":
                print(HELP, file=out)
                continue
            try:
                if line.startswith("/remember "):
                    _print(memory.remember(line[len("/remember "):], source="user"), out)
                elif line.startswith("/recall "):
                    _print(memory.recall(line[len("/recall "):]), out)
                elif line == "/memories":
                    _print(memory.memories(), out)
                elif line.startswith("/search "):
                    _print(memory.search_messages(line[len("/search "):]), out)
                elif line.startswith("/conversation "):
                    _print(memory.conversation(line[len("/conversation "):]), out)
                elif line == "/stats":
                    _print(memory.stats(), out)
                else:
                    print(agent.turn(line), file=out)
            except ProviderError as exc:
                print(f"provider error: {exc}", file=out)
    finally:
        agent.close()
    return 0
