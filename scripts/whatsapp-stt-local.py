"""Local-only speech recognition for one WhatsApp audio file.

Install faster-whisper into a private Python environment and download the model
once during setup. Event processing uses local_files_only so a voice recording
never falls back to a hosted recognizer.
"""
import argparse
import json
import os
import sys

# A transcript is read by a UTF-8 reader, so it must be written as UTF-8.
# Python picks the *locale* encoding for a piped stdout: on Windows that is the
# ANSI code page, so `ensure_ascii=False` put a single cp1252 byte on the wire for
# each accent and the reader, decoding UTF-8, replaced every one of them with
# U+FFFD - "Area" became "<?>rea" and the text was lost, not merely garbled.
# Set the encoding here, once, for stdout and stderr alike, rather than trusting
# whatever locale the scheduler happened to hand us.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not args.check and not args.input:
        raise ValueError("input_required")
    model_name = os.environ.get("WA_WHATSAPP_STT_MODEL", "small")
    language = os.environ.get("WA_WHATSAPP_STT_LANGUAGE", "pt").strip().lower()
    if language == "auto":
        language = None
    elif language and (len(language) not in (2, 3) or not language.isalpha()):
        raise ValueError("invalid_WA_WHATSAPP_STT_LANGUAGE")
    cache = os.environ.get("WA_WHATSAPP_STT_MODELS")
    if not cache:
        raise ValueError("WA_WHATSAPP_STT_MODELS_required")
    try:
        from faster_whisper import WhisperModel
    except ImportError as error:
        raise RuntimeError("faster_whisper_missing") from error
    model = WhisperModel(model_name, device="cpu", compute_type="int8",
                         download_root=cache, local_files_only=True)
    if args.check:
        print(json.dumps({"ok": True, "model": model_name, "local_only": True}))
        return
    if os.path.getsize(args.input) > 20 * 1024 * 1024:
        raise ValueError("audio_too_large")
    segments, info = model.transcribe(
        args.input,
        language=language,
        beam_size=5,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 300},
        condition_on_previous_text=False,
    )
    parts = []
    for segment in segments:
        parts.append(segment.text.strip())
        if sum(map(len, parts)) > 12000:
            raise ValueError("transcript_too_long")
    transcript = " ".join(part for part in parts if part).strip()
    if not transcript:
        raise ValueError("no_speech_detected")
    print(json.dumps({"ok": True, "transcript": transcript,
                      "language": info.language, "local_only": True}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)[:160]}))
        sys.exit(1)
