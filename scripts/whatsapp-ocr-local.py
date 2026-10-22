"""Offline OCR for journaled image messages. RapidOCR/ONNX, PT-friendly Latin model.

No network, translation, hosted fallback or media-key access. The worker keeps one
engine warm and returns plain text for the journal only; it never sends anything.
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


def load_engine():
    try:
        from rapidocr_onnxruntime import RapidOCR
    except ImportError as error:
        raise RuntimeError("rapidocr_missing") from error
    try:
        return RapidOCR()
    except Exception as error:
        raise RuntimeError("offline_model_unavailable") from error


def recognize(engine, request):
    if request.get("mode", "ocr") != "ocr":
        raise ValueError("unsupported_mode")
    path = request["input"]
    if os.path.getsize(path) > 20 * 1024 * 1024:
        raise ValueError("image_too_large")
    result, _ = engine(path)
    lines = []
    for item in result or []:
        if not isinstance(item, (list, tuple)) or len(item) < 3:
            continue
        text = item[1]
        score = item[2]
        if isinstance(text, str) and text.strip() and float(score) >= 0.5:
            lines.append(text.strip())
    text = "\n".join(lines).strip()
    if not text:
        raise ValueError("no_text_detected")
    if len(text) > 12000:
        raise ValueError("ocr_text_too_long")
    return {"ok": True, "text": text, "language": request.get("language", "pt"),
            "local_only": True, "mode": "ocr"}


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
    if args.worker:
        engine = None
        for line in sys.stdin:
            try:
                if len(line) > 16384:
                    raise ValueError("request_too_large")
                request = json.loads(line)
                if engine is None:
                    engine = load_engine()
                emit(recognize(engine, request))
            except Exception as error:
                allowed = {"rapidocr_missing", "offline_model_unavailable", "request_too_large",
                           "unsupported_mode", "image_too_large", "ocr_text_too_long", "no_text_detected"}
                reason = str(error) if str(error) in allowed else "local_compute_unavailable"
                emit({"ok": False, "error": reason[:160]})
        return
    engine = load_engine()
    if args.check:
        emit({"ok": True, "model": "rapidocr", "local_only": True,
              "language": os.environ.get("WA_WHATSAPP_OCR_LANGUAGE", "pt"), "mode": "ocr"})
    else:
        emit(recognize(engine, {"input": args.input,
                               "language": os.environ.get("WA_WHATSAPP_OCR_LANGUAGE", "pt")}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        emit({"ok": False, "error": "local_compute_unavailable"})
        sys.exit(1)
