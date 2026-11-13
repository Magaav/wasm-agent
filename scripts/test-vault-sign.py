#!/usr/bin/env python3
"""`release-signing` in wa-vault: the key signs a release and cannot be read back.

Runs the real `vault/wa_vault.py` as a child process against a scratch data directory - NEVER the
running vault - and asserts, from the outside, everything the release signing design claims:

  * the ed25519 signer is RFC 8032: its signatures equal the RFC's own test vectors (§7.1);
  * every release-signing route is ADMIN-ONLY: the proxy the agents use answers 404 for all of them, and
    the admin listener answers 401 without the token;
  * `sign` takes the manifest bytes or their sha256 and answers a signature and a key id - nothing else;
    the signature verifies with the node's own verifier (`scripts/lib/release_verify.py`), and the key
    that made it is never in the answer;
  * the ONE offline backup: to an operator-named file (0600, never overwritten, never printed) or to the
    page once - and every later call is refused, on both listeners;
  * no endpoint returns the seed after that, and no log line carries it;
  * one line per signature, naming the key id and the manifest's sha256.

Usage: python3 scripts/test-vault-sign.py   (exit 0 = every check passed)
"""

import http.client
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import socket

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADMIN_TOKEN = "s" * 40

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


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


vault_module = load("wa_vault_under_test", os.path.join(ROOT, "vault", "wa_vault.py"))
verifier = load("release_verify_under_test", os.path.join(ROOT, "scripts", "lib", "release_verify.py"))


# --- 1. the signer itself: RFC 8032 §7.1's vectors ------------------------------------------------
RFC_VECTORS = (
    ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
     "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
     "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
    ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
     "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
     "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
)
for seed_hex, public_hex, message_hex, signature_hex in RFC_VECTORS:
    seed, message = bytes.fromhex(seed_hex), bytes.fromhex(message_hex)
    ok(vault_module.ed25519_public(seed).hex() == public_hex, "RFC 8032 public key vector " + seed_hex[:8])
    ok(vault_module.ed25519_sign(seed, message).hex() == signature_hex, "RFC 8032 signature vector " + seed_hex[:8])
    ok(verifier.ed25519_verify(bytes.fromhex(public_hex), message, bytes.fromhex(signature_hex)),
       "the node's verifier accepts the RFC vector " + seed_hex[:8])
    flipped = bytearray(bytes.fromhex(signature_hex))
    flipped[0] ^= 1
    ok(not verifier.ed25519_verify(bytes.fromhex(public_hex), message, bytes(flipped)),
       "the node's verifier refuses a flipped signature byte " + seed_hex[:8])

# --- 2. a scratch vault ---------------------------------------------------------------------------
PROXY, ADMIN = free_port(), free_port()
data_dir = tempfile.mkdtemp(prefix="wa-vault-sign-")
backup_dir = tempfile.mkdtemp(prefix="wa-vault-sign-backup-")
clean_env = {k: v for k, v in os.environ.items()
             if not k.startswith(("WA_", "WASM_AGENT_", "OPENAI_", "OPENCODE_", "PI_"))}
env = dict(clean_env, WA_VAULT_ADMIN_TOKEN=ADMIN_TOKEN, WA_VAULT_DATA=data_dir,
           WA_VAULT_PROXY_PORT=str(PROXY), WA_VAULT_ADMIN_PORT=str(ADMIN), WA_VAULT_BIND="127.0.0.1",
           PYTHONDONTWRITEBYTECODE="1", PYTHONUNBUFFERED="1")
log_file = tempfile.TemporaryFile()
child = subprocess.Popen([sys.executable, os.path.join(ROOT, "vault", "wa_vault.py")], env=env,
                         stdout=log_file, stderr=subprocess.STDOUT)


def request(port, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
    connection.request(method, path, body=data, headers=headers or {})
    response = connection.getresponse()
    payload = response.read()
    connection.close()
    return response.status, payload


def admin(method, path, body=None, token=ADMIN_TOKEN, origin=None):
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["X-Vault-Token"] = token
    if origin is not None:
        headers["Origin"] = origin
    return request(ADMIN, method, path, body, headers)


RELEASE_ROUTES = (("GET", "/api/release-signing", None),
                  ("POST", "/api/release-signing/key", {}),
                  ("POST", "/api/release-signing/sign", {"sha256": "00" * 32}),
                  ("POST", "/api/release-signing/backup", {}))

try:
    started = False
    for _ in range(200):
        try:
            request(PROXY, "GET", "/status")
            request(ADMIN, "GET", "/")
            started = True
            break
        except OSError:
            time.sleep(0.05)
    ok(started, "the scratch vault started on both listeners")

    # --- 3. admin-only, both directions ------------------------------------------------
    for method, path, body in RELEASE_ROUTES:
        status, payload = request(PROXY, method, path, body, {"Content-Type": "application/json"})
        ok(status == 404, "the PROXY answers 404 for %s %s" % (method, path))
        ok(b"release-signing" not in payload.lower() or b"no route" in payload.lower(),
           "the proxy's %s %s answer names no key" % (method, path))
        status, _ = admin(method, path, body, token=None)
        ok(status == 401, "the admin %s %s needs the token" % (method, path))
        status, _ = admin(method, path, body, token="wrong" * 8)
        ok(status == 401, "the admin %s %s refuses a wrong token" % (method, path))
        status, _ = admin(method, path, body, origin="http://evil.example")
        ok(status == 401, "the admin %s %s refuses a foreign Origin" % (method, path))

    status, payload = admin("GET", "/api/release-signing")
    before = json.loads(payload)
    ok(status == 200 and before["configured"] is False, "a fresh vault holds no signing key")
    status, payload = admin("POST", "/api/release-signing/sign", {"sha256": "11" * 32})
    ok(status == 404 and b"vault_key_absent" in payload, "signing before a key exists is refused by name")
    status, payload = admin("POST", "/api/release-signing/backup", {})
    ok(status == 404 and b"vault_key_absent" in payload, "a backup before a key exists is refused by name")

    # --- 4. generate: the vault makes the key, and shows only the public half ------------------------
    status, payload = admin("POST", "/api/release-signing/key", {})
    created = json.loads(payload)
    ok(status == 200 and created["configured"] is True, "the admin page generates the key in the vault")
    ok(len(bytes.fromhex(created["public_key"])) == 32, "the PUBLIC key is answered (32 bytes)")
    ok(created["key_id"].startswith("release-signing-"), "the key has an id a person can compare")
    ok(created["backup_taken"] is False, "the one backup is still offered right after creation")
    ok("seed" not in payload.decode().lower() and "private" not in payload.decode().lower(),
       "generating answers no private material")
    status, payload = admin("GET", "/api/release-signing")
    ok(json.loads(payload)["public_key"] == created["public_key"], "the public key is stable on every read")
    status, payload = admin("POST", "/api/release-signing/key", {})
    ok(status == 409 and b"vault_key_exists" in payload, "a second key is refused without an explicit rotation")
    seed_path = os.path.join(data_dir, "keys", "release-signing.ed25519")
    ok(os.path.isfile(seed_path), "the seed lives in its own file under keys/")
    ok(stat.S_IMODE(os.stat(seed_path).st_mode) == 0o600, "the seed file is 0600")
    with open(seed_path, "rb") as handle:
        seed_hex = handle.read().hex()
    ok(vault_module.ed25519_public(bytes.fromhex(seed_hex)).hex() == created["public_key"],
       "the seed in the file is the key the vault published")

    # --- 5. sign: bytes or sha256, a signature and a key id, nothing else ----------------------------
    sums = b"".join(b"%064x  wa-x86_64-unknown-linux-gnu-%s\n" % (index, b"ab" * 6) for index in range(1, 4))
    import hashlib
    sums_sha = hashlib.sha256(sums).hexdigest()
    status, payload = admin("POST", "/api/release-signing/sign", {"bytes": __import__("base64").b64encode(sums).decode()})
    from_bytes = json.loads(payload)
    ok(status == 200 and from_bytes["sha256"] == sums_sha, "signing the manifest BYTES answers their sha256")
    status, payload = admin("POST", "/api/release-signing/sign", {"sha256": sums_sha})
    from_digest = json.loads(payload)
    ok(status == 200 and from_digest["signature"] == from_bytes["signature"],
       "the sha256 route and the bytes route sign the same digest identically")
    ok(set(from_digest) == {"key_id", "alg", "sha256", "signature"}, "sign answers exactly four fields")
    ok(from_digest["key_id"] == created["key_id"] and from_digest["alg"] == "ed25519", "the key id names the signer")
    # The node's own verifier must accept what the vault produced, over the digest of the real bytes.
    signature_file = verifier.signature_for(sums_sha, from_digest["key_id"],
                                            lambda digest: bytes.fromhex(from_digest["signature"]))
    keys_file = os.path.join(data_dir, "trusted.txt")
    with open(keys_file, "w", encoding="utf-8") as handle:
        handle.write("%s\nkey %s %s\n" % (verifier.TRUST_HEADER, created["key_id"], created["public_key"]))
    sums_dir = tempfile.mkdtemp(prefix="wa-release-")
    with open(os.path.join(sums_dir, "SHA256SUMS"), "wb") as handle:
        handle.write(sums)
    with open(os.path.join(sums_dir, "SHA256SUMS.sig"), "w", encoding="utf-8") as handle:
        handle.write(signature_file)
    ok(verifier.verify_release(os.path.join(sums_dir, "SHA256SUMS"), None, [keys_file]) == created["key_id"],
       "a node's verifier accepts the vault's signature over the release's own sums")
    status, payload = admin("POST", "/api/release-signing/sign", {"sha256": "not-a-digest"})
    ok(status == 400 and b"bad_sha256" in payload, "a malformed sha256 is refused by name")
    status, payload = admin("POST", "/api/release-signing/sign", {"nothing": True})
    ok(status == 400 and b"bad_request" in payload, "a body that names neither bytes nor sha256 is refused")

    # --- 6. the ONE offline backup: straight to a file, 0600, no overwrite, never printed -----------
    named = os.path.join(backup_dir, "release-signing-2026.key")
    status, payload = admin("POST", "/api/release-signing/backup", {"path": named})
    written = json.loads(payload)
    ok(status == 200 and written.get("path") == named, "the backup is written to the path the operator named")
    ok("seed_hex" not in written, "the file form answers no seed - it went to the file")
    ok(os.path.isfile(named), "the backup file exists")
    ok(stat.S_IMODE(os.stat(named).st_mode) == 0o600, "the backup file is 0600")
    with open(named, encoding="ascii") as handle:
        backed_up = handle.read().strip()
    ok(backed_up == seed_hex, "the backup is the key the vault signs with")
    ok(vault_module.ed25519_public(bytes.fromhex(backed_up)).hex() == created["public_key"],
       "the backed-up seed derives the public key the node trusts")

    # After the one export: nothing offers it again, on either listener, in either form.
    again = os.path.join(backup_dir, "second.key")
    for body in ({"path": again}, {}):
        status, payload = admin("POST", "/api/release-signing/backup", body)
        ok(status == 409 and b"vault_backup_taken" in payload, "a second backup is refused (%s)" % (body or "page form"))
    ok(not os.path.exists(again), "the refused second export wrote no file")
    status, payload = request(PROXY, "POST", "/api/release-signing/backup", {}, {"Content-Type": "application/json"})
    ok(status == 404, "the proxy offers no backup either")
    status, payload = admin("GET", "/api/release-signing")
    after = json.loads(payload)
    ok(after["backup_taken"] is True and after["public_key"] == created["public_key"],
       "the vault says the backup was taken and still publishes only the public key")
    ok(seed_hex not in payload.decode(), "the status route carries no seed")

    # --- 7. rotation: a fresh key gets its own one backup, and refuses to overwrite files ------------
    status, ptxt = admin("POST", "/api/release-signing/key", {"replace": True})
    rotated = json.loads(ptxt)
    ok(status == 200 and rotated["public_key"] != created["public_key"], "an explicit rotation makes a new key")
    ok(rotated["backup_taken"] is False, "the new key offers its own backup")
    status, payload = admin("POST", "/api/release-signing/backup", {"path": named})
    ok(status == 409 and b"vault_backup_exists" in payload,
       "the backup refuses to overwrite an existing file (the first copy is never replaced)")
    status, payload = admin("GET", "/api/release-signing")
    ok(json.loads(payload)["backup_taken"] is False,
       "a refused write does not spend the backup: the operator can still take it")
    status, payload = admin("POST", "/api/release-signing/backup", {"path": "relative.key"})
    ok(status == 400 and b"backup_path_invalid" in payload, "a relative backup path is refused")
    status, payload = admin("POST", "/api/release-signing/backup", {"path": backup_dir})
    ok(status == 400 and b"backup_path_invalid" in payload, "a directory is refused as a backup path")
    status, payload = admin("POST", "/api/release-signing/backup", {})
    page_backup = json.loads(payload)
    ok(status == 200 and page_backup.get("seed_hex") and len(page_backup["seed_hex"]) == 64,
       "the page form hands the seed over exactly once")
    ok(vault_module.ed25519_public(bytes.fromhex(page_backup["seed_hex"])).hex() == rotated["public_key"],
       "the page's one backup is the rotated key")
    status, payload = admin("POST", "/api/release-signing/backup", {})
    ok(status == 409, "and then the page form is refused too")
    status, payload = admin("POST", "/api/release-signing/sign", {"sha256": sums_sha})
    ok(json.loads(payload)["key_id"] == rotated["key_id"], "signing follows the rotated key")

    # --- 8. the log: one line per signature, key id and digest, never the key -----------------------
    log_file.seek(0)
    log = log_file.read().decode("utf-8", "replace")
    lines = [line for line in log.splitlines() if "release-signing signature:" in line]
    ok(len(lines) == 3, "one log line per signature (3 signed: bytes, sha256, rotated key)")
    ok(all(sums_sha in line for line in lines), "every signature line names the manifest's sha256")
    ok(all(("key=" + created["key_id"]) in line or ("key=" + rotated["key_id"]) in line for line in lines),
       "every signature line names the key id")
    ok(seed_hex not in log and page_backup["seed_hex"] not in log,
       "the vault's own log never carries a seed")
    ok(from_digest["signature"] not in log, "the vault's own log never carries a signature")
    ok("release-signing key generated:" in log, "key generation is logged as an event, without a value")
finally:
    child.terminate()
    child.wait(timeout=10)

print("%d checks, %d failed" % (checks, failures))
sys.exit(1 if failures else 0)
