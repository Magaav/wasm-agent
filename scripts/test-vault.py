#!/usr/bin/env python3
"""wa-vault, offline: the agent can use a stored credential and cannot read one back.

Runs the real vault/wa_vault.py as a child process against local fake upstreams (opencode, chatgpt,
auth.openai.com) and asserts, from the outside, what the boundary claims:

  * a stored key/token reaches the upstream, and the node's placeholder never does;
  * no endpoint on either listener returns a stored value (status, admin API, errors, 404s);
  * the admin API refuses without the token; the proxy refuses paths outside its routes;
  * SSE is streamed through; a hard-expired token is refreshed once for N concurrent requests;
  * the device-code login stores a credential that the next request uses.

Usage: python3 scripts/test-vault.py   (exit 0 = all checks passed)
"""

import base64
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import importlib.util
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADMIN_TOKEN = "t" * 40
OPENCODE_KEY = "sk-opencode-SECRET-0123456789"
REPLACEMENT_KEY = "sk-opencode-SECRET-replacement-5555"
REFRESH_1 = "rt-SECRET-first"
REFRESH_2 = "rt-SECRET-second"

checks = 0
failures = 0


def ok(condition, label):
    global checks, failures
    checks += 1
    if not condition:
        failures += 1
        print("FAIL " + label)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def jwt(account, marker):
    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b"=").decode()
    return part({"alg": "none"}) + "." + part({"https://api.openai.com/auth": {"chatgpt_account_id": account},
                                                "m": marker}) + ".sig"


ACCESS_1 = jwt("acct-123", "SECRET-access-1")
ACCESS_2 = jwt("acct-123", "SECRET-access-2")
SECRETS = [OPENCODE_KEY, REPLACEMENT_KEY, REFRESH_1, REFRESH_2, ACCESS_1, ACCESS_2, ADMIN_TOKEN]

seen = []          # (path, headers) of every upstream request
refreshes = []     # refresh_token values the fake auth server received
reject_refresh = False
device_polls = []


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, value, content_type="application/json"):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        seen.append((self.path, dict(self.headers)))
        if self.path == "/go/v1/models":
            return self.reply(200, {"data": [{"id": "m1"}, {"id": "m2"}]})
        if self.path == "/backend/wham/usage":
            return self.reply(200, {"rate_limits": {}})
        if self.path == "/backend/codex/redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/steal")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.reply(404, {"error": "nope"})

    def do_POST(self):
        payload = self.body()
        seen.append((self.path, dict(self.headers)))
        if self.path == "/go/v1/chat/completions":
            return self.reply(200, {"echo": json.loads(payload or b"{}")})
        if self.path == "/backend/codex/responses":
            # Streamed in pieces, so a buffering proxy would show up as one late write.
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for index in range(3):
                self.wfile.write(("data: {\"n\": %d}\n\n" % index).encode())
                self.wfile.flush()
                time.sleep(0.05)
            self.close_connection = True
            return
        if self.path == "/auth/oauth/token":
            form = dict(pair.split("=", 1) for pair in payload.decode().split("&"))
            if form.get("grant_type") == "refresh_token":
                refreshes.append(form.get("refresh_token"))
                time.sleep(0.2)  # long enough for concurrent callers to pile up behind the lock
                if reject_refresh:
                    return self.reply(401,{"error":"rejected " + REFRESH_1})
                return self.reply(200, {"access_token": ACCESS_2, "refresh_token": REFRESH_2, "expires_in": 3600})
            if form.get("grant_type") == "authorization_code":
                return self.reply(200, {"access_token": ACCESS_1, "refresh_token": REFRESH_1, "expires_in": -1})
        if self.path == "/auth/api/accounts/deviceauth/usercode":
            return self.reply(200, {"device_auth_id": "dev-1", "user_code": "ABCD-1234", "interval": "0"})
        if self.path == "/auth/api/accounts/deviceauth/token":
            device_polls.append(1)
            if len(device_polls) < 2:
                return self.reply(403, {"error": {"code": "deviceauth_authorization_pending"}})
            return self.reply(200, {"authorization_code": "code-1", "code_verifier": "ver-1"})
        self.reply(404, {"error": "nope"})


def request(port, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
    connection.request(method, path, body=data, headers=headers or {})
    response = connection.getresponse()
    payload = response.read()
    connection.close()
    return response.status, payload


def admin(method, path, body=None, token=ADMIN_TOKEN):
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["X-Vault-Token"] = token
    if path == '/api/opencode-go/key' and method in ('POST','DELETE') and token == ADMIN_TOKEN and (body is None or isinstance(body,dict)):
        generation = json.loads(request(ADMIN,'GET','/api/status',headers=headers)[1])['providers']['opencode-go']['generation']
        body = dict(body or {}, expected_generation=generation, operation=str(uuid.uuid4()))
    if path == '/api/openai-sub/login' and method=='POST' and token==ADMIN_TOKEN:
        generation=json.loads(request(ADMIN,'GET','/api/status',headers=headers)[1])['providers']['openai-sub']['generation']
        body=dict(body or {},expected_generation=generation)
    if path == '/api/openai-sub/login' and method=='DELETE' and token==ADMIN_TOKEN:
        login=json.loads(request(ADMIN,'GET','/api/status',headers=headers)[1])['login']
        body=dict(body or {},operation=login.get('operation','no-pending-operation'))
    return request(ADMIN, method, path, body, headers)


def no_secret(payload, label):
    text = payload.decode("utf-8", "replace") if isinstance(payload, bytes) else str(payload)
    ok(not any(secret in text for secret in SECRETS), label + " carries no stored value")


upstream_port = free_port()
upstream = ThreadingHTTPServer(("127.0.0.1", upstream_port), Upstream)
threading.Thread(target=upstream.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d" % upstream_port

PROXY, ADMIN = free_port(), free_port()
data_dir = tempfile.mkdtemp(prefix="wa-vault-test-")
env = dict(os.environ, WA_VAULT_ADMIN_TOKEN=ADMIN_TOKEN, WA_VAULT_DATA=data_dir,
           WA_VAULT_PROXY_PORT=str(PROXY), WA_VAULT_ADMIN_PORT=str(ADMIN), WA_VAULT_BIND="127.0.0.1",
           WA_VAULT_OPENCODE_BASE=base + "/go/v1", WA_VAULT_CHATGPT_BASE=base + "/backend",
           WA_VAULT_AUTH_BASE=base + "/auth", PYTHONDONTWRITEBYTECODE="1")
log_file = tempfile.TemporaryFile()
child = subprocess.Popen([sys.executable, os.path.join(ROOT, "vault", "wa_vault.py")], env=env,
                         stdout=log_file, stderr=subprocess.STDOUT)
try:
    for _ in range(100):
        try:
            request(PROXY, "GET", "/status")
            request(ADMIN, "GET", "/")
            break
        except OSError:
            time.sleep(0.05)

    # --- refuses to start without a real admin token
    weak = subprocess.run([sys.executable, os.path.join(ROOT, "vault", "wa_vault.py")],
                          env=dict(env, WA_VAULT_ADMIN_TOKEN="short", WA_VAULT_PROXY_PORT=str(free_port()),
                                   WA_VAULT_ADMIN_PORT=str(free_port())), capture_output=True, timeout=10)
    ok(weak.returncode == 2, "a short admin token is refused at start")

    # --- nothing configured: clear refusals, no upstream call
    status, payload = request(PROXY, "POST", "/opencode-go/v1/chat/completions", {"model": "m"},
                              {"Authorization": "Bearer wa-vault-brokered"})
    ok(status == 401 and b"vault_credential_absent" in payload, "absent key is a 401 naming the vault page")
    ok(not seen, "an absent key makes no upstream call")

    # --- the admin API needs the token
    for method, path in (("GET", "/api/status"), ("POST", "/api/opencode-go/key"), ("DELETE", "/api/openai-sub")):
        status, _ = admin(method, path, {"key": "x"}, token=None)
        ok(status == 401, "%s %s without the token is refused" % (method, path))
        status, _ = admin(method, path, {"key": "x"}, token="wrong" * 10)
        ok(status == 401, "%s %s with a wrong token is refused" % (method, path))
    status, payload = admin("GET", "/")
    ok(status == 200 and b"wa-vault" in payload, "the page itself is served")

    # --- store the opencode key; it is used and never returned
    status, payload = admin("POST", "/api/opencode-go/key", {"key": " " + OPENCODE_KEY + " "})
    ok(status == 200 and json.loads(payload)["providers"]["opencode-go"]["configured"], "the key is stored")
    no_secret(payload, "the store answer")
    status, payload = admin("POST", "/api/opencode-go/key", {"key": "two words"})
    ok(status == 400, "a key with whitespace inside is refused")
    with open(os.path.join(data_dir, "vault.json")) as handle:
        ok(OPENCODE_KEY in handle.read(), "the store holds the trimmed key")
    if os.name == "posix":
        ok(os.stat(os.path.join(data_dir, "vault.json")).st_mode & 0o777 == 0o600, "the store is mode 600")
    else:
        print("SKIP Unix mode enforcement on Windows; fixture does not prove ACL isolation")

    seen.clear()
    status, payload = request(PROXY, "POST", "/opencode-go/v1/chat/completions", {"model": "m1"}, {
        "Authorization": "Bearer wa-vault-brokered", "Content-Type": "application/json",
        "x-opencode-session": "sess-1", "Host": "evil.example", "X-Forwarded-Host": "evil.example",
        "Cookie": "c=1"})
    ok(status == 200 and json.loads(payload)["echo"]["model"] == "m1", "a request reaches opencode through the vault")
    path, headers = seen[-1]
    lower = {k.lower(): v for k, v in headers.items()}
    ok(lower.get("authorization") == "Bearer " + OPENCODE_KEY, "the upstream receives the stored key")
    ok("wa-vault-brokered" not in json.dumps(headers), "the placeholder never reaches the upstream")
    ok(lower.get("x-opencode-session") == "sess-1", "the session header is forwarded")
    ok(lower.get("host", "").startswith("127.0.0.1"), "the caller's Host header is not forwarded")
    ok("x-forwarded-host" not in lower and "cookie" not in lower, "forwarding/cookie headers are dropped")
    no_secret(payload, "the proxied answer")

    status, payload = admin("POST", "/api/opencode-go/test")
    ok(status == 200 and json.loads(payload)["test"]["ok"] and "2 models" in json.loads(payload)["test"]["detail"],
       "the admin test calls the upstream with the stored key")
    no_secret(payload, "the test answer")

    # --- generation CAS, operator origin and pinned-request refusal
    current=json.loads(admin('GET','/api/status')[1])['providers']['opencode-go']
    raw_headers={'X-Vault-Token':ADMIN_TOKEN,'Content-Type':'application/json'}
    stale={'key':'synthetic-replacement','expected_generation':'absent','operation':str(uuid.uuid4())}
    status,payload=request(ADMIN,'POST','/api/opencode-go/key',stale,raw_headers)
    ok(status==409,'stale operator save refused')
    status,_=request(ADMIN,'POST','/api/opencode-go/key',dict(stale,expected_generation=current['generation']),dict(raw_headers,Origin='http://evil.invalid'))
    ok(status==401,'foreign origin refused even with token')
    status,_=request(ADMIN,'POST','/api/opencode-go/key',dict(stale,expected_generation=current['generation']),dict(raw_headers,**{'X-Vault-Instance':'wrong-vault'}))
    ok(status==401,'foreign vault identity refused even with token')
    proxy_identity=json.loads(request(PROXY,'GET','/status')[1])['vault_id']
    ok(json.loads(request(ADMIN,'GET','/identity')[1])['vault_id']==proxy_identity,'proxy/operator public identity binds the same durable vault')
    before_count=len(seen)
    status,_=request(PROXY,'POST','/opencode-go/v1/chat/completions',{'model':'m1'},{'X-Wa-Vault-Generation':'stale'})
    ok(status==409 and len(seen)==before_count,'pinned stale generation sends nothing upstream')
    operation=str(uuid.uuid4())
    status,payload=request(ADMIN,'POST','/api/opencode-go/key',dict(stale,key=REPLACEMENT_KEY,expected_generation=current['generation'],operation=operation),raw_headers)
    after=json.loads(admin('GET','/api/status')[1])['providers']['opencode-go']
    ok(status==200 and after['operation']==operation and after['generation']!=current['generation'],'exact operation/generation readback reconciles commit')
    old_count=len(seen)
    stale_status,_=request(PROXY,'POST','/opencode-go/v1/chat/completions',{'model':'m1'},{'X-Wa-Vault-Generation':current['generation']})
    ok(stale_status==409 and len(seen)==old_count,'old pinned generation cannot send with replacement account')
    updated_status,updated_payload=request(PROXY,'POST','/opencode-go/v1/chat/completions',{'model':'m1'},{'Authorization':'Bearer wa-vault-brokered','X-Wa-Vault-Generation':after['generation']})
    ok(updated_status==200 and seen[-1][1].get('Authorization')=='Bearer '+REPLACEMENT_KEY,'subsequent request uses the new operator key at fake upstream')
    no_secret(updated_payload,'updated Go response')
    status,_=request(ADMIN,'POST','/api/opencode-go/key',dict(stale,expected_generation=current['generation']),raw_headers)
    ok(status==409,'concurrent loser cannot overwrite winner')
    no_secret(payload,'CAS response')

    # --- no read path, anywhere
    for port, method, path in ((PROXY, "GET", "/status"), (PROXY, "GET", "/opencode-go/key"),
                               (PROXY, "GET", "/api/status"), (PROXY, "GET", "/openai-sub/accounts/me"),
                               (PROXY, "GET", "/opencode-go/v1/../../../data/vault.json"),
                               (ADMIN, "GET", "/api/opencode-go/key"), (ADMIN, "GET", "/vault.json"),
                               (ADMIN, "GET", "/../vault.json")):
        status, payload = request(port, method, path, headers={"X-Vault-Token": ADMIN_TOKEN})
        no_secret(payload, "%s :%s %s" % (method, "proxy" if port == PROXY else "admin", path))
    status, payload = admin("GET", "/api/status")
    no_secret(payload, "the admin status")
    status, _ = request(PROXY, "GET", "/openai-sub/accounts/me")
    ok(status == 404, "the subscription route refuses paths outside codex/ and wham/usage")
    status, _ = request(PROXY, "GET", "/opencode-go/v1/../../backend/wham/usage")
    ok(status == 404, "a dot-dot path is refused")

    # --- disable / enable
    admin("POST", "/api/opencode-go/enabled", {"enabled": False})
    status, payload = request(PROXY, "GET", "/opencode-go/v1/models")
    ok(status == 403 and b"vault_provider_disabled" in payload, "a disabled provider is refused")
    admin("POST", "/api/opencode-go/enabled", {"enabled": True})
    status, _ = request(PROXY, "GET", "/opencode-go/v1/models")
    ok(status == 200, "re-enabled, it works again")
    status, payload = request(PROXY, "GET", "/status")
    state = json.loads(payload)["providers"]
    ok(state["opencode-go"]["configured"] and not state["openai-sub"]["configured"], "/status reports presence only")

    # --- openai-sub: device login, then an expired token is refreshed once for many callers
    status, payload = admin("POST", "/api/openai-sub/login")
    login = json.loads(payload)["login"]
    ok(status == 200 and login["user_code"] == "ABCD-1234" and login["verification_url"].endswith("/codex/device"),
       "the device login shows the code and the URL")
    for _ in range(100):
        state = json.loads(admin("GET", "/api/status")[1])
        if state["login"].get("state") != "pending":
            break
        time.sleep(0.1)
    ok(state["login"].get("state") == "done" and state["providers"]["openai-sub"]["configured"],
       "the device login completes and stores a credential")
    ok(state["providers"]["openai-sub"]["account"] == "acct-123", "the account id is shown")
    no_secret(json.dumps(state), "the status after login")

    seen.clear()
    results = []

    def call():
        results.append(request(PROXY, "GET", "/openai-sub/wham/usage", headers={
            "Authorization": "Bearer wa-vault-brokered", "chatgpt-account-id": "wa-vault-brokered"})[0])
    threads = [threading.Thread(target=call) for _ in range(5)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    ok(results == [200] * 5, "five concurrent requests with an expired token all succeed")
    ok(refreshes == [REFRESH_1], "one refresh POST for five concurrent callers (got %d)" % len(refreshes))
    usage_headers = [{k.lower(): v for k, v in h.items()} for p, h in seen if p == "/backend/wham/usage"]
    ok(all(h.get("authorization") == "Bearer " + ACCESS_2 for h in usage_headers), "the refreshed token is used")
    ok(all(h.get("chatgpt-account-id") == "acct-123" for h in usage_headers), "the real account id replaces the placeholder")

    # --- SSE streams through
    connection = http.client.HTTPConnection("127.0.0.1", PROXY, timeout=30)
    connection.request("POST", "/openai-sub/codex/responses", body=b"{}", headers={"Content-Type": "application/json"})
    response = connection.getresponse()
    started = time.monotonic()
    first = response.read1(4096)
    first_at = time.monotonic() - started
    rest = response.read()
    connection.close()
    stream = first + rest
    ok(response.status == 200 and stream.count(b"data:") == 3, "the SSE stream arrives whole")
    ok(b"data: {\"n\": 0}" in first and first_at < 0.1, "the first event arrives before the stream ends")

    # --- redirects are not followed (they would carry the credential elsewhere)
    before = len(seen)
    status, _ = request(PROXY, "GET", "/openai-sub/codex/redirect")
    ok(status == 404 and len(seen) == before, "an unallowlisted redirect endpoint is refused before upstream")
    for path in ("/openai-sub/codex/responses/extra", "/openai-sub/codex/%72esponses",
                 "/openai-sub/codex/../wham/usage", "/opencode-go/v1/%2e%2e/keys",
                 "/opencode-go/v1//models", "/opencode-go/v1/./models"):
        status, _ = request(PROXY, "GET", path)
        ok(status == 404 and len(seen) == before, "allowlist refuses " + path)
    status, payload = request(PROXY, "POST", "/opencode-go/v1/chat/completions", b"", {"Content-Length": str(8 * 1024 * 1024 + 1)})
    ok(status == 413 and b"vault_body_too_large" in payload and len(seen) == before, "oversized body refused before credential use")

    # --- the CLI's door (/login on the proxy side): no token, write-only, never a value
    status, payload = request(PROXY, "POST", "/login/opencode-go", {"key": "sk-opencode-SECRET-cli-9999"},
                              {"Content-Type": "application/json"})
    SECRETS.append("sk-opencode-SECRET-cli-9999")
    ok(status == 409 and b"vault_key_exists" in payload, "/login cannot replace an existing key")
    no_secret(payload, "the /login store answer")
    seen.clear()
    request(PROXY, "GET", "/opencode-go/v1/models")
    ok({k.lower(): v for k, v in seen[-1][1].items()}.get("authorization") == "Bearer " + REPLACEMENT_KEY,
       "the operator replacement key remains after refused node replacement")
    admin("DELETE", "/api/opencode-go/key")
    status, payload = request(PROXY, "POST", "/login/opencode-go", {"key": ""}, {"Content-Type": "application/json"})
    ok(status == 400, "/login refuses an empty first key")
    status, payload = request(PROXY, "POST", "/login/opencode-go", {"key": "sk-opencode-SECRET-cli-9999"}, {"Content-Type": "application/json"})
    ok(status == 200, "/login can store a first key after operator removal")
    no_secret(payload, "the first-key store answer")
    status, payload = request(PROXY, "POST", "/login/opencode-go", {"key": ""}, {"Content-Type": "application/json"})
    ok(status == 400, "/login rejects an empty key without changing the store")
    for method, path in (("GET", "/login"), ("GET", "/login/opencode-go"), ("GET", "/login/openai-sub")):
        status, payload = request(PROXY, method, path)
        no_secret(payload, "%s %s" % (method, path))
    status, _ = request(PROXY, "DELETE", "/login/opencode-go")
    ok(status == 404, "/login cannot delete a key (that stays on the admin page)")
    device_polls.clear()
    status, payload = request(PROXY, "POST", "/login/openai-sub")
    ok(status == 409, "node-side device login cannot replace stored credentials")
    admin("DELETE", "/api/openai-sub")
    status, payload = request(PROXY, "POST", "/login/openai-sub")
    ok(status == 200 and json.loads(payload)["login"]["user_code"] == "ABCD-1234", "/login starts the device login")
    for _ in range(100):
        state = json.loads(request(PROXY, "GET", "/login")[1])
        if state["login"].get("state") != "pending":
            break
        time.sleep(0.1)
    ok(state["login"].get("state") == "done", "the device login started from /login completes")
    no_secret(json.dumps(state), "the /login state after login")
    status, payload = request(PROXY, "DELETE", "/login/openai-sub")
    ok(status == 409, "node-side cancellation cannot manage a configured operator login")

    # --- failed rotation is held, not replayed; provider errors cannot echo credentials
    reject_refresh = True
    admin("DELETE", "/api/openai-sub")
    admin("POST", "/api/openai-sub/login")
    for _ in range(100):
        state=json.loads(admin("GET", "/api/status")[1])
        if state["login"].get("state") != "pending": break
        time.sleep(0.1)
    before_refresh=len(refreshes)
    status,payload=request(PROXY,"GET","/openai-sub/wham/usage")
    ok(status==401 and len(refreshes)==before_refresh+1,"one rejected refresh dispatch")
    no_secret(payload,"rejected refresh response")
    status,payload=request(PROXY,"GET","/openai-sub/wham/usage")
    ok(status==409 and len(refreshes)==before_refresh+1,"rejected refresh cannot earn automatic replay")
    no_secret(admin("GET","/api/status")[1],"held-refresh status")
    status,_=admin("POST","/api/opencode-go/key",[])
    ok(status==400,"admin JSON must be an object")
    admin("DELETE", "/api/opencode-go/key")
    first_results=[]
    barrier=threading.Barrier(2)
    def first_login():
        barrier.wait()
        first_results.append(request(PROXY,"POST","/login/opencode-go",{"key":OPENCODE_KEY})[0])
    first_threads=[threading.Thread(target=first_login) for _ in range(2)]
    for t in first_threads: t.start()
    for t in first_threads: t.join()
    ok(sorted(first_results)==[200,409],"concurrent first-key login has exactly one mutation")

    # --- migration runs only with private synthetic files and real fixture HTTP
    spec=importlib.util.spec_from_file_location('migration',os.path.join(ROOT,'scripts','migrate-go-vault.py'))
    migration=importlib.util.module_from_spec(spec);spec.loader.exec_module(migration)
    with tempfile.TemporaryDirectory(prefix='wa-migration-fixture-') as directory:
        from pathlib import Path
        source=Path(directory)/'env';journal=Path(directory)/'journal.json'
        source.write_text('OPENCODE_GO_API_KEY='+OPENCODE_KEY+'\nUNRELATED=keep\nWASM_AGENT_OPENAI_SUB_VAULT_URL=native\n',encoding='utf-8')
        args=argparse.Namespace(env_file=str(source),vault_url='http://127.0.0.1:'+str(PROXY),admin_url='http://127.0.0.1:'+str(ADMIN),journal=str(journal),node_url=None,confirm_go_source=True,check=True,apply=False,reconcile=False)
        check=migration.execute(args,environ={})
        ok(check['variable']=='OPENCODE_GO_API_KEY' and check['present'],'migration check reports effective variable without values')
        no_secret(json.dumps(check),'migration check')
        args.check=False;args.apply=True
        real_request=migration.request
        def foreign_identity(url,*a,**kw):
            if url.endswith('/identity'): return {'vault_id':'foreign-vault'}
            return real_request(url,*a,**kw)
        try: migration.execute(args,environ={},token=ADMIN_TOKEN,http=foreign_identity);blocked=False
        except ValueError: blocked=True
        ok(blocked and not journal.exists(),'foreign operator vault identity refuses migration before any credential write')
        try: migration.execute(args,environ={},token=ADMIN_TOKEN);blocked=False
        except ValueError: blocked=True
        ok(blocked and not journal.exists(),'migration refuses an already configured vault without overwrite')
        admin('DELETE','/api/opencode-go/key')
        original_http=migration.request
        def ambiguous_http(url,*a,**kw):
            result=original_http(url,*a,**kw)
            if url.endswith('/api/opencode-go/key') and a and a[0]=='POST': raise OSError('synthetic lost write response')
            return result
        try: migration.execute(args,environ={},token=ADMIN_TOKEN,http=ambiguous_http);unknown=False
        except OSError: unknown=True
        ok(unknown and json.loads(journal.read_text())['phase']=='sending' and OPENCODE_KEY in source.read_text() and 'WASM_AGENT_OPENCODE_GO_VAULT_URL=' not in source.read_text(),'unknown credential write retains legacy source and has durable no-replay journal')
        args.apply=False;args.reconcile=True
        try: migration.execute(args,environ={},token=ADMIN_TOKEN);held=False
        except ValueError: held=True
        ok(held,'reconciliation requires effective node routing before retirement')
        ok(OPENCODE_KEY in source.read_text() and 'WASM_AGENT_OPENCODE_GO_VAULT_URL=' in source.read_text(),'apply retains plaintext until node route readback')
        no_secret(journal.read_text(),'migration journal')
        record=json.loads(journal.read_text())
        args.apply=False;args.reconcile=True;args.node_url='http://127.0.0.1:1'
        original=migration.request
        def wrong_route(url,*a,**kw):
            if url.startswith(args.node_url): return {'providers':[{'id':'opencode-go','source':'vault','vault_url':args.vault_url,'generation':'stale'}]}
            return original(url,*a,**kw)
        try: migration.execute(args,environ={},token=ADMIN_TOKEN,http=wrong_route);held=False
        except ValueError: held=True
        ok(held and OPENCODE_KEY in source.read_text(),'wrong node generation cannot retire legacy entry')
        def route_http(url,*a,**kw):
            if url.startswith(args.node_url): return {'providers':[{'id':'opencode-go','source':'vault','vault_url':args.vault_url,'vault_id':record['vault_id'],'generation':record['generation']}]}
            return original(url,*a,**kw)
        retired=migration.execute(args,environ={},token=ADMIN_TOKEN,http=route_http)
        ok(OPENCODE_KEY not in source.read_text() and 'UNRELATED=keep' in source.read_text() and 'WASM_AGENT_OPENAI_SUB_VAULT_URL=native' in source.read_text(),'retirement follows exact node route/generation and preserves unrelated/native subscription config')
        drift=Path(directory)/'drift.env';drift_journal=Path(directory)/'drift-journal.json'
        drift.write_text('OPENCODE_GO_API_KEY='+OPENCODE_KEY+'\nUNRELATED=keep\n',encoding='utf-8')
        drift_record=dict(record,source_path=str(drift),source_stamp=migration.stamp(drift),phase='awaiting_node_route')
        drift_journal.write_text(json.dumps(drift_record),encoding='utf-8')
        drift.write_text(drift.read_text()+'CONCURRENT=retain\n',encoding='utf-8')
        drift_args=argparse.Namespace(**vars(args));drift_args.env_file=str(drift);drift_args.journal=str(drift_journal)
        try:migration.execute(drift_args,environ={},token=ADMIN_TOKEN,http=route_http);held=False
        except ValueError:held=True
        ok(held and OPENCODE_KEY in drift.read_text() and 'CONCURRENT=retain' in drift.read_text(),'concurrent source edit refuses retirement without losing unrelated config')
        ok(migration.effective('OPENCODE_GO_API_KEY=file\nWASM_AGENT_LLM_API_KEY=first\n',{'OPENAI_API_KEY':'generic'})[:2]==('WASM_AGENT_LLM_API_KEY','first'),'effective aliases match per-variable process-over-file then route precedence')
        seen.clear()
        admin('POST','/api/opencode-go/enabled',{'enabled':True})
        request(PROXY,'POST','/opencode-go/v1/chat/completions',{'model':'m1'},{'Authorization':'Bearer wa-vault-brokered','X-Wa-Vault-Generation':record['generation']})
        ok(seen[-1][1].get('Authorization')=='Bearer '+OPENCODE_KEY,'migrated generation reaches fake upstream without placeholder')
        # Existing journals cannot re-send a credential write.
        args.reconcile=False;args.apply=True
        try: migration.execute(args,environ={},token=ADMIN_TOKEN);blocked=False
        except ValueError: blocked=True
        ok(blocked,'existing migration journal refuses effect replay')

    # Optional legacy scripted-reader compatibility, private native source + standalone embedding.
    if len(sys.argv)>1:
        SECRETS.append('sk-login-test-SECRET-4242')
        for embedded in (False,True):
            admin('DELETE','/api/opencode-go/key')
            home=os.path.join(data_dir,'lua-embedded' if embedded else 'lua-source');os.makedirs(home,exist_ok=True)
            clean={k:v for k,v in os.environ.items() if not k.startswith(('WA_','WASM_AGENT_','OPENAI_','OPENCODE_','PI_'))}
            clean.update(WASM_AGENT_HOME=home,WASM_AGENT_VAULT_URL='http://127.0.0.1:'+str(PROXY),WA_SCRIPT=os.path.join(ROOT,'scripts','test-vault-login.lua'))
            if not embedded: clean['WASM_AGENT_LUA_ROOT']=ROOT
            result=subprocess.run([os.path.abspath(sys.argv[1]),'--db',os.path.join(home,'fixture.db')],cwd=home,env=clean,capture_output=True,timeout=30)
            ok(result.returncode==0,'legacy scripted reader compatibility '+('embedded' if embedded else 'source'))
            no_secret(result.stdout,'legacy scripted reader stdout')
            no_secret(result.stderr,'legacy scripted reader diagnostics')

    # --- remove: gone, and refused again
    admin("DELETE", "/api/opencode-go/key")
    status, _ = request(PROXY, "GET", "/opencode-go/v1/models")
    ok(status == 401, "a removed key is refused")
    with open(os.path.join(data_dir, "vault.json")) as handle:
        ok("sk-opencode-SECRET" not in handle.read(), "a removed key is gone from the store")

    log_file.seek(0)
    no_secret(log_file.read(), "the vault's own log")
finally:
    child.terminate()
    child.wait(timeout=10)
    upstream.shutdown()

print("%d checks, %d failed, %d skipped" % (checks, failures, 0 if os.name == "posix" else 1))
sys.exit(1 if failures else 0)
