#!/usr/bin/env python3
"""A fake faster-whisper worker for `scripts/test-stt-two-nodes.sh`.

`rust/wa-kernel-runtime/src/service_stt.rs` runs the recognizer as
`<python> <worker> --worker`, writes one JSON request per line to its stdin and reads JSON lines from
its stdout. This script speaks exactly that protocol and nothing else: no model, no audio decoding.
It exists so that two real `wa` processes can be exercised end to end - the producer's own warm
worker, the `stt_worker` node's worker, the signed relay between them - without a model cache on the
test machine.

Privacy of the test itself: it prints no audio, only a digest. `WA_TEST_STT_LOG` gets one line per
decode (`<tag> <sha256 of the audio> <language>`), which is how the test tells which process decoded
which note. `WA_TEST_STT_TAG` names the node (`local` on the producer, `worker` on the other).

Knobs (all optional):
  WA_TEST_STT_LOG          file to append one line per decode to (default: no log)
  WA_TEST_STT_TAG          the tag written in that line (default: "stt")
  WA_TEST_STT_SEGMENTS     progress lines per decode (default 2)
  WA_TEST_STT_SEGMENT_MS   milliseconds of "decode" per segment (default 200)
  WA_TEST_STT_SLOW_SEGMENTS    progress lines when the audio contains b"SLOW" (default 12)
  WA_TEST_STT_SLOW_SEGMENT_MS  milliseconds per segment in that mode (default 500)
  WA_TEST_STT_FAIL         "1" makes the decode fail once every request after the segments
  WA_TEST_STT_READY        "0" suppresses the `ready` line (default: sent once, on the first request)
"""
import hashlib
import json
import os
import sys
import time

TAG = os.environ.get("WA_TEST_STT_TAG", "stt")
LOG = os.environ.get("WA_TEST_STT_LOG", "")
SEGMENTS = max(0, int(os.environ.get("WA_TEST_STT_SEGMENTS", "2") or 2))
SEGMENT_MS = max(0, int(os.environ.get("WA_TEST_STT_SEGMENT_MS", "200") or 200))
SLOW_SEGMENTS = max(1, int(os.environ.get("WA_TEST_STT_SLOW_SEGMENTS", "12") or 12))
SLOW_SEGMENT_MS = max(0, int(os.environ.get("WA_TEST_STT_SLOW_SEGMENT_MS", "500") or 500))
FAIL = os.environ.get("WA_TEST_STT_FAIL", "") == "1"
READY = os.environ.get("WA_TEST_STT_READY", "1") != "0"


def log(line):
    if not LOG:
        return
    with open(LOG, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")
        handle.flush()


def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


def main():
    # The recognizer is started once and kept warm; the hub never writes a request line for a warm.
    ready_sent = False
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            emit({"ok": False, "error": "worker_protocol"})
            continue
        if READY and not ready_sent:
            emit({"progress": True, "ready": True})
            ready_sent = True
        path = request.get("input", "")
        try:
            with open(path, "rb") as handle:
                audio = handle.read()
        except OSError:
            emit({"ok": False, "error": "audio_unreadable"})
            continue
        digest = hashlib.sha256(audio).hexdigest()
        language = request.get("language", "") or "auto"
        log("%s %s %s" % (TAG, digest, language))
        # A note whose bytes say SLOW decodes for a long time: the test kills the node in the middle
        # of it, and needs a window wide enough to be a kill mid-job and not a kill after it.
        slow = b"SLOW" in audio
        segments = SLOW_SEGMENTS if slow else SEGMENTS
        segment_ms = SLOW_SEGMENT_MS if slow else SEGMENT_MS
        duration = max(1, segments) * (segment_ms / 1000.0)
        for index in range(segments):
            time.sleep(segment_ms / 1000.0)
            emit({"progress": True, "at": (index + 1) * (segment_ms / 1000.0), "duration": duration,
                  "text": "%s segment %d" % (TAG, index + 1)})
        if FAIL:
            emit({"ok": False, "error": "worker_compute_failed"})
            continue
        # The transcript text is a canary: the node's logs must never contain it.
        emit({"ok": True, "transcript": "canary %s %s" % (TAG, digest[:12])})


if __name__ == "__main__":
    main()
