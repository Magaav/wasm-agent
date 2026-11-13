#!/usr/bin/env python3
"""Regenerate the release-signature fixtures. NOT a real key: three seeds derived from fixed strings.

Both verifiers - `scripts/lib/release_verify.py` (pure Python, used before a `wa` binary exists) and
`rust/wa-host/src/release.rs` (ring, inside the binary) - are judged by these same files, so a change that
makes one of them accept what the other refuses fails a test instead of shipping.

    python3 tests/fixtures/release-sign/generate.py

The three keys, and that they are TEST keys:

    A  sha256("wasm-agent release-signing fixture A") + fixture          trusted
    B  sha256("wasm-agent release-signing fixture B") + fixture          the rotation target
    X  sha256("wasm-agent release-signing fixture X") + fixture          trusted by nobody
"""
import hashlib
import importlib.util
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


vault = load("wa_vault_fixture", os.path.join(ROOT, "vault", "wa_vault.py"))
verify = load("release_verify_fixture", os.path.join(ROOT, "scripts", "lib", "release_verify.py"))


def seed(label):
    return hashlib.sha256(("wasm-agent release-signing fixture " + label).encode()).digest()


KEYS = {label: {"seed": seed(label), "public": vault.ed25519_public(seed(label)).hex()} for label in ("A", "B", "X")}
for label, value in KEYS.items():
    value["id"] = "release-signing-" + hashlib.sha256(bytes.fromhex(value["public"])).hexdigest()[:16]

SUMS = "".join(
    "%s  wa-%s-%s-%s\n" % (hashlib.sha256(("asset " + name).encode()).hexdigest(), name,
                           "x86_64-unknown-linux-gnu" if index % 2 else "aarch64-unknown-linux-gnu",
                           "0123456789ab")
    for index, name in enumerate(("wa", "wa-sentinel"))).encode()


def signature_file(label, digest):
    return ("wa-release-signature v1\nkey %s\nalg ed25519\nsha256 %s\nsig %s\n"
            % (KEYS[label]["id"], digest, vault.ed25519_sign(KEYS[label]["seed"], bytes.fromhex(digest)).hex()))


def trust_file(labels):
    return "wa-trusted-keys v1\n" + "".join("key %s %s\n" % (KEYS[label]["id"], KEYS[label]["public"]) for label in labels)


def write(directory, name, content):
    path = os.path.join(HERE, directory, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if isinstance(content, bytes) else "w"
    with open(path, mode) as handle:
        handle.write(content)
    print("wrote " + os.path.relpath(path, ROOT))


sums_digest = hashlib.sha256(SUMS).hexdigest()
write(".", "keys.txt", trust_file(["A"]))                       # what a node carries: key A

# 1. good: A signs these sums.
write("good", "SHA256SUMS", SUMS)
write("good", "SHA256SUMS.sig", signature_file("A", sums_digest))

# 2. flipped: one byte of the sums changes after it was signed.
flipped = bytearray(SUMS)
flipped[3] = ord("f") if flipped[3] != ord("f") else ord("e")
write("flipped", "SHA256SUMS", bytes(flipped))
write("flipped", "SHA256SUMS.sig", signature_file("A", sums_digest))

# 3. unknown: a well-formed signature by a key this node does not trust.
write("unknown", "SHA256SUMS", SUMS)
write("unknown", "SHA256SUMS.sig", signature_file("B", sums_digest))

# 4. missing: the sums ship with no signature at all (what every release before this change looks like).
write("missing", "SHA256SUMS", SUMS)

# 5. rotation: B signs this release, and B is announced in TRUSTED-KEYS signed by the trusted A.
rotation_sum = hashlib.sha256(SUMS + b"# rotation release\n").hexdigest()
rotated = SUMS + b"# rotation release\n"
write("rotation", "SHA256SUMS", rotated)
write("rotation", "SHA256SUMS.sig", signature_file("B", rotation_sum))
write("rotation", "TRUSTED-KEYS", trust_file(["A", "B"]))
write("rotation", "TRUSTED-KEYS.sig", signature_file("A", hashlib.sha256(trust_file(["A", "B"]).encode()).hexdigest()))

# 6. rotation-unknown: the same announcement, signed by X - a key trusted by nobody.
write("rotation-unknown", "SHA256SUMS", rotated)
write("rotation-unknown", "SHA256SUMS.sig", signature_file("B", rotation_sum))
write("rotation-unknown", "TRUSTED-KEYS", trust_file(["A", "B"]))
write("rotation-unknown", "TRUSTED-KEYS.sig",
      signature_file("X", hashlib.sha256(trust_file(["A", "B"]).encode()).hexdigest()))

# The two verifiers must agree on all six; this generator says so before it exits, so a fixture that
# cannot be what it is named is caught where it is made.
expectations = {"good": 0, "flipped": 3, "unknown": 4, "missing": 2, "rotation": 0, "rotation-unknown": 5}
for case, expected in expectations.items():
    try:
        verify.verify_release(os.path.join(HERE, case, "SHA256SUMS"), None, [os.path.join(HERE, "keys.txt")])
        code = 0
    except verify.VerificationError as error:
        code = error.code
    if code != expected:
        raise SystemExit("fixture %s verifies as %d, expected %d (signer and verifier disagree?)" % (case, code, expected))
print("fixtures ok: " + ", ".join("%s=%d" % (case, code) for case, code in expectations.items()))
