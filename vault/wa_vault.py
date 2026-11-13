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

import base64
import binascii
import hashlib
import hmac
import uuid
import http.client
import json
import os
import re
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


# --- ed25519 (RFC 8032), pure standard library ----------------------------------------------------
#
# The vault signs a release manifest and never returns the key, so it needs an ed25519 signer - and this
# image is `python:3.13-alpine` with nothing installed (the premise of this file: the image is the
# interpreter and this file). The curve arithmetic therefore lives here, written from RFC 8032 §5.1 in
# extended twisted-Edwards coordinates (dbl-2008-hwcd). It is checked against the RFC's own test vectors
# (§7.1) in `scripts/test-vault-sign.py`, and every signature it makes is verified by the node's ring on
# the other side of the seam, so an error in it cannot pass unseen by both.
_E_P = 2 ** 255 - 19
_E_L = 2 ** 252 + 27742317777372353535851937790883648493
_E_D = -121665 * pow(121666, _E_P - 2, _E_P) % _E_P
# The base point: y = 4/5, x the even root (RFC 8032 §5.1). Spelled out so this file needs no decoder.
_E_BX = 15112221349535400772501151409588531511454012693041857206046113283949847762202
_E_BY = 46316835694926478169428394003475163141307993866256225615783033603165251855960
_E_BASE = (_E_BX, _E_BY, 1, _E_BX * _E_BY % _E_P)


def _e_add(one, two):
    x1, y1, z1, t1 = one
    x2, y2, z2, t2 = two
    a = (y1 - x1) * (y2 - x2) % _E_P
    b = (y1 + x1) * (y2 + x2) % _E_P
    c = t1 * 2 * _E_D * t2 % _E_P
    d = z1 * 2 * z2 % _E_P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % _E_P, g * h % _E_P, f * g % _E_P, e * h % _E_P)


def _e_double(one):
    x1, y1, z1, _ = one
    a = x1 * x1 % _E_P
    b = y1 * y1 % _E_P
    c = 2 * z1 * z1 % _E_P
    h = a + b
    e = h - (x1 + y1) * (x1 + y1)
    g = a - b
    f = c + g
    return (e * f % _E_P, g * h % _E_P, f * g % _E_P, e * h % _E_P)


def _e_mult(scalar, point):
    result = (0, 1, 1, 0)          # the neutral element
    addend = point
    while scalar > 0:
        if scalar & 1:
            result = _e_add(result, addend)
        addend = _e_double(addend)
        scalar >>= 1
    return result


def _e_encode(point):
    x, y, z, _ = point
    inverse = pow(z, _E_P - 2, _E_P)
    x, y = x * inverse % _E_P, y * inverse % _E_P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _e_clamp(digest):
    scalar = int.from_bytes(digest[:32], "little") & ((1 << 254) - 8)
    return scalar | (1 << 254)


def ed25519_public(seed):
    """The 32-byte public key of a 32-byte seed (RFC 8032 §5.1.5)."""
    return _e_encode(_e_mult(_e_clamp(hashlib.sha512(seed).digest()), _E_BASE))


def ed25519_sign(seed, message):
    """RFC 8032 §5.1.6: the 64-byte signature of `message` under this seed."""
    digest = hashlib.sha512(seed).digest()
    scalar = _e_clamp(digest)
    public = _e_encode(_e_mult(scalar, _E_BASE))
    nonce = int.from_bytes(hashlib.sha512(digest[32:] + message).digest(), "little") % _E_L
    point = _e_encode(_e_mult(nonce, _E_BASE))
    challenge = int.from_bytes(hashlib.sha512(point + public + message).digest(), "little") % _E_L
    return point + int.to_bytes((nonce + challenge * scalar) % _E_L, 32, "little")


# --- the release signing key ----------------------------------------------------------------------
#
# One ed25519 key, `release-signing`, that exists so a node can trust a download: a release ships
# `SHA256SUMS` and `SHA256SUMS.sig`, the signature is made here, and a node verifies it against a public
# key it already holds (embedded in its binary, or listed in its config). That closes the hole this key
# was asked for: a node that checks a download against a checksum from the SAME release trusts whoever
# can publish that release with both halves at once.
#
# What holds, and is tested (`scripts/test-vault-sign.py`):
#
#   1. **Admin only.** Every release-signing route is under the admin listener. The proxy the nodes use
#      answers 404 for all of them, so an agent that can reach the proxy cannot make a signature.
#   2. **The seed never comes back.** `sign` answers a signature and a key id. The one exception is the
#      BACKUP: exactly one export, offered at creation time, by the page or to a file the operator names
#      - and after it, no route returns the seed, ever (`store[release-signing].backup_taken`).
#   3. **One line per signature**, naming the key id and the manifest's sha256 - never key material.
RELEASE_KEY = "release-signing"
RELEASE_SEED_PATH = os.path.join(KEYS_DIR, RELEASE_KEY + ".ed25519")


def read_release_seed():
    """The 32-byte seed, for the two operations that may hold it: sign, and the one backup."""
    try:
        with open(RELEASE_SEED_PATH, "rb") as handle:
            value = handle.read(32)
    except FileNotFoundError:
        return None
    return value if len(value) == 32 else None


def write_release_seed(seed):
    # Same discipline as a key file: a private temp file in the same directory, fsync, then a rename.
    os.makedirs(KEYS_DIR, mode=0o700, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".signing-", dir=KEYS_DIR)
    try:
        os.chmod(temp, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(seed)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, RELEASE_SEED_PATH)
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


def release_key_id(public_hex):
    """A key id a person can compare: `sha256(public key)`'s first 16 hex, prefixed with the name."""
    return RELEASE_KEY + "-" + hashlib.sha256(bytes.fromhex(public_hex)).hexdigest()[:16]


def release_entry(store):
    value = store.get(RELEASE_KEY)
    return value if isinstance(value, dict) else {}


def release_status(store):
    """What may be said about the signing key: its id and its PUBLIC half. Never the seed."""
    seed = read_release_seed()
    item = release_entry(store)
    if seed is None:
        return {"configured": False, "key_id": None, "public_key": None, "created_at": None,
                "backup_taken": True, "signatures": item.get("signatures", 0)}
    public = item.get("public_key") or ed25519_public(seed).hex()
    return {"configured": True, "key_id": item.get("key_id") or release_key_id(public),
            "public_key": public, "created_at": item.get("created_at"),
            "backup_taken": bool(item.get("backup_taken")), "signatures": item.get("signatures", 0)}


def release_generate(replace=False):
    """Generate the key INSIDE the vault. Answers the public half; the seed stays in its file."""
    def put(store):
        if read_release_seed() is not None and not replace:
            raise VaultError(409, "vault_key_exists",
                             "wa-vault already holds the release-signing key; rotate it only if you mean to "
                             "sign releases with a new key (POST /api/release-signing/key {\"replace\": true})")
        seed = os.urandom(32)
        public = ed25519_public(seed).hex()
        write_release_seed(seed)
        store[RELEASE_KEY] = {"created_at": now_ms(), "public_key": public,
            "key_id": release_key_id(public), "generation": str(uuid.uuid4()),
            # False until the one backup is produced: this flag IS the one-shot budget.
            "backup_taken": False, "signatures": 0}
    update_store(put)
    status = release_status(read_store())
    log("release-signing key generated: key=%s (public key only; no value logged)" % status["key_id"])
    return status


def release_backup_file(path):
    """Write the seed to an operator-named path: 0600, never overwritten, never printed."""
    if not isinstance(path, str) or not path.strip() or any(ord(c) < 32 for c in path):
        raise VaultError(400, "backup_path_invalid", "name the file to write the backup to")
    path = path.strip()
    if not os.path.isabs(path):
        raise VaultError(400, "backup_path_invalid",
                         "the backup path must be absolute - a path inside a volume the vault can write")
    if os.path.isdir(path):
        raise VaultError(400, "backup_path_invalid", "the backup path is a directory; name a file")
    directory = os.path.dirname(path)
    if not os.path.isdir(directory):
        raise VaultError(400, "backup_path_missing", "the backup file's directory does not exist here: " + directory)
    try:
        # O_EXCL is the no-overwrite rule: an existing file is refused, not truncated, so a second
        # export can never land on top of the first copy the operator already wrote down.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise VaultError(409, "vault_backup_exists", "refusing to overwrite an existing file: " + path)
    except OSError as error:
        raise VaultError(409, "vault_backup_unwritable",
                         "the backup file could not be created (%s): %s" % (type(error).__name__, path))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write(read_release_seed().hex() + "\n")
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as error:
        raise VaultError(409, "vault_backup_unwritable",
                         "the backup file could not be written (%s): %s" % (type(error).__name__, path))
    return path


def release_backup(path=None):
    """The ONE offline backup: at creation time, once, then never again.

    Two shapes, one budget. With `path`, the seed is written straight to the file the operator names
    (mode 0600, never overwritten, never printed) - the copy that goes to a USB stick. Without it, the
    seed is answered to the operator's page so it can be written down. Either way this marks the backup
    as taken in the same locked write, and every later call is refused: after this, no route in this
    file returns the seed. Named risk: with the admin token, this route writes one file at a path of the
    operator's choosing. It refuses to overwrite, it refuses a relative path, and it exists once per key.
    """
    if read_release_seed() is None:
        raise VaultError(404, "vault_key_absent", "wa-vault holds no release-signing key - create it first")
    written = None

    def take(store):
        nonlocal written
        item = release_entry(store)
        if item.get("backup_taken"):
            raise VaultError(409, "vault_backup_taken",
                             "the one offline backup of the release-signing key was already taken; no route "
                             "returns the seed again (rotate the key if the backup was lost)")
        if path is not None:
            written = release_backup_file(path)
        item["backup_taken"] = True
        item["backup_taken_at"] = now_ms()
        store[RELEASE_KEY] = item
    update_store(take)
    status = release_status(read_store())
    log("release-signing key backed up once (%s): key=%s" % ("file" if written else "page", status["key_id"]))
    answer = {"key_id": status["key_id"], "public_key": status["public_key"], "backup_taken": True}
    if written is not None:
        answer["path"] = written
    else:
        # The single exception in this file, and it is spent: `backup_taken` is already written.
        answer["seed_hex"] = read_release_seed().hex()
    return answer


def release_sign(payload):
    """Sign a manifest's sha256 (or its bytes). Answers the signature and the key id - nothing else."""
    seed = read_release_seed()
    if seed is None:
        raise VaultError(404, "vault_key_absent", "wa-vault holds no release-signing key - create it on the vault page")
    if "sha256" in payload:
        digest_hex = payload.get("sha256")
        if not isinstance(digest_hex, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest_hex.strip()):
            raise VaultError(400, "bad_sha256", "sha256 must be the 64-character hex digest of the manifest")
        digest = bytes.fromhex(digest_hex.strip())
    elif "bytes" in payload:
        try:
            raw = base64.b64decode(payload.get("bytes") or "", validate=True)
        except (ValueError, binascii.Error):
            raise VaultError(400, "bad_bytes", "bytes must be the manifest, base64-encoded")
        if len(raw) > MAX_BODY:
            raise VaultError(413, "vault_body_too_large", "manifest over %d bytes" % MAX_BODY)
        if not raw:
            raise VaultError(400, "bad_bytes", "there is nothing to sign")
        digest = hashlib.sha256(raw).digest()
    else:
        raise VaultError(400, "bad_request", "send the manifest bytes (\"bytes\", base64) or their sha256")
    # What is signed is the DIGEST, on both paths: a node recomputes sha256(SHA256SUMS) and verifies this
    # signature over those 32 bytes, so the vault never has to agree with a node about a file's framing.
    signature = ed25519_sign(seed, digest)

    def count(store):
        item = release_entry(store)
        item["signatures"] = int(item.get("signatures") or 0) + 1
        store[RELEASE_KEY] = item
    update_store(count)
    status = release_status(read_store())
    # One line per signature: the key id and what was signed. The key itself is never logged.
    log("release-signing signature: key=%s sha256=%s" % (status["key_id"], digest.hex()))
    return {"key_id": status["key_id"], "alg": "ed25519", "sha256": digest.hex(), "signature": signature.hex()}


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
            return self.send_json(200, {"providers": public_status(read_store(), operator=True),
                                        "release_signing": release_status(read_store())})
        # The signing key's own view: id and public half. Admin listener only - the proxy has no route
        # for it (`ProxyHandler` answers 404), which is what keeps a signature the operator's to make.
        if path == "/api/release-signing":
            return self.send_json(200, release_status(read_store()))
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
            # The release-signing operations: generate, sign, and the one backup. None of them answers
            # with the seed except the backup, and the backup does so once (release_backup).
            if path == '/api/release-signing/key' and method == 'POST':
                return self.send_json(200, release_generate(replace=payload.get('replace') is True))
            if path == '/api/release-signing/sign' and method == 'POST':
                return self.send_json(200, release_sign(payload))
            if path == '/api/release-signing/backup' and method == 'POST':
                named = payload.get('path')
                if named is not None and not isinstance(named, str):
                    raise VaultError(400, 'backup_path_invalid', 'name the file to write the backup to')
                return self.send_json(200, release_backup(named))
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
