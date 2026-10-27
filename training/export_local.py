"""Export a benchmark set from Local Dictation's saved takes.

With "Save audio for accuracy testing" on, the app keeps each take as recordings/<id>.wav
(16 kHz mono, pre-roll included) plus <id>.json with Parakeet's raw text per segment, the
cleaned text and what was pasted. This copies them into bench/ in the layout bench_asr.py
reads, with an empty `reference` for each clip to fill in by hand.

Re-running adds only new takes; clips and references already in meta.json are kept.

Usage: python export_local.py --out work/local [--limit 50]
"""
import argparse
import json
import shutil
from pathlib import Path

DEFAULT_DIR = Path.home() / "Library/Application Support/LocalDictation/recordings"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--recordings", type=Path, default=DEFAULT_DIR)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--limit", type=int, help="add at most N new takes, newest first")
    args = parser.parse_args()

    clips_dir = args.out / "bench" / "clips"
    clips_dir.mkdir(parents=True, exist_ok=True)
    meta_path = args.out / "bench" / "meta.json"
    # Clips already exported stay, with their labels, even after the app prunes the recording.
    old = json.loads(meta_path.read_text()) if meta_path.exists() else []
    exported = {m["id"] for m in old}

    takes = sorted(args.recordings.glob("*.json"), key=lambda p: int(p.stem), reverse=True)
    new = []
    for path in takes:
        wav = path.with_suffix(".wav")
        if int(path.stem) in exported or not wav.exists():
            continue
        if args.limit is not None and len(new) >= args.limit:
            break
        take = json.loads(path.read_text())
        clip = clips_dir / wav.name
        shutil.copyfile(wav, clip)
        segments = take["segments"]
        new.append(dict(
            id=take["id"],
            file=str(clip),
            date=take["date"],
            duration=take["audio_seconds"],
            # Parakeet's text as the app heard it, segment by segment, before filler stripping.
            asr=" ".join(s["asr"] for s in segments),
            segments=segments,
            final_text=take["final_text"],
            pasted_text=take["pasted_text"],
            latency_ms=take["latency_ms"],
            reference="",
        ))
    meta = sorted(old + new, key=lambda m: m["id"], reverse=True)
    meta_path.write_text(json.dumps(meta, indent=1, ensure_ascii=False))
    print(f"{len(new)} new, {len(meta)} clips ({sum(1 for m in meta if m['reference'])} labeled) -> {args.out / 'bench'}")


if __name__ == "__main__":
    main()
