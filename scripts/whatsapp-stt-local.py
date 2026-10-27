"""Offline original-language recognition. --worker keeps one multilingual model warm.
No translation/provider fallback; provision the private model cache separately.

Speed knobs (environment, read once at start; see docs/WHATSAPP-TRANSCRIPTION.md):
  WA_WHATSAPP_STT_MODEL           model name in the private cache (default "small")
  WA_WHATSAPP_STT_BEAM            beam size for tier 0 (default 1 = greedy)
  WA_WHATSAPP_STT_THREADS         CTranslate2 CPU threads (default: usable CPU count)
  WA_WHATSAPP_STT_FALLBACK_MODEL  cheaper model for the last fallback tier (default: none)
The worker protocol is one JSON request per stdin line. While decoding it writes
{"progress":...} lines (timings only, never text) so the Go side can tell a slow
decode from a stuck one, then exactly one final {"ok":...} line per request.
"""
import argparse
import json
import os
import sys

for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

KNOWN_ERRORS = {"WA_WHATSAPP_STT_MODELS_required", "faster_whisper_missing", "offline_model_unavailable",
                "fallback_model_unavailable", "request_too_large", "cross_language_translation_unsupported",
                "language_must_be_en_pt_auto", "audio_too_large", "transcript_too_long", "no_speech_detected"}


def env_int(name, default, low, high):
    try:
        value = int(os.environ.get(name, ""))
    except ValueError:
        return default
    return min(max(value, low), high)


def cpu_count():
    # The cores this process may actually run on (cgroup/affinity), not the host total.
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except (AttributeError, OSError):
        return max(1, os.cpu_count() or 1)


def beam_size():
    return env_int("WA_WHATSAPP_STT_BEAM", 1, 1, 10)


def load_model(name=None):
    cache = os.environ.get("WA_WHATSAPP_STT_MODELS")
    if not cache or not os.path.isdir(cache):
        raise ValueError("WA_WHATSAPP_STT_MODELS_required")
    os.environ["HF_HUB_OFFLINE"] = "1"
    try:
        from faster_whisper import WhisperModel
    except ImportError as error:
        raise RuntimeError("faster_whisper_missing") from error
    try:
        # cpu_threads defaults to 4 inside CTranslate2; on a 2-core host that
        # oversubscribes and is slower, so pin it to the usable cores.
        return WhisperModel(name or os.environ.get("WA_WHATSAPP_STT_MODEL", "small"),
                            device="cpu", compute_type="int8",
                            cpu_threads=env_int("WA_WHATSAPP_STT_THREADS", cpu_count(), 1, 64),
                            download_root=cache, local_files_only=True)
    except Exception as error:
        raise RuntimeError("offline_model_unavailable") from error


def decode_options(tier):
    # Tier 0 is the configured decode. Later tiers exist only for audio that has
    # genuinely failed before: greedy, no temperature re-decode (the 0.2..1.0
    # fallback re-runs a whole window and is the slow path on hallucination loops),
    # and finally no timestamp tokens.
    options = {"beam_size": beam_size()}
    if tier >= 1:
        options.update(beam_size=1, temperature=0.0)
    if tier >= 2:
        options["without_timestamps"] = True
    return options


def recognize(model, request, progress=None):
    if request.get("mode", "transcribe") != "transcribe":
        raise ValueError("cross_language_translation_unsupported")
    language = request.get("language", "en")
    if language not in ("en", "pt", "auto"):
        raise ValueError("language_must_be_en_pt_auto")
    path = request["input"]
    if os.path.getsize(path) > 20 * 1024 * 1024:
        raise ValueError("audio_too_large")
    tier = request.get("tier", 0)
    if not isinstance(tier, int) or tier < 0:
        tier = 0
    segments, info = model.transcribe(
        path, task="transcribe", language=None if language == "auto" else language,
        vad_filter=True, vad_parameters={"min_silence_duration_ms": 300},
        condition_on_previous_text=False, **decode_options(tier))
    duration = float(getattr(info, "duration", 0) or 0)
    if progress:
        progress(0.0, duration)  # decoded + VAD + language detection finished
    parts = []
    count = 0
    for segment in segments:
        text = segment.text.strip()
        count += len(text)
        if count > 12000:
            raise ValueError("transcript_too_long")
        parts.append(text)
        if progress:
            progress(float(getattr(segment, "end", 0) or 0), duration)
    transcript = " ".join(filter(None, parts)).strip()
    if not transcript:
        raise ValueError("no_speech_detected")
    return {"ok": True, "transcript": transcript, "language": info.language,
            "local_only": True, "mode": "transcribe", "tier": tier, "duration": round(duration, 1)}


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def progress_line(at, duration):
    emit({"progress": True, "at": round(at, 1), "duration": round(duration, 1)})


class Models:
    """One warm primary model, loaded at worker start; the optional fallback model
    loads only when a request actually reaches the last tier."""

    def __init__(self):
        self.primary = None
        self.fallback = None

    def preload(self):
        try:
            self.primary = load_model()
            emit({"progress": True, "ready": True})
        except Exception:
            pass  # Reported on the next request, as before; a missing cache is not a crash.

    def for_request(self, request):
        name = os.environ.get("WA_WHATSAPP_STT_FALLBACK_MODEL", "")
        if request.get("tier", 0) >= 2 and name:
            if self.fallback is None:
                try:
                    self.fallback = load_model(name)
                except Exception as error:
                    raise RuntimeError("fallback_model_unavailable") from error
            return self.fallback
        if self.primary is None:
            self.primary = load_model()
        return self.primary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--worker", action="store_true")
    args = parser.parse_args()
    if not args.worker and not args.check and not args.input:
        raise ValueError("input_required")
    if args.worker:
        models = Models()
        models.preload()
        for line in sys.stdin:
            try:
                if len(line) > 16384:
                    raise ValueError("request_too_large")
                request = json.loads(line)
                emit(recognize(models.for_request(request), request, progress_line))
            except Exception as error:
                # Private paths, library URLs and credentials must not enter logs.
                reason = str(error) if str(error) in KNOWN_ERRORS else "local_compute_unavailable"
                emit({"ok": False, "error": reason[:160]})
        return
    model = load_model()
    if args.check:
        emit({"ok": True, "model": os.environ.get("WA_WHATSAPP_STT_MODEL", "small"),
              "local_only": True, "language": os.environ.get("WA_WHATSAPP_STT_LANGUAGE", "en"),
              "mode": "transcribe", "beam": beam_size(),
              "threads": env_int("WA_WHATSAPP_STT_THREADS", cpu_count(), 1, 64)})
    else:
        emit(recognize(model, {"input": args.input,
                             "language": os.environ.get("WA_WHATSAPP_STT_LANGUAGE", "en")}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        emit({"ok": False, "error": "local_compute_unavailable"})
        sys.exit(1)
