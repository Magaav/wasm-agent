#!/usr/bin/env python3
"""Verify a release's SHA256SUMS against its SHA256SUMS.sig, with a key this node already trusts.

WHY THIS EXISTS. A node used to check a download against a checksum that ships in the SAME release, so
whoever could publish a release could swap the binary and the checksum together and nothing would notice.
Now a release's `SHA256SUMS` is signed by wa-vault with the `release-signing` ed25519 key, and this file
verifies that signature against a public key the node holds before the release: the list embedded in the
`wa` binary and the list in the node's config (`config/release-keys.txt`).

    python3 scripts/lib/release_verify.py --sums DIR|FILE [--keys FILE] [--announce FILE] [--quiet]

`DIR` is the directory a release was downloaded into (`SHA256SUMS`, `SHA256SUMS.sig`, and optionally
`TRUSTED-KEYS` + `TRUSTED-KEYS.sig` when the release announces a key rotation).

THE FORMATS, which the node's Rust verifier reads too (`rust/wa-host/src/release.rs`):

  SHA256SUMS.sig                 TRUSTED-KEYS                TRUSTED-KEYS.sig
  wa-release-signature v1        wa-trusted-keys v1          (same as SHA256SUMS.sig)
  key <key id>                   key <key id> <public hex>   ...
  alg ed25519                    key <key id> <public hex>
  sha256 <hex of the file>
  sig <hex, 64 bytes>

What is signed is the SHA-256 DIGEST of the file (32 bytes), not its text: a node recomputes the digest
of the bytes it downloaded and verifies the signature over those 32 bytes, so no two readers have to
agree about line endings or trailing newlines to agree about what was signed.

ROTATION. A release may announce a new key in `TRUSTED-KEYS`, and that announcement is itself signed
(`TRUSTED-KEYS.sig`) by a key that is trusted NOW - the embedded/config list, never the announced one.
Only then does the announced list become the trust set for `SHA256SUMS.sig`. So a rotation signed by an
unknown key is refused, and a rotation announced by a trusted key is accepted even when the release
itself is signed by the new key.

Exit codes: 0 verified; 2 no signature file; 3 the signature does not match the sums; 4 the key that
signed is not trusted; 5 a rotation announcement is not signed by a currently trusted key; 6 a file is
unreadable or malformed.
"""

import argparse
import hashlib
import os
import sys

SIGNATURE_HEADER = "wa-release-signature v1"
TRUST_HEADER = "wa-trusted-keys v1"


# --- ed25519 verify (RFC 8032), pure standard library ------------------------------------------------
# The signing half lives in wa-vault (vault/wa_vault.py, which the vault image carries as its only
# non-page file); this is the verifying half, for the hosts that check a release before a `wa` binary
# exists (scripts/install.sh, scripts/linux/bootstrap.sh). Both are checked against RFC 8032 §7.1's
# vectors in scripts/test-release-signing.py, and the node's binary verifies with ring, so the two sides
# are not allowed to agree only with each other.
_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_I = pow(2, (_P - 1) // 4, _P)


def _decode(data):
    if len(data) != 32:
        return None
    value = int.from_bytes(data, "little")
    sign = value >> 255
    y = value & ((1 << 255) - 1)
    if y >= _P:
        return None
    xx = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P) % _P
    x = pow(xx, (_P + 3) // 8, _P)
    if (x * x - xx) % _P != 0:
        x = x * _I % _P
    if (x * x - xx) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return (x, y, 1, x * y % _P)


def _add(one, two):
    x1, y1, z1, t1 = one
    x2, y2, z2, t2 = two
    a = (y1 - x1) * (y2 - x2) % _P
    b = (y1 + x1) * (y2 + x2) % _P
    c = t1 * 2 * _D * t2 % _P
    d = z1 * 2 * z2 % _P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _double(one):
    x1, y1, z1, _ = one
    a = x1 * x1 % _P
    b = y1 * y1 % _P
    c = 2 * z1 * z1 % _P
    h = a + b
    e = h - (x1 + y1) * (x1 + y1)
    g = a - b
    f = c + g
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _mult(scalar, point):
    result = (0, 1, 1, 0)
    addend = point
    while scalar > 0:
        if scalar & 1:
            result = _add(result, addend)
        addend = _double(addend)
        scalar >>= 1
    return result


def _encode(point):
    x, y, z, _ = point
    inverse = pow(z, _P - 2, _P)
    return int.to_bytes(y * inverse % _P | ((x * inverse % _P & 1) << 255), 32, "little")


_BASE = _decode(int.to_bytes(4 * pow(5, _P - 2, _P) % _P, 32, "little"))


def ed25519_verify(public, message, signature):
    """True when `signature` is this 32-byte public key's signature over `message`, and nothing else."""
    if len(public) != 32 or len(signature) != 64:
        return False
    point, left = _decode(signature[:32]), _decode(public)
    if point is None or left is None:
        return False
    scalar = int.from_bytes(signature[32:], "little")
    if scalar >= _L:                       # a non-canonical S is refused, not reduced
        return False
    challenge = int.from_bytes(hashlib.sha512(signature[:32] + public + message).digest(), "little") % _L
    # R + [k]A == [S]B
    return _encode(_mult(scalar, _BASE)) == _encode(_add(point, _mult(challenge, left)))


# --- the release files ------------------------------------------------------------------------------

class VerificationError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


def parse_trusted_keys(text, source="keys"):
    """`wa-trusted-keys v1` + one `key <id> <public hex>` line each -> {id: public hex}."""
    keys = {}
    header = False
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if not header:
            if line != TRUST_HEADER:
                raise VerificationError(6, "%s: line %d is not %r" % (source, number, TRUST_HEADER))
            header = True
            continue
        fields = line.split()
        if len(fields) != 3 or fields[0] != "key":
            raise VerificationError(6, "%s: line %d is not 'key <id> <public hex>'" % (source, number))
        key_id, public = fields[1], fields[2].lower()
        try:
            valid = len(bytes.fromhex(public)) == 32
        except ValueError:
            valid = False
        if not valid:
            raise VerificationError(6, "%s: line %d has no 32-byte ed25519 public key" % (source, number))
        keys[key_id] = public
    if not header:
        raise VerificationError(6, "%s: no %r header" % (source, TRUST_HEADER))
    return keys


def parse_signature(text, source="SHA256SUMS.sig"):
    """-> {'key','alg','sha256','sig'} or refuse."""
    fields, header = {}, False
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if not header:
            if line != SIGNATURE_HEADER:
                raise VerificationError(6, "%s: line %d is not %r" % (source, number, SIGNATURE_HEADER))
            header = True
            continue
        parts = line.split()
        if len(parts) != 2 or parts[0] not in ("key", "alg", "sha256", "sig"):
            raise VerificationError(6, "%s: line %d is not '<field> <value>'" % (source, number))
        fields[parts[0]] = parts[1]
    if not header:
        raise VerificationError(6, "%s: no %r header" % (source, SIGNATURE_HEADER))
    missing = [name for name in ("key", "alg", "sha256", "sig") if name not in fields]
    if missing:
        raise VerificationError(6, "%s: missing %s" % (source, ", ".join(missing)))
    if fields["alg"] != "ed25519":
        raise VerificationError(6, "%s: algorithm %r is not ed25519" % (source, fields["alg"]))
    try:
        valid = len(bytes.fromhex(fields["sha256"])) == 32 and len(bytes.fromhex(fields["sig"])) == 64
    except ValueError:
        valid = False
    if not valid:
        raise VerificationError(6, "%s: sha256 must be 64 hex characters and sig 128" % source)
    return fields


def signature_for(sha256_hex, key_id, signer):
    """The text a release ships as SHA256SUMS.sig. `signer` is (digest bytes) -> 64 signature bytes."""
    signature = signer(bytes.fromhex(sha256_hex))
    return "{header}\nkey {key}\nalg ed25519\nsha256 {sha256}\nsig {sig}\n".format(
        header=SIGNATURE_HEADER, key=key_id, sha256=sha256_hex, sig=signature.hex())


def trusted_keys_from(paths):
    """{id: public hex} from the files that exist; a malformed one is a refusal, not a shrug."""
    keys = {}
    for path in paths:
        if not path or not os.path.exists(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as handle:
                keys.update(parse_trusted_keys(handle.read(), path))
        except OSError as error:
            raise VerificationError(6, "%s: %s" % (path, error.strerror or type(error).__name__))
    return keys


def verify_release(sums_path, sig_path=None, keys=(), announce_dir=None, sums_bytes=None):
    """Verify one release. Returns the key id that vouched for it, or raises VerificationError.

    `keys` is an iterable of trusted-keys file paths (embedded config first, then the node's own). The
    same directory may also carry `TRUSTED-KEYS` + `TRUSTED-KEYS.sig`, which is how a release announces a
    rotation: that announcement is checked against `keys` (the trust set as it is NOW), and only then
    does its list become the trust set for this release's sums.
    """
    directory = os.path.dirname(os.path.abspath(sums_path)) if sums_path else announce_dir
    if sums_bytes is None:
        try:
            with open(sums_path, "rb") as handle:
                sums_bytes = handle.read()
        except OSError as error:
            raise VerificationError(6, "%s: %s" % (sums_path, error.strerror or type(error).__name__))
    if sig_path is None:
        sig_path = os.path.join(directory, "SHA256SUMS.sig")
    if not os.path.isfile(sig_path):
        raise VerificationError(2, "no signature beside the sums: %s is missing" % sig_path)
    try:
        with open(sig_path, "r", encoding="utf-8") as handle:
            signature = parse_signature(handle.read(), sig_path)
    except OSError as error:
        raise VerificationError(6, "%s: %s" % (sig_path, error.strerror or type(error).__name__))

    digest = hashlib.sha256(sums_bytes).hexdigest()
    if digest != signature["sha256"]:
        # Not a bad signature yet: the signature is about different bytes, which is the same refusal a
        # swapped binary produces and a plainer sentence than "signature invalid".
        raise VerificationError(3, "%s is about %s, the sums here are %s" % (sig_path, signature["sha256"], digest))

    trusted = dict(trusted_keys_from(keys))
    announce = os.path.join(directory, "TRUSTED-KEYS")
    if os.path.isfile(announce):
        announce_sig = announce + ".sig"
        if not os.path.isfile(announce_sig):
            raise VerificationError(5, "a rotation is announced in %s with no %s signing it" % (announce, announce_sig))
        try:
            with open(announce, "rb") as handle:
                announced_bytes = handle.read()
            with open(announce_sig, "r", encoding="utf-8") as handle:
                announced_signature = parse_signature(handle.read(), announce_sig)
        except OSError as error:
            raise VerificationError(6, "%s: %s" % (announce, error.strerror or type(error).__name__))
        announced_digest = hashlib.sha256(announced_bytes).hexdigest()
        if announced_digest != announced_signature["sha256"]:
            raise VerificationError(5, "%s is about %s, %s is %s" % (
                announce_sig, announced_signature["sha256"], announce, announced_digest))
        voucher = trusted.get(announced_signature["key"])
        if voucher is None:
            raise VerificationError(5, "the rotation in %s is signed by %s, which is not trusted here" % (
                announce, announced_signature["key"]))
        if not ed25519_verify(bytes.fromhex(voucher), bytes.fromhex(announced_digest), bytes.fromhex(announced_signature["sig"])):
            raise VerificationError(5, "the rotation in %s does not verify against the trusted key %s" % (
                announce, announced_signature["key"]))
        try:
            with open(announce, "r", encoding="utf-8") as handle:
                trusted = parse_trusted_keys(handle.read(), announce)
        except OSError as error:
            raise VerificationError(6, "%s: %s" % (announce, error.strerror or type(error).__name__))

    public = trusted.get(signature["key"])
    if public is None:
        raise VerificationError(4, "%s is signed by %s, which this node does not trust (%s)" % (
            sig_path, signature["key"], ", ".join(sorted(trusted)) or "no trusted key is configured"))
    if not ed25519_verify(bytes.fromhex(public), bytes.fromhex(digest), bytes.fromhex(signature["sig"])):
        raise VerificationError(4, "%s does not verify against the trusted key %s" % (sig_path, signature["key"]))
    return signature["key"]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Verify a release's SHA256SUMS signature before installing it.")
    parser.add_argument("--sums", help="the SHA256SUMS file, or the directory that holds it")
    parser.add_argument("--sig", help="the signature file (default: SHA256SUMS.sig beside the sums)")
    parser.add_argument("--keys", action="append", default=[], help="a trusted-keys file (repeatable)")
    parser.add_argument("--quiet", action="store_true", help="say nothing on success")
    arguments = parser.parse_args(argv)
    if not arguments.sums:
        parser.error("--sums is required")
    path = arguments.sums
    if os.path.isdir(path):
        path = os.path.join(path, "SHA256SUMS")
    try:
        key_id = verify_release(path, arguments.sig, arguments.keys)
    except VerificationError as error:
        sys.stderr.write("release_unsigned_or_forged: %s\n" % error.message)
        return error.code
    if not arguments.quiet:
        sys.stdout.write("release signature verified: %s (%s)\n" % (key_id, path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
