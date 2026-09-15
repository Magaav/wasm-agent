"""Minimal OpenAI-compatible chat provider (stdlib only)."""
from __future__ import annotations

import json
import urllib.error
import urllib.request


class ProviderError(RuntimeError):
    pass


class ChatProvider:
    def __init__(self, *, base_url: str, api_key: str, model: str,
                 timeout: float = 90.0, extra_headers: dict | None = None,
                 session_id: str = "wasm-agent") -> None:
        self.base_url = (base_url or "").rstrip("/")
        self.api_key = api_key or ""
        self.model = model or ""
        self.timeout = timeout
        self.session_id = session_id
        self.extra_headers = extra_headers or {}

    @property
    def configured(self) -> bool:
        return bool(self.base_url and self.api_key and self.model)

    def complete(self, messages, tools=None) -> dict:
        if not self.configured:
            raise ProviderError("provider_not_configured")
        body: dict = {"model": self.model, "messages": messages}
        if tools:
            body["tools"] = tools
            body["tool_choice"] = "auto"
        request = urllib.request.Request(
            self.base_url + "/chat/completions",
            data=json.dumps(body).encode("utf-8"),
            method="POST",
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {self.api_key}",
                     "Accept": "application/json",
                     # A default urllib User-Agent is rejected by the provider edge.
                     "User-Agent": "wasm-agent/0.1 provider-proxy",
                     "x-opencode-session": self.session_id,
                     **self.extra_headers})
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read()[:400].decode("utf-8", "replace")
            raise ProviderError(f"http_{exc.code}: {detail}") from exc
        except Exception as exc:  # network, timeout, bad json
            raise ProviderError(type(exc).__name__ + ":" + str(exc)[:200]) from exc
        message = ((payload.get("choices") or [{}])[0].get("message") or {})
        return {"content": message.get("content") or "", "tool_calls": message.get("tool_calls") or []}
