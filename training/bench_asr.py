"""Benchmark Parakeet (via FluidAudio's CLI, the same engine the app uses) on exported clips.

Word error rate is measured, after normalizing case, punctuation and filler words, against
each clip's hand-written `reference` when it has one, otherwise Wispr Flow's raw ASR text
(export_wispr.py). Clips with neither are skipped. For sets from export_local.py, the app's
own segmented transcript (`asr`) is scored too.

Usage:
  (cd <FluidAudio checkout> && swift build -c release --product fluidaudiocli)
  python bench_asr.py --cli <FluidAudio>/.build/release/fluidaudiocli --work work/ [--model v3]
  python bench_asr.py --cli ... --work work/local     # after export_local.py --out work/local
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
    meta = [m for m in meta if normalize(m.get("reference") or m.get("wispr_asr"))]
    refs, hyps, app_hyps, fast = [], [], [], []
    with tempfile.TemporaryDirectory() as tmp:
        for m in meta:
            out = Path(tmp) / f"{m['id']}.json"
            subprocess.run([args.cli, "transcribe", m["file"], "--model-version", args.model, "--output-json", str(out)],
                           check=True, capture_output=True)
            result = json.loads(out.read_text())
            if (m["duration"] or 0) <= 20:
                fast.append(result["processingTimeSeconds"])
            refs.append(normalize(m.get("reference") or m["wispr_asr"]))
            hyps.append(normalize(result["text"]) or "x")
            if "asr" in m:
                app_hyps.append(normalize(m["asr"]) or "x")

    print(f"{args.model}: {len(refs)} clips, WER {jiwer.wer(refs, hyps):.3f} | "
          f"clips <= 20 s: median {statistics.median(fast):.3f} s, max {max(fast):.3f} s")
    if len(app_hyps) == len(refs):
        print(f"app (segmented, as dictated): WER {jiwer.wer(refs, app_hyps):.3f}")


if __name__ == "__main__":
    main()
