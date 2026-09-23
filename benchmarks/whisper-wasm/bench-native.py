"""Warm comparison with the current faster-whisper engine; benchmark only."""
import argparse
import json
import time

import numpy as np
from faster_whisper import WhisperModel


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pcm", help="16 kHz mono f32le PCM")
    parser.add_argument("model", choices=["tiny", "small"])
    parser.add_argument("model_dir")
    args = parser.parse_args()
    samples = np.fromfile(args.pcm, dtype="<f4")
    model = WhisperModel(args.model, device="cpu", compute_type="int8",
                         download_root=args.model_dir, local_files_only=True)
    for run in range(4):
        start = time.perf_counter()
        segments, _ = model.transcribe(samples, beam_size=1, vad_filter=False,
                                       language="en")
        transcript = " ".join(segment.text.strip() for segment in segments).strip()
        print(json.dumps({"run": run, "seconds": time.perf_counter() - start,
                          "transcript": transcript}), flush=True)


if __name__ == "__main__":
    main()
