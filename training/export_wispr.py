"""Export training pairs and a benchmark set from a local Wispr Flow database.

Wispr Flow keeps each dictation's raw ASR text and its formatted output, which makes a
ready-made dataset for teaching a small model your own cleanup style. Dictations that
also kept their audio become the held-out benchmark set and are excluded from training.

The database is opened read-only (immutable); Wispr Flow's data is never modified.

Usage: python export_wispr.py --out work/
"""
import argparse
import json
import random
import sqlite3
from pathlib import Path

DEFAULT_DB = Path.home() / "Library/Application Support/Wispr Flow/flow.sqlite"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    db = sqlite3.connect(f"file:{args.db}?immutable=1", uri=True)
    clips_dir = args.out / "bench" / "clips"
    clips_dir.mkdir(parents=True, exist_ok=True)

    # Benchmark set: dictations whose audio was saved.
    meta, held_out = [], set()
    rows = db.execute(
        "SELECT transcriptEntityId, audio, asrText, formattedText, duration FROM History "
        "WHERE audio IS NOT NULL AND length(audio) > 0 ORDER BY timestamp DESC"
    ).fetchall()
    for i, (tid, audio, asr, formatted, duration) in enumerate(rows):
        path = clips_dir / f"{i:03d}.wav"
        path.write_bytes(audio)
        held_out.add(tid)
        meta.append(dict(id=i, file=str(path), wispr_asr=asr, wispr_formatted=formatted, duration=duration))
    (args.out / "bench" / "meta.json").write_text(json.dumps(meta, indent=1))

    # Training pairs: raw ASR -> formatted text, in the completion format the app uses.
    examples = []
    for tid, raw, formatted in db.execute(
        "SELECT transcriptEntityId, asrText, formattedText FROM History "
        "WHERE length(asrText) > 0 AND length(formattedText) > 0"
    ):
        if tid in held_out:
            continue
        raw, formatted = raw.strip(), formatted.strip()
        ratio = len(formatted.split()) / max(1, len(raw.split()))
        # Skip command-mode rewrites and other outliers that aren't plain cleanup.
        if not 0.4 <= ratio <= 1.3 or len(raw.split()) > 400:
            continue
        examples.append({"prompt": f"### Input:\n{raw}\n\n### Output:\n", "completion": f"{formatted}\n###"})

    random.seed(0)
    random.shuffle(examples)
    n_valid = max(150, len(examples) // 20)
    data_dir = args.out / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    for name, part in (("valid", examples[:n_valid]), ("train", examples[n_valid:])):
        with open(data_dir / f"{name}.jsonl", "w") as fh:
            for example in part:
                fh.write(json.dumps(example) + "\n")

    print(f"{len(examples) - n_valid} training pairs, {n_valid} validation pairs, {len(meta)} benchmark clips -> {args.out}")


if __name__ == "__main__":
    main()
