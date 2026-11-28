#!/usr/bin/env python3
"""A provider that answers a FIXED SCRIPT and writes down what every request cost.

WHY IT EXISTS (item model-facing-changes-are-measured, Victor 25/11). A change is measured by running the SAME tasks
against the base tree and the tip tree and comparing what the model was asked to read: the request bytes of a healthy
call (a prompt cache dies on any difference), the system prompt and tool description bytes, the tool-result bytes, the
tokens, the rounds and the wall time. None of that may depend on a real account or on network, so the provider is this
file: it replays a script, one entry per completion request, and appends one JSON line per request to a ledger.

It is deliberately NOT stub-provider.py (which answers one fixed reply and counts requests): a task set needs a run
that CALLS A TOOL and reads its result, and it needs the numbers, not only the count. The wire is the same
OpenAI-compatible one (POST /v1/chat/completions, streaming and not, GET /v1/models), because that is what the node
speaks to every provider in its registry - so the same task set compares providers too, and `--model` on a real
provider is the only thing that changes.

Environment:
  STUB_PORT            port to bind (0 = pick one and print `listening <port>`)
  STUB_SCRIPT          path to a JSON list of replies; each entry is {"content": "..."} or
                       {"tool_calls": [{"name": "...", "arguments": {...}}]}. After the list is spent the last
                       entry repeats, so a task can never hang for want of a reply.
  STUB_LEDGER          path to append one JSON line per completion request (required to be useful)
  STUB_SLEEP_SECONDS   hold each request this long (default 0)
  STUB_MODEL           the model name to report (default stub-model)
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("STUB_PORT", "0") or 0)
LEDGER = os.environ.get("STUB_LEDGER", "")
SLEEP = float(os.environ.get("STUB_SLEEP_SECONDS", "0") or 0)
MODEL = os.environ.get("STUB_MODEL", "stub-model") or "stub-model"
LOCK = threading.Lock()
COUNT = [0]


def load_script():
    path = os.environ.get("STUB_SCRIPT", "")
    if not path:
        return [{"content": "stub reply"}]
    with open(path, "r", encoding="utf-8") as handle:
        entries = json.load(handle)
    if not isinstance(entries, list) or not entries:
        raise SystemExit("stub script must be a non-empty JSON list")
    return entries


SCRIPT = load_script()


def byte_len(value):
    return len(json.dumps(value, ensure_ascii=False).encode("utf-8")) if value is not None else 0


def text_bytes(value):
    if value is None:
        return 0
    if isinstance(value, str):
        return len(value.encode("utf-8"))
    return byte_len(value)


def measure(request, index, began_ms):
    """The facts a before/after table needs, from the request as it came off the wire."""
    messages = request.get("messages") or []
    system_bytes = 0
    tool_result_bytes = 0
    for message in messages:
        role = (message or {}).get("role")
        if role == "system":
            system_bytes += text_bytes(message.get("content"))
        elif role == "tool":
            tool_result_bytes += text_bytes(message.get("content"))
    tools = request.get("tools") or []
    return {
        "index": index,
        "request_bytes": byte_len(request),
        "messages_bytes": byte_len(messages),
        "system_bytes": system_bytes,
        "tools_bytes": byte_len(tools),
        "tool_count": len(tools),
        "tool_result_bytes": tool_result_bytes,
        "message_count": len(messages),
        "stream": bool(request.get("stream")),
        "ms": int(time.time() * 1000) - began_ms,
    }


def record(row):
    if not LEDGER:
        return
    with LOCK:
        with open(LEDGER, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _json(self, payload, code=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._json({"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "measuring-stub"}]})
            return
        self._json({"error": "not_found", "path": self.path}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            request = json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            request = {}
        if not self.path.rstrip("/").endswith("/chat/completions"):
            self._json({"error": "not_found", "path": self.path}, 404)
            return
        with LOCK:
            COUNT[0] += 1
            index = COUNT[0]
        began = int(time.time() * 1000)
        if SLEEP > 0:
            time.sleep(SLEEP)
        entry = SCRIPT[min(index, len(SCRIPT)) - 1]
        row = measure(request, index, began)
        row["reply"] = "tool_calls" if entry.get("tool_calls") else "content"
        row["reply_bytes"] = byte_len({"content": entry.get("content"), "tool_calls": entry.get("tool_calls")})
        row["model"] = request.get("model") or MODEL
        record(row)
        content = entry.get("content", "")
        calls = entry.get("tool_calls") or []
        if request.get("stream"):
            self._stream(content, calls)
            return
        message = {"role": "assistant", "content": content or None}
        finish = "stop"
        if calls:
            message["tool_calls"] = [
                {"id": "call_%d_%d" % (index, position), "type": "function",
                 "function": {"name": call["name"], "arguments": json.dumps(call.get("arguments") or {})}}
                for position, call in enumerate(calls)
            ]
            finish = "tool_calls"
        self._json({
            "id": "measuring-%d" % index,
            "object": "chat.completion",
            "model": request.get("model") or MODEL,
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        })

    def _stream(self, content, calls):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def event(payload):
            self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode("utf-8"))
            self.wfile.flush()

        delta = {"role": "assistant"}
        if content:
            delta["content"] = content
        if calls:
            delta["tool_calls"] = [
                {"index": position, "id": "call_%d_%d" % (COUNT[0], position), "type": "function",
                 "function": {"name": call["name"], "arguments": json.dumps(call.get("arguments") or {})}}
                for position, call in enumerate(calls)
            ]
        event({"id": "measuring", "object": "chat.completion.chunk", "model": MODEL,
               "choices": [{"index": 0, "delta": delta, "finish_reason": None}]})
        event({"id": "measuring", "object": "chat.completion.chunk", "model": MODEL,
               "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls" if calls else "stop"}]})
        event({"id": "measuring", "object": "chat.completion.chunk", "model": MODEL, "choices": [],
               "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("listening %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
