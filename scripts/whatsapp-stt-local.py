"""Offline original-language recognition. --worker keeps one multilingual model warm.
No translation/provider fallback; provision the private model cache separately.
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


def load_model():
    cache = os.environ.get("WA_WHATSAPP_STT_MODELS")
    if not cache or not os.path.isdir(cache):
        raise ValueError("WA_WHATSAPP_STT_MODELS_required")
    os.environ["HF_HUB_OFFLINE"] = "1"
    try:
        from faster_whisper import WhisperModel
    except ImportError as error:
        raise RuntimeError("faster_whisper_missing") from error
    try:
        return WhisperModel(os.environ.get("WA_WHATSAPP_STT_MODEL", "small"),
                            device="cpu", compute_type="int8",
                            download_root=cache, local_files_only=True)
    except Exception as error:
        raise RuntimeError("offline_model_unavailable") from error


def recognize(model, request):
    if request.get("mode", "transcribe") != "transcribe":
        raise ValueError("cross_language_translation_unsupported")
    language = request.get("language", "en")
    if language not in ("en", "pt", "auto"):
        raise ValueError("language_must_be_en_pt_auto")
    path = request["input"]
    if os.path.getsize(path) > 20 * 1024 * 1024:
        raise ValueError("audio_too_large")
    segments, info = model.transcribe(
        path, task="transcribe", language=None if language == "auto" else language,
        beam_size=5, vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 300},
        condition_on_previous_text=False)
    parts = []
    count = 0
    for segment in segments:
        text = segment.text.strip()
        count += len(text)
        if count > 12000:
            raise ValueError("transcript_too_long")
        parts.append(text)
    transcript = " ".join(filter(None, parts)).strip()
    if not transcript:
        raise ValueError("no_speech_detected")
    return {"ok": True, "transcript": transcript, "language": info.language,
            "local_only": True, "mode": "transcribe"}


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--worker", action="store_true")
    args = parser.parse_args()
    if not args.worker and not args.check and not args.input:
        raise ValueError("input_required")
    model = None
    if args.worker:
        for line in sys.stdin:
            try:
                if len(line) > 16384:
                    raise ValueError("request_too_large")
                request = json.loads(line)
                if model is None:
                    model = load_model()
                emit(recognize(model, request))
            except Exception as error:
                # Private paths, library URLs and credentials must not enter logs.
                reason = str(error) if str(error) in {"WA_WHATSAPP_STT_MODELS_required", "faster_whisper_missing", "offline_model_unavailable", "request_too_large", "cross_language_translation_unsupported", "language_must_be_en_pt_auto", "audio_too_large", "transcript_too_long", "no_speech_detected"} else "local_compute_unavailable"
                emit({"ok": False, "error": reason[:160]})
        return
    model = load_model()
    if args.check:
        emit({"ok": True, "model": os.environ.get("WA_WHATSAPP_STT_MODEL", "small"),
              "local_only": True, "language": os.environ.get("WA_WHATSAPP_STT_LANGUAGE", "en"),
              "mode": "transcribe"})
    else:
        emit(recognize(model, {"input": args.input,
                             "language": os.environ.get("WA_WHATSAPP_STT_LANGUAGE", "en")}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        emit({"ok": False, "error": "local_compute_unavailable"})
        sys.exit(1)
