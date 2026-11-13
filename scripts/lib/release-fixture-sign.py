#!/usr/bin/env python3
"""Sign a fixture release's `SHA256SUMS` with the TEST key, so a test can stand up a signed release offline.

    python3 scripts/lib/release-fixture-sign.py <release-dir> [--unsigned] [--key A|B|X] [--key-id-out FILE]

Writes `<dir>/SHA256SUMS` (one `<sha256>  <name>` line per regular file in the directory, sorted by name,
never including `SHA256SUMS` itself or its signature) and `<dir>/SHA256SUMS.sig` signed with a key from
`tests/fixtures/release-sign/` - the same keys `tests/fixtures/release-sign/generate.py` derives from fixed
strings, which are TEST keys and appear in this repository on purpose.

It signs with the vault's own signer (`vault/wa_vault.py`), so a test that passes here also proves the
signature the real publisher would produce is the one the verifier accepts. `--unsigned` writes the sums
and no signature (the "a release without a signature" case); `--key B` signs with the rotation key.

`WA_RELEASE_KEYS` is printed to stderr as the file to trust, so a caller can point the verifier at it.
"""
import argparse
import hashlib
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(ROOT, "tests", "fixtures", "release-sign")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture_seed(label):
    return hashlib.sha256(("wasm-agent release-signing fixture " + label).encode()).digest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument("--key", default="A", choices=["A", "B", "X"])
    parser.add_argument("--unsigned", action="store_true")
    parser.add_argument("--key-id-out", help="write the signing key id here")
    arguments = parser.parse_args(argv)
    directory = arguments.directory
    vault = load("wa_vault_fixture_sign", os.path.join(ROOT, "vault", "wa_vault.py"))
    names = sorted(
        name for name in os.listdir(directory)
        if os.path.isfile(os.path.join(directory, name)) and name not in ("SHA256SUMS", "SHA256SUMS.sig"))
    if not names:
        print("release-fixture-sign: %s holds no asset to sum" % directory, file=sys.stderr)
        return 2
    rows = []
    for name in names:
        with open(os.path.join(directory, name), "rb") as handle:
            rows.append("%s  %s\n" % (hashlib.sha256(handle.read()).hexdigest(), name))
    sums = "".join(rows).encode()
    with open(os.path.join(directory, "SHA256SUMS"), "wb") as handle:
        handle.write(sums)
    seed = fixture_seed(arguments.key)
    public = vault.ed25519_public(seed).hex()
    key_id = "release-signing-" + hashlib.sha256(bytes.fromhex(public)).hexdigest()[:16]
    if not arguments.unsigned:
        digest = hashlib.sha256(sums).digest()
        signature = vault.ed25519_sign(seed, digest)
        with open(os.path.join(directory, "SHA256SUMS.sig"), "w", encoding="utf-8") as handle:
            handle.write("wa-release-signature v1\nkey %s\nalg ed25519\nsha256 %s\nsig %s\n"
                         % (key_id, digest.hex(), signature.hex()))
    if arguments.key_id_out:
        with open(arguments.key_id_out, "w", encoding="utf-8") as handle:
            handle.write(key_id + "\n")
    print("release-fixture-sign: %s key=%s signed=%s" % (directory, key_id, "no" if arguments.unsigned else "yes"),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
