"""Benchmark a GGUF cleanup model with llama.cpp (the same runtime the app uses).

Feeds Wispr Flow's raw ASR text for each benchmark clip through the model and compares the
result with Wispr's formatted text. Also flags outputs whose length drifted far from the
input, which usually means dropped or invented content.

Usage:
  llama-server -m work/cleanup.gguf --port 8089 -ngl 99 &     # brew install llama.cpp
  python bench_cleanup.py --work work/
"""
import argparse
import json
import re
import time
import urllib.request
from pathlib import Path

import jiwer


def clean(raw, port):
    body = json.dumps({
        "prompt": f"### Input:\n{raw}\n\n### Output:\n", "temperature": 0,
        "n_predict": int(len(raw.split()) * 2.5) + 32, "stop": ["###"], "cache_prompt": False,
    }).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/completion", body, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request))["content"].strip()


def content(text):
    text = (text or "").lower().replace("’", "'")
    return " ".join(re.sub(r"[^a-z0-9' ]+", " ", text).split())


def styled(text):
    """Keeps case and punctuation as separate tokens, so formatting differences count."""
    return " ".join(re.findall(r"[A-Za-z0-9']+|[.,?!:;]", (text or "").replace("’", "'")))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", type=Path, default=Path("work"))
    parser.add_argument("--port", type=int, default=8089)
    args = parser.parse_args()

    meta = [m for m in json.loads((args.work / "bench/meta.json").read_text())
            if (m["wispr_asr"] or "").strip() and (m["wispr_formatted"] or "").strip()]
    rows = []
    for m in meta:
        start = time.perf_counter()
        out = clean(m["wispr_asr"], args.port)
        rows.append((m["wispr_asr"], out, m["wispr_formatted"], time.perf_counter() - start))

    refs = [r[2] for r in rows]
    latencies = sorted(r[3] for r in rows)
    drifted = sum(1 for raw, out, _, _ in rows if not 0.6 <= len(out.split()) / max(1, len(raw.split())) <= 1.4)
    print(f"content WER {jiwer.wer([content(x) for x in refs], [content(r[1]) or 'x' for r in rows]):.3f} | "
          f"styled WER {jiwer.wer([styled(x) for x in refs], [styled(r[1]) or 'x' for r in rows]):.3f} | "
          f"median {latencies[len(latencies) // 2]:.2f} s | length drift: {drifted}/{len(rows)}")


if __name__ == "__main__":
    main()
