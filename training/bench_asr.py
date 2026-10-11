"""Benchmark Parakeet (via FluidAudio's CLI, the same engine the app uses) on exported clips.

Word error rate is measured against Wispr Flow's raw ASR text for the same audio, after
normalizing case, punctuation and filler words.

Usage:
  (cd <FluidAudio checkout> && swift build -c release --product fluidaudiocli)
  python bench_asr.py --cli <FluidAudio>/.build/release/fluidaudiocli --work work/ [--model v3]
"""
import argparse
import json
import re
import statistics
import subprocess
import tempfile
from pathlib import Path

import jiwer


def normalize(text):
    text = (text or "").lower().replace("’", "'")
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    text = re.sub(r"\b(um+|uh+|erm|hmm+|mm+|ah)\b", " ", text)
    return " ".join(text.split())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--work", type=Path, default=Path("work"))
    parser.add_argument("--model", default="v3")
    args = parser.parse_args()

    meta = json.loads((args.work / "bench/meta.json").read_text())
    refs, hyps, fast = [], [], []
    with tempfile.TemporaryDirectory() as tmp:
        for m in meta:
            out = Path(tmp) / f"{m['id']}.json"
            subprocess.run([args.cli, "transcribe", m["file"], "--model-version", args.model, "--output-json", str(out)],
                           check=True, capture_output=True)
            result = json.loads(out.read_text())
            if (m["duration"] or 0) <= 20:
                fast.append(result["processingTimeSeconds"])
            if normalize(m["wispr_asr"]):
                refs.append(normalize(m["wispr_asr"]))
                hyps.append(normalize(result["text"]) or "x")

    print(f"{args.model}: WER vs Wispr raw ASR {jiwer.wer(refs, hyps):.3f} | "
          f"clips <= 20 s: median {statistics.median(fast):.3f} s, max {max(fast):.3f} s")


if __name__ == "__main__":
    main()
