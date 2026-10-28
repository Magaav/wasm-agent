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
         /status                        -> which providers are configured/enabled; no values
         /login/opencode-go             -> the CLI's `/login`: store/replace the opencode-go key
                                           (keys/opencode-go.key). Write-only, like the admin API: a
                                           key can be placed, and no answer carries a value.
  admin  (WA_VAULT_ADMIN_PORT, default 8801) - the operator's side: the page and its API. Every API
         call needs the admin token (`X-Vault-Token`), which is given to this process only and lives
         on the host, outside anything the agent can mount.

Rules this file is built around:

  1. **No read path.** No endpoint on either listener returns a stored value - not the admin API, not
     the proxy, not an error message. The admin API is write/replace/delete/status only. A stolen admin
     token can overwrite or delete a key; it cannot read one. The node-side `/login` routes need no
     token - they are how a person signs in from `wa chat` - so the agent can reach them too: it can
     place the opencode-go key (`<data>/keys/opencode-go.key`, never mounted by the agent), and it still cannot read one. Removing a credential stays on the admin page.
  2. **The upstream is fixed per route.** The node chooses a path under a route, never a host. No Host
     header passthrough, and no redirect following (a redirect would carry the credential to wherever
     it points).
  3. **The node's own credential headers are dropped**, and the vault's are set. The placeholder the
     node sends is never forwarded.

Standard library only, so the image is the interpreter and this file.
"""

import hmac
import uuid
import http.client
import json
import os
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Upstreams. Overridable only so a test can aim the vault at a local fixture.
OPENCODE_BASE = os.environ.get("WA_VAULT_OPENCODE_BASE", "https://opencode.ai/zen/go/v1").rstrip("/")

DATA_DIR = os.environ.get("WA_VAULT_DATA", "/data")
STORE_PATH = os.path.join(DATA_DIR, "vault.json")
# API keys are files: `<provider>.key`, one line, mode 600, in a directory only this process opens.
# vault.json keeps what may be said about a key (when, enabled, generation) and never the key itself.
KEYS_DIR = os.path.join(DATA_DIR, "keys")
KEY_PROVIDERS = ("opencode-go",)
ADMIN_TOKEN = os.environ.get("WA_VAULT_ADMIN_TOKEN", "")
PROXY_PORT = int(os.environ.get("WA_VAULT_PROXY_PORT", "8810"))
ADMIN_PORT = int(os.environ.get("WA_VAULT_ADMIN_PORT", "8801"))
BIND = os.environ.get("WA_VAULT_BIND", "0.0.0.0")
# The admin listener can be bound apart from the proxy, so a deployment can keep the token-gated page off
# the network the agent shares with the vault (the proxy must stay reachable from the agent; the page need not).
ADMIN_BIND = os.environ.get("WA_VAULT_ADMIN_BIND", BIND)
UPSTREAM_TIMEOUT = float(os.environ.get("WA_VAULT_UPSTREAM_TIMEOUT", "3600"))

PROVIDERS = ("opencode-go",)

# Headers never forwarded upstream: hop-by-hop, the node's own credential and identity, and anything
# that could steer the request to another host.
DROP_REQUEST = {
    "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding", "te", "trailer",
    "upgrade", "content-length", "authorization", "chatgpt-account-id", "cookie", "proxy-authorization",
    "forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip",
    "x-vault-token", "x-vault-instance", "x-wa-vault-generation",
}
DROP_RESPONSE = {
    "connection", "keep-alive", "transfer-encoding", "content-length", "set-cookie", "trailer",
    "upgrade", "proxy-authenticate",
}

_store_lock = threading.Lock()      # every read-modify-write of the store


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
        if os.name == "posix":
            os.fchmod(fd, 0o600)
        else:
            # Windows inherits the explicitly selected data directory's ACL; chmod is
            # not an ACL sandbox. Tests prove behavior, not a secret-isolation deployment.
            os.chmod(temp, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, STORE_PATH)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
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


# --- key files ---------------------------------------------------------------------------------

def key_path(provider):
    if provider not in KEY_PROVIDERS:
        raise VaultError(404, "vault_no_route", "no key file for " + str(provider))
    return os.path.join(KEYS_DIR, provider + ".key")


def read_key(provider):
    """The key, for the one header that carries it upstream. Never logged, never returned."""
    try:
        with open(key_path(provider), "r", encoding="utf-8") as handle:
            value = handle.read().strip()
        return value or None
    except FileNotFoundError:
        return None


def write_key(provider, value):
    # Same rule as the store: a private temp file in the same directory, fsync, then a rename.
    os.makedirs(KEYS_DIR, mode=0o700, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".key-", dir=KEYS_DIR)
    try:
        os.chmod(temp, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(value.strip() + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, key_path(provider))
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
        raise


def delete_key(provider):
    try:
        os.unlink(key_path(provider))
    except FileNotFoundError:
        pass


def migrate_keys(store):
    """A key from before key files moves out of vault.json into its file, once."""
    for provider in KEY_PROVIDERS:
        item = entry(store, provider)
        if item.get("key"):
            if not read_key(provider):
                write_key(provider, item["key"])
            item.pop("key", None)
            store[provider] = item
            log(provider + " key moved to its key file")


def valid_key(key):
    return isinstance(key, str) and key.strip() and len(key) <= 4096 and not any(c.isspace() for c in key.strip())


def entry(store, provider):
    value = store.get(provider)
    return value if isinstance(value, dict) else {}


def configured(store, provider):
    return provider in KEY_PROVIDERS and read_key(provider) is not None


def enabled(store, provider):
    return entry(store, provider).get("enabled", True) is not False


def public_status(store, operator=False):
    """What may be said about the store: presence, timestamps and the account id. Never a value."""
    out = {}
    for provider in PROVIDERS:
        item = entry(store, provider)
        status = {"configured": configured(store, provider), "enabled": enabled(store, provider),
                  "set_at": item.get("set_at"),
                  "generation": item.get("generation", "legacy" if configured(store, provider) else "absent")}
        if operator:
            status["operation"] = item.get("operation")
        if provider == 'opencode-go':
            # Opaque current-write receipt, not credential-derived; lets the parent verify a
            # frame result against the effective broker rather than trusting postMessage.
            status['operation'] = item.get('operation')
        out[provider] = status
    return out


# --- upstream ------------------------------------------------------------------------------------

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


MAX_BODY = 8 * 1024 * 1024


class VaultError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def set_opencode_key(key, first_only=False, expected=None, operation=None, door=False):
    """Store the key in opencode-go.key. `door` is the node-side `/login` (a person pasting in `wa chat`):
    it may replace a key and turns the provider on; the admin API keeps its generation check."""
    if not valid_key(key):
        raise VaultError(400, "bad_key", "paste the key on its own, one line")

    def put(store):
        previous = entry(store, "opencode-go")
        if first_only and configured(store, "opencode-go"):
            raise VaultError(409, "vault_key_exists", "wa-vault already holds an opencode-go key - replace it on the vault page")
        generation = previous.get("generation", "legacy" if configured(store, "opencode-go") else "absent")
        if not first_only and not door:
            try:
                valid_operation = isinstance(operation, str) and str(uuid.UUID(operation)) == operation and uuid.UUID(operation).version == 4
            except (ValueError, AttributeError):
                valid_operation = False
            if not valid_operation:
                raise VaultError(400, "bad_operation", "a canonical opaque UUIDv4 operation id is required")
            if expected != generation:
                raise VaultError(409, "vault_stale_generation", "credential changed; reconcile status before a new explicit save")
        write_key("opencode-go", key)
        store["opencode-go"] = {"set_at": now_ms(),
            "enabled": True if door else previous.get("enabled", True), "generation": str(uuid.uuid4()),
            "operation": operation or str(uuid.uuid4())}
    update_store(put)
    log("opencode-go key stored in its key file" + (" (from wa chat)" if door else ""))


# --- the proxy (the node's side) ---------------------------------------------------------------

def route(path):
    """(upstream_url, provider) for a proxy path, or None. The upstream host is never the caller's."""
    parsed = urllib.parse.urlsplit(path)
    query = ("?" + parsed.query) if parsed.query else ""
    # No percent-encoding and no backslash at all: `%2e%2e` is `..` to an upstream that normalises, and
    # a check on the raw text alone let it through with the credential attached. The paths the node
    # uses never need either.
    if "%" in parsed.path or "\\" in parsed.path:
        return None
    if any(segment in ("..", ".") for segment in parsed.path.split("/")) or "//" in parsed.path:
        return None
    if parsed.path.startswith("/opencode-go/v1/"):
        return OPENCODE_BASE + parsed.path[len("/opencode-go/v1"):] + query, "opencode-go"
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
        if isinstance(value, dict) and 'providers' in value:
            value = dict(value, vault_id=read_store().get('_vault_id'))
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
        # Bounded: the vault has 128 MiB and the agent can send it anything.
        self.connection.settimeout(30)
        if self.headers.get("Transfer-Encoding"):
            self.close_connection = True
            raise VaultError(400, "vault_bad_framing", "use a bounded Content-Length body, not transfer encoding")
        lengths = self.headers.get_all("Content-Length") or ["0"]
        try:
            if len(lengths) != 1 or not lengths[0].isdigit():
                raise ValueError()
            length = int(lengths[0])
        except ValueError:
            self.close_connection = True
            raise VaultError(400, "vault_bad_framing", "invalid Content-Length")
        if length > MAX_BODY:
            self.close_connection = True
            raise VaultError(413, "vault_body_too_large", "request body over %d bytes" % MAX_BODY)
        body = self.rfile.read(length) if length else b""
        if len(body) != length:
            self.close_connection = True
            raise VaultError(400, "vault_bad_framing", "incomplete body")
        return body


class ProxyHandler(Handler):
    def do_GET(self):
        if self.path == "/status":
            return self.send_json(200, {"providers": public_status(read_store())})
        self.proxy()

    def do_POST(self):
        if self.path.startswith("/login/"):
            return self.login()
        self.proxy()

    def do_DELETE(self):
        self.read_body()
        self.send_error_json(404, "vault_no_route", "wa-vault has no route for " + self.path.split("?")[0])

    def login(self):
        """The CLI's door: store a key. Never answers with a value."""
        try:
            body = self.read_body()
            if self.path == "/login/opencode-go":
                try:
                    payload = json.loads(body) if body else {}
                except ValueError:
                    raise VaultError(400, "bad_json", "the body is not JSON")
                # `/login` in `wa chat` pastes here, and may replace the key: placing a key and turning the
                # provider on is the whole of that flow. Named risk: this door is reachable by the agent
                # too, so an injected agent could swap in a key of its own; it still can never read one.
                # Check and mutation share _store_lock.
                set_opencode_key(payload.get("key") if isinstance(payload, dict) else None, door=True)
                return self.send_json(200, {"providers": public_status(read_store())})
        except VaultError as error:
            return self.send_error_json(error.status, error.code, error.message)
        self.send_error_json(404, "vault_no_route", "wa-vault has no route for " + self.path.split("?")[0])

    def proxy(self):
        target = route(self.path)
        if not target:
            self.close_connection = True  # refused bodies are never forwarded or retained
            return self.send_error_json(404, "vault_no_route", "wa-vault has no route for " + self.path.split("?")[0])
        url, provider = target
        try:
            body = self.read_body()
        except VaultError as error:
            return self.send_error_json(error.status, error.code, error.message)
        headers = {name: value for name, value in self.headers.items() if name.lower() not in DROP_REQUEST}
        try:
            store = read_store()
            expected = self.headers.get("X-Wa-Vault-Generation")
            if expected is not None and public_status(store)[provider]["generation"] != expected:
                raise VaultError(409, "vault_stale_generation", "credential changed since run start; request not sent")
            if not configured(store, provider):
                raise VaultError(401, "vault_credential_absent",
                                 "wa-vault holds no opencode-go key - paste it on the vault page")
            if not enabled(store, provider):
                raise VaultError(403, "vault_provider_disabled", "opencode-go is disabled on the vault page")
            headers["Authorization"] = "Bearer " + read_key(provider)
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


def embed_parent_origin():
    """One explicit parent, never a wildcard/CORS permission. Invalid configuration disables embedding."""
    value = os.environ.get('WA_VAULT_EMBED_PARENT_ORIGIN', '')
    parsed = urllib.parse.urlsplit(value)
    if (not value or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path or not parsed.hostname or value.endswith('/')
            or parsed.scheme not in ('http', 'https')
            or (parsed.scheme == 'http' and parsed.hostname not in ('127.0.0.1', 'localhost', '::1'))
            or any(c.isspace() for c in value) or '*' in value):
        return None
    try:
        parsed.port
    except ValueError:
        return None
    return value


def embedded_go(action, payload):
    """Operator-only durable Go operation ledger. Never stores a proposed key before commit.

    Prepared operations fence late sends after close/reload/cancel. A save is not replayable;
    status reconciles its exact historical operation+generation, including after supersession.
    """
    parent = embed_parent_origin()
    if not parent:
        raise VaultError(503, 'vault_embed_unconfigured', 'exact operator parent origin is not configured')
    scope = payload.get('scope')
    operation = payload.get('operation')
    if not isinstance(scope, str) or len(scope) != 64 or any(c not in '0123456789abcdef' for c in scope):
        raise VaultError(400, 'vault_embed_scope', 'public node/account scope required')
    if action != 'state':
        try:
            valid = isinstance(operation, str) and str(uuid.UUID(operation)) == operation and uuid.UUID(operation).version == 4
        except (ValueError, AttributeError):
            valid = False
        if not valid:
            raise VaultError(400, 'bad_operation', 'canonical UUIDv4 operation required')
    with _store_lock:
        store = read_store()
        if payload.get('expected_vault_id') != store.get('_vault_id'):
            raise VaultError(409, 'vault_instance_changed', 'vault identity changed; no write sent')
        operations = store.setdefault('_go_operations', {})
        item = operations.get(operation)
        if item and (item.get('scope') != scope or item.get('parent') != parent):
            raise VaultError(409, 'vault_operation_scope', 'operation belongs to another scope')
        current = public_status(store)['opencode-go']
        if action == 'prepare':
            if not item:
                if any(r.get('scope') == scope and r.get('parent') == parent and r.get('state') == 'prepared' for r in operations.values()):
                    raise VaultError(409, 'vault_operation_held', 'reconcile or explicitly cancel the pending operation first')
                if len(operations) >= 1024:
                    raise VaultError(409, 'vault_operation_history_full', 'operator operation history requires review; no evidence deleted')
                if payload.get('expected_generation') != current['generation']:
                    raise VaultError(409, 'vault_stale_generation', 'credential changed; read status before saving')
                operations[operation] = {'operation': operation, 'scope': scope, 'parent': parent,
                    'state': 'prepared', 'expected_generation': current['generation'], 'at': now_ms()}
                write_store(store)
        elif action == 'save':
            if not item or item.get('state') != 'prepared':
                raise VaultError(409, 'vault_operation_replay', 'save not admitted; reconcile, never resend a credential write')
            key = payload.get('key')
            if not valid_key(key):
                raise VaultError(400, 'bad_key', 'one nonempty key required')
            if item['expected_generation'] != current['generation']:
                item['state'] = 'refused'
                write_store(store)
                raise VaultError(409, 'vault_stale_generation', 'credential changed; this operation is refused')
            generation = str(uuid.uuid4())
            write_key('opencode-go', key)
            store['opencode-go'] = {'set_at': now_ms(),
                'enabled': entry(store, 'opencode-go').get('enabled', True), 'generation': generation, 'operation': operation}
            item.update(state='committed', generation=generation)
            write_store(store)
            log('opencode-go embedded credential committed')
        elif action == 'cancel':
            if not item:
                raise VaultError(409, 'vault_operation_absent', 'no prepared operation; read status')
            if item.get('state') == 'prepared':
                item['state'] = 'cancelled'
                write_store(store)
        elif action != 'state':
            raise VaultError(404, 'vault_no_route', 'unsupported embedded operation')
        current = public_status(store)['opencode-go']
        rows = [{k: r[k] for k in ('operation', 'state', 'expected_generation', 'generation', 'at') if k in r}
            for r in operations.values() if r.get('scope') == scope and r.get('parent') == parent]
        return {'vault_id': store.get('_vault_id'), 'scope': scope, 'provider': 'opencode-go',
            'entry': current, 'operations': sorted(rows, key=lambda r: r['at'])}


class AdminHandler(Handler):
    def authorized(self):
        supplied = self.headers.get("X-Vault-Token") or ""
        expected_instance=self.headers.get('X-Vault-Instance')
        if expected_instance and expected_instance != read_store().get('_vault_id'):
            return False
        origin = self.headers.get("Origin")
        expected_origin = os.environ.get("WA_VAULT_ADMIN_ORIGIN", "http://127.0.0.1:" + str(self.server.server_port))
        return (not origin or origin == expected_origin) and bool(ADMIN_TOKEN) and hmac.compare_digest(supplied.encode(), ADMIN_TOKEN.encode())

    def static(self, name, content_type, embedded=False):
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
        if embedded:
            self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; object-src 'none'; form-action 'none'; frame-ancestors " + embed_parent_origin())
            self.send_header('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), clipboard-read=(), clipboard-write=()')
        else:
            self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
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
        if path == '/embed/go':
            if not embed_parent_origin():
                return self.send_error_json(503, 'vault_embed_unconfigured', 'exact parent origin required')
            return self.static('embed-go.html', 'text/html; charset=utf-8', embedded=True)
        if path == '/embed-go.js':
            return self.static('embed-go.js', 'text/javascript; charset=utf-8')
        if path == '/embed-go.css':
            return self.static('embed-go.css', 'text/css; charset=utf-8')
        if path == '/embed/config':
            if not embed_parent_origin():
                return self.send_error_json(503, 'vault_embed_unconfigured', 'exact parent origin required')
            return self.send_json(200, {'vault_id': read_store().get('_vault_id'), 'parent_origin': embed_parent_origin()})
        if path == '/identity':
            return self.send_json(200, {'vault_id':read_store().get('_vault_id')})
        if not path.startswith("/api/"):
            return self.send_error_json(404, "not_found", path)
        if not self.authorized():
            return self.send_error_json(401, "vault_admin_token", "the admin token is missing or wrong")
        if path == "/api/status":
            return self.send_json(200, {"providers": public_status(read_store(), operator=True)})
        return self.send_error_json(404, "not_found", path)

    def do_POST(self):
        self.admin_write("POST")

    def do_DELETE(self):
        self.admin_write("DELETE")

    def admin_write(self, method):
        path = self.path.split("?")[0]
        if not self.authorized():
            self.close_connection = True
            return self.send_error_json(401, "vault_admin_token", "the admin token is missing or wrong")
        try:
            body = self.read_body()
        except VaultError as error:
            return self.send_error_json(error.status, error.code, error.message)
        if not self.authorized():
            return self.send_error_json(401, "vault_admin_token", "the admin token is missing or wrong")
        # The page is same-origin; a cross-site form post cannot set this header, which is what keeps a
        # page elsewhere in the browser from driving this API even if it guessed the port.
        try:
            payload = json.loads(body) if body else {}
        except ValueError:
            return self.send_error_json(400, "bad_json", "the body is not JSON")
        if not isinstance(payload, dict):
            return self.send_error_json(400, "bad_json", "the body must be a JSON object")
        if payload.get('expected_vault_id') is not None and payload['expected_vault_id'] != read_store().get('_vault_id'):
            return self.send_error_json(409, 'vault_instance_changed', 'operator vault instance changed; no write sent')
        try:
            if path.startswith('/api/embed/go/') and method == 'POST':
                if self.path != path:
                    raise VaultError(400, 'vault_embed_query', 'query parameters are not accepted')
                return self.send_json(200, embedded_go(path.rsplit('/', 1)[-1], payload))
            if path == "/api/opencode-go/key" and method == "POST":
                set_opencode_key(payload.get("key"), expected=payload.get("expected_generation"), operation=payload.get("operation"))
            elif path == "/api/opencode-go/key" and method == "DELETE":
                def remove_go(store):
                    current = public_status(store)["opencode-go"]["generation"]
                    if payload.get("expected_generation") != current:
                        raise VaultError(409, "vault_stale_generation", "credential changed; read status")
                    delete_key("opencode-go")
                    store["opencode-go"] = {"generation": str(uuid.uuid4()), "enabled": False}
                update_store(remove_go)
                log("opencode-go key removed")
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
        self.send_json(200, {"providers": public_status(read_store(), operator=True)})


def test_provider(provider):
    """One cheap upstream call with the stored credential; the answer is a status, never a body."""
    started = time.monotonic()
    try:
        store = read_store()
        if not configured(store, provider):
            return {"ok": False, "detail": "no key stored"}
        status, body = http_request("GET", OPENCODE_BASE + "/models", {
            "Authorization": "Bearer " + read_key(provider), "Accept": "application/json",
            "User-Agent": "wasm-agent/0.1 wa-vault"})
        detail = "HTTP %d" % status
        if status == 200:
            try:
                detail += ", %d models" % len(json.loads(body).get("data") or [])
            except (ValueError, AttributeError):
                pass
    except VaultError as error:
        return {"ok": False, "detail": error.code + ": " + error.message}
    except OSError as error:
        return {"ok": False, "detail": "unreachable: " + type(error).__name__}
    return {"ok": status == 200, "detail": detail, "ms": int((time.monotonic() - started) * 1000)}


def serve(port, handler, name, bind=None):
    bind = bind or BIND
    server = ThreadingHTTPServer((bind, port), handler)
    server.daemon_threads = True
    server.name = name
    log("%s listening on %s:%d" % (name, bind, port))
    return server


def main():
    if not ADMIN_TOKEN or len(ADMIN_TOKEN) < 24:
        # Refusing is the safe default: an admin API with no token is one the agent can drive.
        log("refusing to start: WA_VAULT_ADMIN_TOKEN must be set (24+ characters)")
        return 2
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    update_store(lambda store: store.setdefault('_vault_id', str(uuid.uuid4())))
    update_store(migrate_keys)
    proxy = serve(PROXY_PORT, ProxyHandler, "proxy")
    admin = serve(ADMIN_PORT, AdminHandler, "admin", ADMIN_BIND)
    threading.Thread(target=admin.serve_forever, daemon=True).start()
    try:
        proxy.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
