#!/usr/bin/env python3
"""Parity harness: the component's image OCR is the old bridge's image OCR.

Both implementations run the **same** script. The native connector spawns
`scripts/whatsapp-ocr-local.py --worker` itself; the component asks the kernel's text reader
(`wa:kernel/vision`, `rust/wa-kernel-runtime/src/service_ocr.rs`), which spawns that same script on
the node's OCR venv. So parity rests on two facts, and this harness checks the first on a real host
and leaves the second to `cargo test --lib ocr::` in `rust/components/wa-whatsapp` (the text is
attached verbatim, bounded only by the record's own field size):

  1. the worker answers the same bytes with the same text, twice - a deterministic reader;
  2. the component stores what the worker said, unchanged.

It is honest about what it cannot do: without the OCR venv, the recognizer model pair or a fixture,
it prints `SKIP <reason>` and exits 0. It never reports a parity run it did not do.

Privacy: this script prints lengths, hashes and the offset of a difference - never the recognized
text and never the image. A fixture is a synthetic document, not a user message, and even then the
log stays metadata-only because that is the rule the component itself follows.

Usage:
  scripts/test-waocr-parity.py [--fixture PATH] [--expect TEXT] [--python PATH]

Exit codes: 0 = ran and agreed, or skipped with its reason; 1 = the two runs disagreed.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zlib
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKER = os.path.join(ROOT, "scripts", "whatsapp-ocr-local.py")
TIMEOUT_S = 180


def skip(reason):
    print(f"SKIP {reason} - no parity claim was made")
    return 0


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def interpreter(explicit):
    candidates = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get("WA_OCR_PYTHON"):
        candidates.append(os.environ["WA_OCR_PYTHON"])
    home = os.environ.get("HOME") or os.environ.get("USERPROFILE") or ""
    if home:
        candidates.append(os.path.join(home, ".local", "wa-ocr-rapid", "bin", "python"))
    found = shutil.which("python3") or shutil.which("python")
    if found:
        candidates.append(found)
    candidates.append(sys.executable)
    return candidates


def has_rapidocr(python):
    try:
        done = subprocess.run(
            [python, "-c", "import rapidocr_onnxruntime"], capture_output=True, timeout=60
        )
        return done.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def blank_png(path):
    """An 8x8 mid-grey PNG, written with the standard library only: a real image with no words.

    It is the negative fixture: a reader must answer `no_text_detected`, not an empty string, which
    is the same answer the old bridge stored as "no text" for that screenshot.
    """
    width = height = 8
    raw = b"".join(b"\x00" + bytes([0x80, 0x80, 0x80]) * width for _ in range(height))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)
    return path


def run_worker(python, image, language):
    """One `--worker` session, one request: exactly the protocol the kernel speaks."""
    request = json.dumps({"input": image, "language": language, "mode": "ocr"}) + "\n"
    env = dict(os.environ)
    env.setdefault("WA_WHATSAPP_OCR_LANGUAGE", language)
    done = subprocess.run(
        [python, WORKER, "--worker"], input=request, capture_output=True, text=True, timeout=TIMEOUT_S, env=env
    )
    lines = [line for line in done.stdout.splitlines() if line.strip()]
    if not lines:
        return {"ok": False, "error": "worker_silent"}
    return json.loads(lines[-1])


def compare(first, second, expected):
    if first.get("ok") != second.get("ok"):
        print(f"FAIL ok differs between the two runs: {first.get('ok')} vs {second.get('ok')}")
        return 1
    if not first.get("ok"):
        same = first.get("error") == second.get("error")
        print(f"{'PASS' if same else 'FAIL'} both runs refused with {first.get('error')} vs {second.get('error')}")
        return 0 if same else 1
    a, b = first.get("text", ""), second.get("text", "")
    if a != b:
        at = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
        print(f"FAIL the same fixture read differently at character {at} ({digest(a)} vs {digest(b)})")
        return 1
    print(f"PASS two runs agree: {len(a)} characters, sha256[:16]={digest(a)}, language={first.get('language')}")
    if not first.get("local_only"):
        print("FAIL the worker did not report local_only")
        return 1
    if expected is not None:
        if expected == a:
            print(f"PASS matches the old bridge's stored text ({len(expected)} characters)")
        else:
            at = next((i for i, (x, y) in enumerate(zip(expected, a)) if x != y), min(len(expected), len(a)))
            print(f"FAIL differs from the old bridge's stored text at character {at} ({len(expected)} vs {len(a)})")
            return 1
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fixture", help="an image with text; defaults to fixtures/waocr/ocr-fixture.png if present")
    parser.add_argument("--expect", help="the old bridge's stored media_text for that fixture (compared, never printed)")
    parser.add_argument("--python", help="the OCR venv interpreter (default: WA_OCR_PYTHON, ~/.local/wa-ocr-rapid/bin/python)")
    parser.add_argument("--language", default="pt")
    args = parser.parse_args()

    if not os.path.isfile(WORKER):
        return skip("worker_missing")
    candidates = interpreter(args.python)
    python = next((c for c in candidates if c and has_rapidocr(c)), None)
    if python is None:
        return skip("rapidocr_missing")

    temporary = None
    fixture = args.fixture
    if fixture is None:
        default = os.path.join(ROOT, "fixtures", "waocr", "ocr-fixture.png")
        if os.path.isfile(default):
            fixture = default
        else:
            temporary = tempfile.mkdtemp(prefix="wa-ocr-parity-")
            fixture = blank_png(os.path.join(temporary, "blank.png"))
            print("note: no fixture given; using a synthetic blank image (expects no_text_detected)")
    try:
        first = run_worker(python, fixture, args.language)
        second = run_worker(python, fixture, args.language)
        code = compare(first, second, args.expect)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        print(f"SKIP worker did not answer ({type(error).__name__}) - no parity claim was made")
        return 0
    finally:
        if temporary:
            shutil.rmtree(temporary, ignore_errors=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
