#!/usr/bin/env python3
"""wa-vault: the provider keys live here, and the agent can use them without being able to read them.

Why this is a separate process (and, deployed, a separate container): the agent has a shell that runs
as the node's own user, so any file, environment variable or memory the node can read, the agent can
read too - `cat`, `env`, `/proc/self/environ`. A key "hidden" inside the node is a key the agent holds.
The only boundary that holds is a process the agent cannot reach into, with storage it cannot mount.
So the node never receives a key: it sends its request here with a placeholder, and this process puts
the real credential on the upstream request and streams the answer back. The agent can *use* a key -
test a provider, run a turn - and there is no path by which it can *retrieve* one.

Two listeners, two audiences:

  proxy  (WA_VAULT_PROXY_PORT, default 8810) - the node's side. Fixed routes to fixed upstreams:
         /opencode-go/v1/<path>         -> https://opencode.ai/zen/go/v1/<path>   (API key)
         /openai-sub/codex/<path>       -> https://chatgpt.com/backend-api/codex/<path>  (OAuth)
         /openai-sub/wham/usage         -> https://chatgpt.com/backend-api/wham/usage    (OAuth)
         /status                        -> which providers are configured/enabled; no values
         /login, /login/<provider>      -> the CLI's `/login` (pi-style): start the ChatGPT device
                                           login, or store an opencode-go key. Write-only, like the
                                           admin API: a login can be started and a key replaced, and
                                           neither answer carries a stored value.
  admin  (WA_VAULT_ADMIN_PORT, default 8801) - the operator's side: the page and its API. Every API
         call needs the admin token (`X-Vault-Token`), which is given to this process only and lives
         on the host, outside anything the agent can mount.

Rules this file is built around:

  1. **No read path.** No endpoint on either listener returns a stored value - not the admin API, not
     the proxy, not an error message. The admin API is write/replace/delete/status only. A stolen admin
     token can overwrite or delete a key; it cannot read one. The node-side `/login` routes need no
     token - they are how a person signs in from `wa chat` - so the agent can reach them too: it can
     start a device login (which only a human with the ChatGPT account can complete) or replace the
     opencode-go key, and it still cannot read one. Removing a credential stays on the admin page.
  2. **The upstream is fixed per route.** The node chooses a path under a route, never a host. No Host
     header passthrough, no redirect following (a redirect would carry the credential to wherever it
     points), and a path allowlist for the subscription route, so the OAuth token reaches only the two
     endpoints wasm-agent uses and not the rest of the account surface.
  3. **The node's own credential headers are dropped**, and the vault's are set. The placeholder the
     node sends is never forwarded.
  4. **The refresh token rotates on every refresh**, so a refresh is single-flight under one lock and
     the store is re-read under it (the same rule as lua/core/openai_sub_auth.lua). A rejected refresh
     is never retried.

The OAuth constants and the device-code flow are the ones lua/core/openai_sub_auth.lua measured from
Pi 0.87.1 (MIT); see that file for the provenance. Standard library only, so the image is the
interpreter and this file.
"""

import base64
import hmac
import http.client
import json
import os
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --- the measured contract (Pi 0.87.1, MIT; see lua/core/openai_sub_auth.lua) -----------------
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
JWT_CLAIM_PATH = "https://api.openai.com/auth"
DEVICE_CODE_TIMEOUT_SECONDS = 900
PENDING_CODES = {"deviceauth_authorization_pending", "authorization_pending"}

# Upstreams. Overridable only so a test can aim the vault at a local fixture.
AUTH_BASE = os.environ.get("WA_VAULT_AUTH_BASE", "https://auth.openai.com").rstrip("/")
CHATGPT_BASE = os.environ.get("WA_VAULT_CHATGPT_BASE", "https://chatgpt.com/backend-api").rstrip("/")
OPENCODE_BASE = os.environ.get("WA_VAULT_OPENCODE_BASE", "https://opencode.ai/zen/go/v1").rstrip("/")

DATA_DIR = os.environ.get("WA_VAULT_DATA", "/data")
STORE_PATH = os.path.join(DATA_DIR, "vault.json")
ADMIN_TOKEN = os.environ.get("WA_VAULT_ADMIN_TOKEN", "")
PROXY_PORT = int(os.environ.get("WA_VAULT_PROXY_PORT", "8810"))
ADMIN_PORT = int(os.environ.get("WA_VAULT_ADMIN_PORT", "8801"))
BIND = os.environ.get("WA_VAULT_BIND", "0.0.0.0")
UPSTREAM_TIMEOUT = float(os.environ.get("WA_VAULT_UPSTREAM_TIMEOUT", "3600"))

PROVIDERS = ("opencode-go", "openai-sub")

# Headers never forwarded upstream: hop-by-hop, the node's own credential and identity, and anything
# that could steer the request to another host.
DROP_REQUEST = {
    "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding", "te", "trailer",
    "upgrade", "content-length", "authorization", "chatgpt-account-id", "cookie", "proxy-authorization",
    "forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip",
    "x-vault-token",
}
DROP_RESPONSE = {
    "connection", "keep-alive", "transfer-encoding", "content-length", "set-cookie", "trailer",
    "upgrade", "proxy-authenticate",
}

_store_lock = threading.Lock()      # every read-modify-write of the store
_refresh_lock = threading.Lock()    # single-flight OAuth refresh
_login = {"state": "idle"}          # the device flow in progress; no secrets in it
_login_lock = threading.Lock()


def log(message):
    # One line per event, never a value: the admin token, keys and tokens never reach a log.
    sys.stderr.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + message + "\n")
    sys.stderr.flush()


def now_ms():
    return int(time.time() * 1000)


# --- the store ---------------------------------------------------------------------------------

def read_store():
    try:
        with open(STORE_PATH, "r", encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except FileNotFoundError:
        return {}


def write_store(value):
    # Atomic and private: a temp file in the same directory, mode 600, then a rename.
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".vault-", dir=DATA_DIR)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, STORE_PATH)
    except BaseException:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
        raise


def update_store(mutate):
    with _store_lock:
        value = read_store()
        mutate(value)
        write_store(value)
        return value


def entry(store, provider):
    value = store.get(provider)
    return value if isinstance(value, dict) else {}


def configured(store, provider):
    item = entry(store, provider)
    if provider == "opencode-go":
        return bool(item.get("key"))
    return bool(item.get("access") and item.get("refresh"))


def enabled(store, provider):
    return entry(store, provider).get("enabled", True) is not False


def public_status(store):
    """What may be said about the store: presence, timestamps and the account id. Never a value."""
    out = {}
    for provider in PROVIDERS:
        item = entry(store, provider)
        status = {"configured": configured(store, provider), "enabled": enabled(store, provider),
                  "set_at": item.get("set_at")}
        if provider == "openai-sub":
            status["account"] = item.get("account_id")
            status["expires"] = item.get("expires")
            status["last_error"] = item.get("last_error")
        out[provider] = status
    return out


# --- OAuth (openai-sub) ------------------------------------------------------------------------

def http_request(method, url, headers=None, body=None, timeout=30):
    """One upstream request, no redirects followed. Returns (status, body_bytes)."""
    parsed = urllib.parse.urlsplit(url)
    connection_class = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    connection = connection_class(parsed.netloc, timeout=timeout)
    path = parsed.path + (("?" + parsed.query) if parsed.query else "")
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def post_json(url, value):
    return http_request("POST", url, {"Content-Type": "application/json", "Accept": "application/json"},
                        json.dumps(value).encode())


def post_form(url, fields):
    return http_request("POST", url, {"Content-Type": "application/x-www-form-urlencoded",
                                      "Accept": "application/json"},
                        urllib.parse.urlencode(fields).encode())


def oauth_error(body):
    # A provider's error body can quote the request, so only the documented OAuth fields are reported.
    try:
        payload = json.loads(body)
    except ValueError:
        return "body of %d bytes with no OAuth error field" % len(body)
    code = None
    description = None
    if isinstance(payload, dict):
        raw = payload.get("error")
        if isinstance(raw, str):
            code = raw
        elif isinstance(raw, dict) and isinstance(raw.get("code"), str):
            code = raw["code"]
        if isinstance(payload.get("error_description"), str):
            description = payload["error_description"][:160]
        if not code and isinstance(payload.get("code"), str):
            code = payload["code"]
    if not code and not description:
        return "body of %d bytes with no OAuth error field" % len(body)
    return ", ".join(part for part in (code and "error=" + code, description and "description=" + description) if part)


def account_id_from_access(access):
    try:
        encoded = access.split(".")[1]
        encoded += "=" * (-len(encoded) % 4)
        payload = json.loads(base64.urlsafe_b64decode(encoded))
        account = payload.get(JWT_CLAIM_PATH, {}).get("chatgpt_account_id")
        return account if isinstance(account, str) and account else None
    except (IndexError, ValueError, AttributeError):
        return None


def store_token_response(payload, source):
    access, refresh, expires_in = payload.get("access_token"), payload.get("refresh_token"), payload.get("expires_in")
    if not (isinstance(access, str) and access and isinstance(refresh, str) and refresh
            and isinstance(expires_in, (int, float))):
        raise RuntimeError("invalid_response: the token exchange answered without access_token/refresh_token/expires_in")
    account_id = account_id_from_access(access)
    if not account_id:
        raise RuntimeError("invalid_response: the access token carries no chatgpt_account_id claim")

    def mutate(store):
        previous = entry(store, "openai-sub")
        store["openai-sub"] = {"access": access, "refresh": refresh, "account_id": account_id,
                               "expires": now_ms() + int(expires_in * 1000), "set_at": now_ms(),
                               "source": source, "enabled": previous.get("enabled", True)}
    update_store(mutate)
    return account_id


def subscription_credential():
    """(access, account_id) for an upstream request, refreshing on hard expiry; raises VaultError."""
    store = read_store()
    item = entry(store, "openai-sub")
    if not configured(store, "openai-sub"):
        raise VaultError(401, "vault_credential_absent",
                         "wa-vault holds no ChatGPT login - log in from the vault page")
    if not enabled(store, "openai-sub"):
        raise VaultError(403, "vault_provider_disabled", "openai-sub is disabled on the vault page")
    if now_ms() < int(item.get("expires") or 0):
        return item["access"], item["account_id"]
    with _refresh_lock:
        # Re-read under the lock: the holder before us may have refreshed, and that token is the one.
        item = entry(read_store(), "openai-sub")
        if now_ms() < int(item.get("expires") or 0):
            return item["access"], item["account_id"]
        status, body = post_form(AUTH_BASE + "/oauth/token", {
            "grant_type": "refresh_token", "refresh_token": item.get("refresh", ""), "client_id": CLIENT_ID})
        if status < 200 or status >= 300:
            detail = "refresh_rejected:%d (%s)" % (status, oauth_error(body))

            def mark(store):
                entry(store, "openai-sub")["last_error"] = detail
            update_store(mark)
            log("openai-sub refresh rejected: %d" % status)
            raise VaultError(401, "refresh_rejected:%d" % status,
                             "the token endpoint refused the refresh - log in again from the vault page")
        try:
            payload = json.loads(body)
            store_token_response(payload, item.get("source") or "login")
        except (ValueError, RuntimeError) as error:
            raise VaultError(502, "invalid_response", str(error).split(":")[0])
        log("openai-sub refreshed")
        item = entry(read_store(), "openai-sub")
        return item["access"], item["account_id"]


def start_device_login():
    """Ask for a device code, then poll for it on a thread. Returns what the page shows the human."""
    with _login_lock:
        if _login.get("state") == "pending" and now_ms() < _login.get("expires_at", 0):
            return dict(_login)
    status, body = post_json(AUTH_BASE + "/api/accounts/deviceauth/usercode", {"client_id": CLIENT_ID})
    if status == 404:
        raise VaultError(502, "flow_failed:404", "device-code login is not enabled for " + AUTH_BASE)
    if status < 200 or status >= 300:
        raise VaultError(502, "flow_failed:%d" % status, "the device-code request was refused: " + oauth_error(body))
    payload = json.loads(body)
    device_auth_id, user_code = payload.get("device_auth_id"), payload.get("user_code")
    try:
        interval = float(payload.get("interval") or 5)
    except (TypeError, ValueError):
        interval = 5.0
    if not (isinstance(device_auth_id, str) and device_auth_id and isinstance(user_code, str) and user_code):
        raise VaultError(502, "invalid_response", "the device-code response carried no device_auth_id/user_code")
    with _login_lock:
        _login.clear()
        _login.update({"state": "pending", "user_code": user_code,
                       "verification_url": AUTH_BASE + "/codex/device",
                       "expires_at": now_ms() + DEVICE_CODE_TIMEOUT_SECONDS * 1000})
        public = dict(_login)
    threading.Thread(target=poll_device_login, args=(device_auth_id, user_code, interval), daemon=True).start()
    log("openai-sub device login started")
    return public


def poll_device_login(device_auth_id, user_code, interval):
    def finish(state, **fields):
        with _login_lock:
            if _login.get("user_code") == user_code:
                _login.update({"state": state, **fields})

    deadline = time.monotonic() + DEVICE_CODE_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        with _login_lock:
            if _login.get("user_code") != user_code or _login.get("state") != "pending":
                return  # cancelled or superseded
        time.sleep(max(1.0, interval))
        try:
            status, body = post_json(AUTH_BASE + "/api/accounts/deviceauth/token",
                                     {"device_auth_id": device_auth_id, "user_code": user_code})
        except OSError as error:
            finish("error", error="unreachable: " + type(error).__name__)
            return
        if 200 <= status < 300:
            try:
                payload = json.loads(body)
                code, verifier = payload.get("authorization_code"), payload.get("code_verifier")
                if not (isinstance(code, str) and code and isinstance(verifier, str) and verifier):
                    raise RuntimeError("invalid_response: no authorization_code/code_verifier")
                status, body = post_form(AUTH_BASE + "/oauth/token", {
                    "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                    "client_id": CLIENT_ID, "redirect_uri": AUTH_BASE + "/deviceauth/callback"})
                if status < 200 or status >= 300:
                    raise RuntimeError("flow_failed:%d: %s" % (status, oauth_error(body)))
                account = store_token_response(json.loads(body), "login:device")
            except (ValueError, RuntimeError) as error:
                finish("error", error=str(error)[:240])
                log("openai-sub device login failed")
                return
            finish("done", account=account)
            log("openai-sub logged in")
            return
        try:
            payload = json.loads(body)
        except ValueError:
            payload = {}
        error_code = None
        if isinstance(payload, dict):
            raw = payload.get("error")
            error_code = payload.get("code") or (raw.get("code") if isinstance(raw, dict) else raw)
        if status in (403, 404) or error_code in PENDING_CODES:
            continue
        if error_code == "slow_down":
            interval += 5
            continue
        finish("error", error="flow_failed:%d: %s" % (status, oauth_error(body)))
        return
    finish("error", error="flow_expired: the code was not entered in time")


class VaultError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def login_snapshot():
    with _login_lock:
        return dict(_login)


def set_opencode_key(key):
    if not isinstance(key, str) or not key.strip() or len(key) > 4096 or any(c.isspace() for c in key.strip()):
        raise VaultError(400, "bad_key", "paste the key on its own, one line")

    def put(store):
        previous = entry(store, "opencode-go")
        store["opencode-go"] = {"key": key.strip(), "set_at": now_ms(), "enabled": previous.get("enabled", True)}
    update_store(put)
    log("opencode-go key stored")


def cancel_login():
    with _login_lock:
        _login.clear()
        _login["state"] = "idle"


# --- the proxy (the node's side) ---------------------------------------------------------------

def route(path):
    """(upstream_url, provider) for a proxy path, or None. The upstream host is never the caller's."""
    parsed = urllib.parse.urlsplit(path)
    query = ("?" + parsed.query) if parsed.query else ""
    segments = parsed.path.split("/")
    if any(segment in ("..", ".") for segment in segments):
        return None
    if parsed.path.startswith("/opencode-go/v1/"):
        return OPENCODE_BASE + parsed.path[len("/opencode-go/v1"):] + query, "opencode-go"
    if parsed.path.startswith("/openai-sub/codex/") or parsed.path == "/openai-sub/wham/usage":
        return CHATGPT_BASE + parsed.path[len("/openai-sub"):] + query, "openai-sub"
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "wa-vault"
    sys_version = ""

    def log_message(self, fmt, *args):
        # The default logger prints the request line, which for this server carries no secret, but
        # the query string is the caller's and is not ours to keep.
        log("%s %s %s" % (self.server.name, self.command, self.path.split("?")[0]))

    def send_json(self, status, value, extra=None):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, header in (extra or {}).items():
            self.send_header(name, header)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_error_json(self, status, code, message):
        # The shape an OpenAI-compatible client already reads, so the node surfaces the sentence.
        self.send_json(status, {"error": {"code": code, "message": message, "type": "wa_vault"}})

    def read_body(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            return b"".join(chunks)
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length > 0 else b""


class ProxyHandler(Handler):
    def do_GET(self):
        if self.path == "/status":
            return self.send_json(200, {"providers": public_status(read_store())})
        if self.path == "/login":
            return self.send_json(200, {"providers": public_status(read_store()), "login": login_snapshot()})
        self.proxy()

    def do_POST(self):
        if self.path.startswith("/login/"):
            return self.login()
        self.proxy()

    def do_DELETE(self):
        if self.path == "/login/openai-sub":
            self.read_body()
            cancel_login()
            return self.send_json(200, {"providers": public_status(read_store()), "login": login_snapshot()})
        self.read_body()
        self.send_error_json(404, "vault_no_route", "wa-vault has no route for " + self.path.split("?")[0])

    def login(self):
        """The CLI's door: start the device login, or store a key. Never answers with a value."""
        body = self.read_body()
        try:
            if self.path == "/login/openai-sub":
                login = start_device_login()
                return self.send_json(200, {"providers": public_status(read_store()), "login": login})
            if self.path == "/login/opencode-go":
                try:
                    payload = json.loads(body) if body else {}
                except ValueError:
                    raise VaultError(400, "bad_json", "the body is not JSON")
                set_opencode_key(payload.get("key") if isinstance(payload, dict) else None)
                return self.send_json(200, {"providers": public_status(read_store())})
        except VaultError as error:
            return self.send_error_json(error.status, error.code, error.message)
        self.send_error_json(404, "vault_no_route", "wa-vault has no route for " + self.path.split("?")[0])

    def proxy(self):
        target = route(self.path)
        if not target:
            body = self.read_body()  # drain, so the connection stays in sync
            del body
            return self.send_error_json(404, "vault_no_route", "wa-vault has no route for " + self.path.split("?")[0])
        url, provider = target
        body = self.read_body()
        headers = {name: value for name, value in self.headers.items() if name.lower() not in DROP_REQUEST}
        try:
            if provider == "opencode-go":
                store = read_store()
                if not configured(store, provider):
                    raise VaultError(401, "vault_credential_absent",
                                     "wa-vault holds no opencode-go key - paste it on the vault page")
                if not enabled(store, provider):
                    raise VaultError(403, "vault_provider_disabled", "opencode-go is disabled on the vault page")
                headers["Authorization"] = "Bearer " + entry(store, provider)["key"]
            else:
                access, account_id = subscription_credential()
                headers["Authorization"] = "Bearer " + access
                headers["ChatGPT-Account-Id"] = account_id
        except VaultError as error:
            return self.send_error_json(error.status, error.code, error.message)

        parsed = urllib.parse.urlsplit(url)
        connection_class = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
        connection = connection_class(parsed.netloc, timeout=UPSTREAM_TIMEOUT)
        try:
            connection.request(self.command, parsed.path + (("?" + parsed.query) if parsed.query else ""),
                               body=body if body else None, headers=headers)
            response = connection.getresponse()
        except OSError as error:
            connection.close()
            return self.send_error_json(502, "vault_upstream_unreachable",
                                        "wa-vault could not reach the %s upstream (%s)" % (provider, type(error).__name__))
        try:
            # Streamed back as it arrives (SSE), re-framed as chunked: the upstream's own framing was
            # decoded by http.client, and the body bytes are passed through untouched.
            self.send_response(response.status)
            for name, value in response.getheaders():
                if name.lower() not in DROP_RESPONSE:
                    self.send_header(name, value)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = response.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True  # the node went away (a cancelled run); stop reading upstream
        finally:
            connection.close()


# --- the admin side (the operator's page) ------------------------------------------------------

PAGE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "page")


class AdminHandler(Handler):
    def authorized(self):
        supplied = self.headers.get("X-Vault-Token") or ""
        return bool(ADMIN_TOKEN) and hmac.compare_digest(supplied.encode(), ADMIN_TOKEN.encode())

    def static(self, name, content_type):
        try:
            with open(os.path.join(PAGE_DIR, name), "rb") as handle:
                body = handle.read()
        except FileNotFoundError:
            return self.send_error_json(404, "not_found", name)
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        # The page is the only thing that ever holds the admin token; keep it from being framed or
        # from loading anything it did not ship with.
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self.static("index.html", "text/html; charset=utf-8")
        if path == "/app.js":
            return self.static("app.js", "text/javascript; charset=utf-8")
        if path == "/manifest.webmanifest":
            return self.static("manifest.webmanifest", "application/manifest+json")
        if path == "/icon.svg":
            return self.static("icon.svg", "image/svg+xml")
        if not path.startswith("/api/"):
            return self.send_error_json(404, "not_found", path)
        if not self.authorized():
            return self.send_error_json(401, "vault_admin_token", "the admin token is missing or wrong")
        if path == "/api/status":
            return self.send_json(200, {"providers": public_status(read_store()), "login": login_snapshot()})
        return self.send_error_json(404, "not_found", path)

    def do_POST(self):
        self.admin_write("POST")

    def do_DELETE(self):
        self.admin_write("DELETE")

    def admin_write(self, method):
        path = self.path.split("?")[0]
        body = self.read_body()
        if not self.authorized():
            return self.send_error_json(401, "vault_admin_token", "the admin token is missing or wrong")
        # The page is same-origin; a cross-site form post cannot set this header, which is what keeps a
        # page elsewhere in the browser from driving this API even if it guessed the port.
        try:
            payload = json.loads(body) if body else {}
        except ValueError:
            return self.send_error_json(400, "bad_json", "the body is not JSON")
        try:
            if path == "/api/opencode-go/key" and method == "POST":
                set_opencode_key(payload.get("key"))
            elif path == "/api/opencode-go/key" and method == "DELETE":
                update_store(lambda store: store.pop("opencode-go", None))
                log("opencode-go key removed")
            elif path == "/api/openai-sub/login" and method == "POST":
                login = start_device_login()
                return self.send_json(200, {"login": login, "providers": public_status(read_store())})
            elif path == "/api/openai-sub/login" and method == "DELETE":
                cancel_login()
            elif path == "/api/openai-sub" and method == "DELETE":
                update_store(lambda store: store.pop("openai-sub", None))
                log("openai-sub login removed")
            elif path.endswith("/enabled") and method == "POST" and path.split("/")[2] in PROVIDERS:
                provider = path.split("/")[2]
                if not isinstance(payload.get("enabled"), bool):
                    return self.send_error_json(400, "bad_enabled", "enabled must be true or false")

                def toggle(store):
                    item = entry(store, provider)
                    item["enabled"] = payload["enabled"]
                    store[provider] = item
                update_store(toggle)
                log("%s %s" % (provider, "enabled" if payload["enabled"] else "disabled"))
            elif path.endswith("/test") and method == "POST" and path.split("/")[2] in PROVIDERS:
                return self.send_json(200, {"test": test_provider(path.split("/")[2])})
            else:
                return self.send_error_json(404, "not_found", path)
        except VaultError as error:
            return self.send_error_json(error.status, error.code, error.message)
        self.send_json(200, {"providers": public_status(read_store()), "login": login_snapshot()})


def test_provider(provider):
    """One cheap upstream call with the stored credential; the answer is a status, never a body."""
    started = time.monotonic()
    try:
        if provider == "opencode-go":
            store = read_store()
            if not configured(store, provider):
                return {"ok": False, "detail": "no key stored"}
            status, body = http_request("GET", OPENCODE_BASE + "/models", {
                "Authorization": "Bearer " + entry(store, provider)["key"], "Accept": "application/json",
                "User-Agent": "wasm-agent/0.1 wa-vault"})
            detail = "HTTP %d" % status
            if status == 200:
                try:
                    detail += ", %d models" % len(json.loads(body).get("data") or [])
                except (ValueError, AttributeError):
                    pass
        else:
            access, account_id = subscription_credential()
            status, _ = http_request("GET", CHATGPT_BASE + "/wham/usage", {
                "Authorization": "Bearer " + access, "ChatGPT-Account-Id": account_id,
                "Accept": "application/json", "User-Agent": "codex-cli"})
            detail = "HTTP %d" % status
    except VaultError as error:
        return {"ok": False, "detail": error.code + ": " + error.message}
    except OSError as error:
        return {"ok": False, "detail": "unreachable: " + type(error).__name__}
    return {"ok": status == 200, "detail": detail, "ms": int((time.monotonic() - started) * 1000)}


def serve(port, handler, name):
    server = ThreadingHTTPServer((BIND, port), handler)
    server.daemon_threads = True
    server.name = name
    log("%s listening on %s:%d" % (name, BIND, port))
    return server


def main():
    if not ADMIN_TOKEN or len(ADMIN_TOKEN) < 24:
        # Refusing is the safe default: an admin API with no token is one the agent can drive.
        log("refusing to start: WA_VAULT_ADMIN_TOKEN must be set (24+ characters)")
        return 2
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    proxy = serve(PROXY_PORT, ProxyHandler, "proxy")
    admin = serve(ADMIN_PORT, AdminHandler, "admin")
    threading.Thread(target=admin.serve_forever, daemon=True).start()
    try:
        proxy.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
