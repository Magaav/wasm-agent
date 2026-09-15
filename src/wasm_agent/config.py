"""Configuration: a tiny KEY=VALUE env file plus provider settings.

Provider resolution is deliberately permissive so the same code works on the
cloud VM (which already has ``OPENCODE_GO_API_KEY``) and on a laptop.
"""
from __future__ import annotations

import os
from pathlib import Path

ENV_FILE = Path(os.environ.get("WASM_AGENT_ENV_FILE") or (Path.home() / ".wasm-agent" / "env"))


def load_env_file(path: Path | str | None = None) -> dict:
    """Load KEY=VALUE lines into ``os.environ`` (without overwriting). Returns them."""
    target = Path(path) if path else ENV_FILE
    loaded: dict[str, str] = {}
    try:
        lines = target.read_text(encoding="utf-8").splitlines()
    except OSError:
        return loaded
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip().strip("'\"")
        if not key:
            continue
        loaded[key] = value
        os.environ.setdefault(key, value)
    return loaded


def provider_settings(env: dict | None = None) -> dict:
    source = env if env is not None else os.environ
    return {
        "base_url": (source.get("WASM_AGENT_LLM_BASE_URL") or source.get("WASM_AGENT_OPENAI_BASE_URL")
                     or "https://opencode.ai/zen/go/v1"),
        "api_key": (source.get("WASM_AGENT_LLM_API_KEY") or source.get("OPENCODE_GO_API_KEY")
                    or source.get("OPENAI_API_KEY") or ""),
        "model": (source.get("WASM_AGENT_LLM_MODEL") or source.get("WASM_AGENT_DIRECT_HEAD_MODEL")
                  or source.get("WASM_AGENT_OPENAI_MODEL") or ""),
    }
