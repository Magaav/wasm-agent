#!/usr/bin/env python3
"""The Claude subscription route, end to end, offline: /login -> wa-vault OAuth -> a turn on POST /v1/messages.

Nothing here reaches Anthropic. One local stub plays all three upstreams - the OAuth token endpoint, the
Messages API and (for the comparison turn) an OpenAI-compatible endpoint - and the REAL vault/wa_vault.py
runs in this process with its two Anthropic URLs pointed at the stub (module constants, set here: the
vault has no switch for them). Every wa process gets a scratch HOME and WASM_AGENT_HOME, and the operator's
vault variables are removed from its environment.

What it pins:
  * the vault side of pi's flow: the authorize URL (client id, scopes, S256 challenge, copy-code redirect),
    the code exchange (grant, code, state, verifier, redirect), the refresh when the access token expired,
    a refused refresh shown on the account and answered 401, several accounts and a switch with no login;
  * no answer, log or wa output ever carries a token;
  * /login lists "Anthropic (Claude subscription)" and signs in through its pages; /model lists its ids;
  * a turn through the anthropic route sends Bearer + the OAuth betas, wa's own system prompt (after the
    one reported identity prefix), and exactly one tool, run - byte-identical to what the opencode-go
    route sends for the same turn.

Usage: WA_BIN=<wa> python3 scripts/test-anthropic-subscription.py   (exit 0 = all checks passed)
"""
import base64
import hashlib
import http.client
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
checks = 0
failures = 0


def ok(condition, label):
    global checks, failures
    checks += 1
    if not condition:
        failures += 1
        print("FAIL " + label, flush=True)


TOKENS = {}            # code -> (access, refresh, email)
REFRESH = {}           # refresh token -> (access, refresh) or None (refused)
token_calls = []       # JSON bodies the token endpoint received
messages_calls = []    # (headers, body) of every /v1/messages request
chat_calls = []        # bodies of every /chat/completions request
SECRETS = set()


def secret(value):
    SECRETS.add(value)
    return value


class Stub(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def sse(self, events, openai=False):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        for event in events:
            if not openai:
                self.wfile.write(("event: " + event["type"] + "\n").encode())
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()
        if openai:
            self.wfile.write(b"data: [DONE]\n\n")
        self.close_connection = True

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/v1/oauth/token":
            token_calls.append(body)
            if body.get("grant_type") == "authorization_code" and body.get("code") in TOKENS:
                access, refresh, email = TOKENS[body["code"]]
                REFRESH.setdefault(refresh, None)
                return self.reply(200, {"access_token": access, "refresh_token": refresh, "expires_in": 3600,
                                        "account": {"email_address": email}})
            if body.get("grant_type") == "refresh_token" and REFRESH.get(body.get("refresh_token")):
                access, refresh = REFRESH[body["refresh_token"]]
                return self.reply(200, {"access_token": access, "refresh_token": refresh, "expires_in": 3600})
            return self.reply(400, {"error": "invalid_grant", "error_description": "echo " + json.dumps(body)})
        if self.path == "/v1/messages":
            messages_calls.append((dict((k.lower(), v) for k, v in self.headers.items()), body))
            if not body.get("stream"):
                return self.reply(200, {"id": "msg_1", "type": "message", "role": "assistant", "model": body.get("model"),
                                        "content": [{"type": "text", "text": "plain reply"}], "stop_reason": "end_turn",
                                        "usage": {"input_tokens": 3, "output_tokens": 2}})
            had_result = any(isinstance(block, dict) and block.get("type") == "tool_result"
                             for message in body.get("messages", []) for block in (message.get("content") or [])
                             if isinstance(message.get("content"), list))
            start = {"type": "message_start", "message": {"id": "msg_%d" % len(messages_calls), "type": "message",
                     "role": "assistant", "model": body.get("model"), "content": [],
                     "usage": {"input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 0}}}
            if not had_result:
                return self.sse([start,
                    {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_stub1", "name": "run", "input": {}}},
                    {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "{\"code\": \"return 'stub-ran' "}},
                    {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "\"}"}},
                    {"type": "content_block_stop", "index": 0},
                    {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 9}},
                    {"type": "message_stop"}])
            return self.sse([start,
                {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "stub "}},
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "answer"}},
                {"type": "content_block_stop", "index": 0},
                {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 2}},
                {"type": "message_stop"}])
        if self.path.endswith("/chat/completions"):
            chat_calls.append(body)
            return self.sse([{"choices": [{"index": 0, "delta": {"role": "assistant", "content": "stub answer"}, "finish_reason": None}]},
                             {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                              "usage": {"prompt_tokens": 1, "completion_tokens": 1}}], openai=True)
        self.reply(404, {"error": "no route " + self.path})

    def do_GET(self):
        if self.path.endswith("/models"):
            return self.reply(200, {"data": [{"id": "stub-model"}]})
        self.reply(404, {"error": "no route " + self.path})


def serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def call(port, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    payload = json.dumps(body).encode() if body is not None else None
    connection.request(method, path, body=payload, headers=dict({"Content-Type": "application/json"}, **(headers or {})))
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, data


def carries_secret(text):
    return [value for value in SECRETS if value and value in text]


def main():
    scratch = tempfile.mkdtemp(prefix="anthropic-sub-")
    try:
        return run(scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def run(scratch):
    stub = serve(Stub)
    stub_url = "http://127.0.0.1:%d" % stub.server_address[1]

    # The real vault, in this process, with its data in the scratch and its Anthropic URLs at the stub.
    os.environ["WA_VAULT_DATA"] = os.path.join(scratch, "vault-data")
    spec = importlib.util.spec_from_file_location("wa_vault_under_test", os.path.join(ROOT, "vault", "wa_vault.py"))
    vault = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vault)
    vault.ANTHROPIC_TOKEN_URL = stub_url + "/v1/oauth/token"
    vault.ANTHROPIC_BASE = stub_url
    logged = []
    vault.log = lambda message: logged.append(message)
    os.makedirs(vault.DATA_DIR, mode=0o700, exist_ok=True)
    proxy = vault.serve(0, vault.ProxyHandler, "proxy", "127.0.0.1")
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    vport = proxy.server_address[1]
    answers = []

    # ---- 1. the vault's half of pi's flow -------------------------------------------------------
    status, raw = call(vport, "POST", "/login/anthropic/start", {})
    answers.append(raw.decode())
    started = json.loads(raw)
    url = urllib.parse.urlsplit(started["url"])
    query = dict(urllib.parse.parse_qsl(url.query))
    ok(status == 200 and url.scheme + "://" + url.netloc + url.path == "https://claude.ai/oauth/authorize", "the authorize URL is pi's")
    ok(query.get("client_id") == "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "the client id is pi's")
    ok(query.get("scope") == "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload", "the scopes are pi's")
    ok(query.get("response_type") == "code" and query.get("code") == "true", "response_type=code and code=true")
    ok(query.get("redirect_uri") == "https://platform.claude.com/oauth/code/callback", "the copy-code redirect")
    ok(query.get("code_challenge_method") == "S256" and len(query.get("code_challenge", "")) == 43, "an S256 challenge")
    state = query.get("state", "")
    secret(state)

    TOKENS["code-one"] = (secret("sk-ant-oat01-ACCESS-ONE"), secret("sk-ant-ort01-REFRESH-ONE"), "one@example.com")
    status, raw = call(vport, "POST", "/login/anthropic/finish", {"code": "code-one#" + state})
    answers.append(raw.decode())
    ok(status == 200, "the pasted code#state signs in (got %d %s)" % (status, raw[:200]))
    exchange = token_calls[-1] if token_calls else {}
    ok(exchange.get("grant_type") == "authorization_code" and exchange.get("code") == "code-one"
       and exchange.get("state") == state and exchange.get("redirect_uri") == "https://platform.claude.com/oauth/code/callback"
       and exchange.get("client_id") == "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "the code exchange carries pi's fields")
    verifier = exchange.get("code_verifier", "")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    ok(challenge == query.get("code_challenge"), "the verifier sent is the one the challenge was made from")
    anthropic = json.loads(raw)["providers"]["anthropic"]
    ok(anthropic["configured"] and anthropic["active"] == "account-1" and anthropic["accounts"][0]["label"] == "one@example.com",
       "the account is signed in, active, and named by its email")
    token_file = os.path.join(vault.KEYS_DIR, "anthropic-account-1.json")
    ok(os.path.exists(token_file) and (os.stat(token_file).st_mode & 0o777) == 0o600, "the tokens are a 0600 key file in the vault")

    status, raw = call(vport, "POST", "/login/anthropic/finish", {"code": "code-one#" + state})
    ok(status == 409, "a code from a finished sign-in is refused, not replayed")

    status, raw = call(vport, "POST", "/anthropic/v1/messages", {"model": "m", "max_tokens": 1, "messages": []},
                       {"Authorization": "Bearer wa-vault-brokered", "x-api-key": "wa-vault-brokered"})
    answers.append(raw.decode())
    sent = messages_calls[-1][0] if messages_calls else {}
    ok(status == 200 and sent.get("authorization") == "Bearer sk-ant-oat01-ACCESS-ONE", "the vault sets the Bearer token")
    ok("x-api-key" not in sent and "wa-vault-brokered" not in json.dumps(sent), "the placeholder never reaches the upstream")

    # Expired: the next use refreshes first, with pi's refresh grant, and uses the new token.
    REFRESH["sk-ant-ort01-REFRESH-ONE"] = (secret("sk-ant-oat01-ACCESS-ONE-B"), secret("sk-ant-ort01-REFRESH-ONE-B"))
    tokens = json.load(open(token_file))
    tokens["expires"] = 1
    json.dump(tokens, open(token_file, "w"))
    status, raw = call(vport, "POST", "/anthropic/v1/messages", {"model": "m", "max_tokens": 1, "messages": []})
    ok(token_calls[-1] == {"grant_type": "refresh_token", "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                           "refresh_token": "sk-ant-ort01-REFRESH-ONE"}, "an expired token is refreshed with pi's grant")
    ok(status == 200 and messages_calls[-1][0].get("authorization") == "Bearer sk-ant-oat01-ACCESS-ONE-B", "the refreshed token is used")
    ok(json.load(open(token_file))["refresh"] == "sk-ant-ort01-REFRESH-ONE-B", "the new refresh token replaces the old one")

    # A second account; switching back and forth needs no login.
    status, raw = call(vport, "POST", "/login/anthropic/start", {})
    state2 = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(json.loads(raw)["url"]).query))["state"]
    secret(state2)
    TOKENS["code-two"] = (secret("sk-ant-oat01-ACCESS-TWO"), secret("sk-ant-ort01-REFRESH-TWO"), "two@example.com")
    status, raw = call(vport, "POST", "/login/anthropic/finish", {"code": "https://platform.claude.com/oauth/code/callback?code=code-two&state=" + state2})
    anthropic = json.loads(raw)["providers"]["anthropic"]
    ok(status == 200 and anthropic["active"] == "account-2" and len(anthropic["accounts"]) == 2, "a second account signs in beside the first")
    status, raw = call(vport, "POST", "/login/anthropic/use", {"account": "account-1"})
    ok(status == 200 and json.loads(raw)["providers"]["anthropic"]["active"] == "account-1", "switching the active account needs no login")
    call(vport, "POST", "/anthropic/v1/messages", {"model": "m", "max_tokens": 1, "messages": []})
    ok(messages_calls[-1][0].get("authorization") == "Bearer sk-ant-oat01-ACCESS-ONE-B", "the switched-to account's token is used")
    ok(json.load(open(vault.STORE_PATH))["anthropic"]["active"] == "account-1", "the choice persists in the vault store")

    # A refused refresh: shown on the account, answered 401, nothing sent upstream.
    REFRESH["sk-ant-ort01-REFRESH-ONE-B"] = None
    tokens = json.load(open(token_file))
    tokens["expires"] = 1
    json.dump(tokens, open(token_file, "w"))
    before = len(messages_calls)
    status, raw = call(vport, "POST", "/anthropic/v1/messages", {"model": "m", "max_tokens": 1, "messages": []})
    answers.append(raw.decode())
    ok(status == 401 and json.loads(raw)["error"]["code"] == "vault_credential_refused" and len(messages_calls) == before,
       "a refused refresh is a 401 that asks for a new sign-in, and nothing is sent")
    status, raw = call(vport, "GET", "/status")
    answers.append(raw.decode())
    anthropic = json.loads(raw)["providers"]["anthropic"]
    ok(bool(anthropic.get("refused")) and "invalid_grant" in anthropic["refused"] and "echo" not in anthropic["refused"],
       "the refusal shows on the status as a short word, never the endpoint's body")
    status, raw = call(vport, "POST", "/login/anthropic/use", {"account": "account-2"})
    ok(status == 200, "switch to the healthy account")

    # ---- 2. wa: /login, /model and a turn --------------------------------------------------------
    binary = os.environ.get("WA_BIN") or shutil.which("wa")
    if not binary:
        print("FAIL no wa binary (set WA_BIN)")
        return 1
    home = os.path.join(scratch, "home")
    os.makedirs(os.path.join(home, ".wasm-agent"))
    base_env = {k: v for k, v in os.environ.items()
                if not k.startswith("WASM_AGENT_") and not k.startswith("WA_VAULT") and k not in ("OPENAI_API_KEY", "OPENCODE_GO_API_KEY")}
    base_env.update({"HOME": home, "WASM_AGENT_HOME": home, "WASM_AGENT_LUA_ROOT": ROOT,
                     "WASM_AGENT_RENDEZVOUS": "", "WASM_AGENT_RELAY": "", "WASM_AGENT_DB": "",
                     "WASM_AGENT_PI_MODELS_STORE": os.path.join(scratch, "no-pi-store.json")})
    vaulted = dict(base_env, WASM_AGENT_VAULT_URL="http://127.0.0.1:%d" % vport)

    TOKENS["code-three"] = (secret("sk-ant-oat01-ACCESS-THREE"), secret("sk-ant-ort01-REFRESH-THREE"), "three@example.com")
    lua = subprocess.run([binary, "--db", os.path.join(scratch, "login.db")], cwd=ROOT, capture_output=True, text=True, timeout=120,
                         env=dict(vaulted, WA_SCRIPT=os.path.join(ROOT, "scripts", "lib", "anthropic-subscription-login.lua")))
    out = lua.stdout + lua.stderr
    print(out.strip().splitlines()[-1] if out.strip() else "(the /login row printed nothing)")
    ok(lua.returncode == 0, "the /login and /model row passes:\n" + out[-3000:])
    ok(not carries_secret(out.replace(state, "").replace(state2, "")), "the /login row never prints a token")

    def turn(env, label):
        done = subprocess.run([binary, "chat", "--once", "--offline", "say hi", "--db", os.path.join(scratch, label + ".db")],
                              cwd=ROOT, capture_output=True, text=True, timeout=180, env=env)
        return done.returncode, done.stdout + done.stderr

    before = len(messages_calls)
    # The same node the /login row signed in on: its provider and model choice must persist to this run.
    code, out = turn(vaulted, "login")
    turns = messages_calls[before:]
    ok(code == 0 and len(turns) == 2, "one turn = a run call and its answer, two requests (got %d, exit %d):\n%s" % (len(turns), code, out[-2000:]))
    ok("stub answer" in out, "the streamed answer reaches the chat")
    ok(not carries_secret(out.replace(state, "").replace(state2, "")), "the turn never prints a token")
    if turns:
        headers, body = turns[0]
        betas = [b.strip() for b in headers.get("anthropic-beta", "").split(",")]
        ok(headers.get("authorization") == "Bearer sk-ant-oat01-ACCESS-THREE", "the turn carries the active account's Bearer (set by the vault)")
        ok("claude-code-20250219" in betas and "oauth-2025-04-20" in betas, "the turn carries the OAuth betas: " + str(betas))
        ok(headers.get("anthropic-version") == "2023-06-01", "the anthropic-version header")
        ok(headers.get("user-agent", "").startswith("claude-cli/") and headers.get("x-app") == "cli", "pi's client identity headers")
        ok(body.get("model") == "claude-opus-5-5" and body.get("stream") is True, "the model /model picked, streamed (got %s, %s)" % (body.get("model"), body.get("stream")))
        system = body.get("system") or []
        ok(len(system) == 2 and system[0]["text"] == "You are Claude Code, Anthropic's official CLI for Claude.",
           "the one reported prefix, then wa's prompt")
        ok([tool["name"] for tool in body.get("tools") or []] == ["run"], "exactly one tool, run")
        second = turns[-1][1]["messages"] if len(turns) > 1 else []
        results = [block for message in second for block in (message["content"] if isinstance(message["content"], list) else [])
                   if block.get("type") == "tool_result"]
        ok(len(results) == 1 and results[0]["tool_use_id"] == "toolu_stub1", "the run result goes back as the tool_result of that call")
        uses = [block for message in second if message["role"] == "assistant" for block in message["content"] if block.get("type") == "tool_use"]
        ok(len(uses) == 1 and uses[0]["input"] == {"code": "return 'stub-ran' "}, "the call is replayed as the model wrote it")

        # Caching: both rounds carry pi's breakpoints, and round 2 repeats round 1 up to round 1's last one.
        def marked(block):
            return isinstance(block, dict) and block.get("cache_control") == {"type": "ephemeral"}

        def breakpoints(request):
            where = ["system[%d]" % i for i, block in enumerate(request.get("system") or []) if marked(block)]
            where += ["tools[%d]" % i for i, tool in enumerate(request.get("tools") or []) if marked(tool)]
            for m, message in enumerate(request.get("messages") or []):
                for b, block in enumerate(message["content"] if isinstance(message["content"], list) else []):
                    if marked(block):
                        where.append("messages[%d][%d]" % (m, b))
            return where

        def unmarked(value):
            if isinstance(value, dict):
                return {k: unmarked(v) for k, v in value.items() if k != "cache_control"}
            if isinstance(value, list):
                return [unmarked(v) for v in value]
            return value

        def canonical(value):
            return json.dumps(unmarked(value), sort_keys=True, separators=(",", ":"))

        if len(turns) > 1:
            one, two = turns[0][1], turns[1][1]
            last_one = "messages[%d][%d]" % (len(one["messages"]) - 1, len(one["messages"][-1]["content"]) - 1)
            last_two = "messages[%d][%d]" % (len(two["messages"]) - 1, len(two["messages"][-1]["content"]) - 1)
            ok(breakpoints(one) == ["system[0]", "system[1]", "tools[0]", last_one], "round 1 breakpoints: " + str(breakpoints(one)))
            ok(breakpoints(two) == ["system[0]", "system[1]", "tools[0]", last_two] and last_two != last_one,
               "round 2 breakpoints move forward: " + str(breakpoints(two)))
            n = len(one["messages"])
            ok(canonical(one["tools"]) == canonical(two["tools"]) and canonical(one["system"]) == canonical(two["system"])
               and canonical(one["messages"]) == canonical(two["messages"][:n]),
               "round 2 is byte-identical to round 1 up to round 1's last breakpoint (tools, system, messages[0..%d])" % (n - 1))

        # The same turn on opencode-go: the model must see the same system prompt and the same tool.
        go_env = dict(base_env, WASM_AGENT_PROVIDER="opencode-go", WASM_AGENT_LLM_BASE_URL=stub_url + "/go/v1",
                      WASM_AGENT_LLM_API_KEY="stub-key")
        go_home = os.path.join(scratch, "home-go")
        os.makedirs(os.path.join(go_home, ".wasm-agent"))
        go_env.update({"HOME": go_home, "WASM_AGENT_HOME": go_home})
        code, out = turn(go_env, "turn-go")
        ok(code == 0 and chat_calls, "the comparison turn on opencode-go ran:\n" + out[-1500:])
        if chat_calls and len(system) == 2:
            go = chat_calls[0]
            ok(go["messages"][0]["role"] == "system" and go["messages"][0]["content"] == system[1]["text"],
               "the system prompt is byte-identical to the opencode-go turn's")
            tool = (body.get("tools") or [{}])[0]
            go_tool = go["tools"][0]["function"]
            ok(len(go["tools"]) == 1 and tool.get("name") == go_tool["name"] and tool.get("description") == go_tool["description"]
               and tool.get("input_schema") == go_tool["parameters"], "the run tool is byte-identical to the opencode-go turn's")

    everything = "\n".join(answers + logged)
    ok(not carries_secret(everything.replace(state, "").replace(state2, "")), "no vault answer or log line carries a token")
    print("anthropic subscription: %d checks, %d failed" % (checks, failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
