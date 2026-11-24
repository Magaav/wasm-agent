#!/usr/bin/env python3
"""A provider the node can be pointed at in a test: a fixed reply, an optional sleep, and a request count.

WHY IT EXISTS (r8a/4, Fable 24/11). Three assertions needed a model turn that could start and finish WITHOUT a real
provider and without spending money: one interruption must cost exactly ONE paid turn (one pause plus two re-arms plus
a CLI resume); r7's node-level B shape needs a turn that holds its lane for minutes; r8b needs a lane that is visibly
working while a queue waits behind it. None could be written, so each was reported as "needs a stub provider". This is
that stub, once.

HOW IT IS USED. Point the node at it and give it a key and a model, because `lua/core/provider.lua` counts a provider as
configured only when all three are set:

    WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:$PORT
    WASM_AGENT_API_KEY=stub-key   (or the provider's own key variable)
    WASM_AGENT_MODEL=stub-model

Environment:
    STUB_PORT           port to bind (default 0 = pick one and print it)
    STUB_SLEEP_SECONDS  hold each completion request this long before answering (default 0)
    STUB_COUNT_FILE     file to append one line per completion request (default: none)
    STUB_REPLY          the assistant text to answer with

It answers the OpenAI-compatible shapes the node asks for: `POST /v1/chat/completions` (streaming and not) and
`GET /v1/models`. Every completion request appends one line to STUB_COUNT_FILE, so a row can count paid turns by
counting lines - measured, not inferred.
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("STUB_PORT", "0") or 0)
SLEEP = float(os.environ.get("STUB_SLEEP_SECONDS", "0") or 0)
COUNT_FILE = os.environ.get("STUB_COUNT_FILE") or ""
REPLY = os.environ.get("STUB_REPLY") or "stub reply"
COUNT_LOCK = threading.Lock()
COUNT = [0]


def record_request():
    with COUNT_LOCK:
        COUNT[0] += 1
        n = COUNT[0]
    if COUNT_FILE:
        with open(COUNT_FILE, "a", encoding="utf-8") as fh:
            fh.write("%d\n" % n)
    return n


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet: the row reads the count file, never the stub's chatter
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
            self._json({"object": "list", "data": [{"id": os.environ.get("WASM_AGENT_MODEL", "stub-model"),
                                                       "object": "model", "owned_by": "stub"}]})
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
        n = record_request()
        if SLEEP > 0:
            time.sleep(SLEEP)
        model = request.get("model") or os.environ.get("WASM_AGENT_MODEL", "stub-model")
        if request.get("stream"):
            self._stream(model)
            return
        self._json({
            "id": "stub-%d" % n,
            "object": "chat.completion",
            "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": REPLY},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        })

    def _stream(self, model):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def event(payload):
            self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode("utf-8"))
            self.wfile.flush()

        event({"id": "stub-stream", "object": "chat.completion.chunk", "model": model,
               "choices": [{"index": 0, "delta": {"role": "assistant", "content": REPLY}, "finish_reason": None}]})
        event({"id": "stub-stream", "object": "chat.completion.chunk", "model": model,
               "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("stub-provider listening on %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
