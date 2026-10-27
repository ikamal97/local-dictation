# Training your own cleanup model

Local Dictation's cleanup step uses a small language model fine-tuned on one person's
dictation history. That model isn't distributed: it was trained on private dictations and
could reproduce them. Without it, the app still works and falls back to rule-based cleanup
(filler words, dictionary, spacing). This folder rebuilds the model from **your** history.

## Requirements

- An Apple Silicon Mac with 16 GB+ of memory
- [uv](https://docs.astral.sh/uv/) and git
- A Wispr Flow history on this Mac (`~/Library/Application Support/Wispr Flow/flow.sqlite`).
  It's opened read-only. Any source of raw-ASR → cleaned-text pairs works if you write the
  same `data/train.jsonl` format (see `export_wispr.py`).

## Train

```sh
./train.sh
```

The script:

1. Exports raw → formatted pairs (`data/`) and a held-out benchmark set of dictations that
   kept their audio (`bench/`). Benchmark dictations are never used for training.
2. LoRA fine-tunes [LFM2.5 1.2B Instruct](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct)
   with mlx-lm (1,000 steps, batch 4, lr 5e-5, last 16 layers).
3. Fuses the adapter, fixes the conv weight layout for llama.cpp, and converts to 8-bit GGUF.
4. Installs it to `~/Library/Application Support/LocalDictation/models/cleanup.gguf`.

Everything lands in `training/work/` (git-ignored).

## Benchmark

```sh
# Speech-to-text, through FluidAudio's CLI
git clone https://github.com/FluidInference/FluidAudio && (cd FluidAudio && swift build -c release --product fluidaudiocli)
work/.venv-mlx/bin/python bench_asr.py --cli FluidAudio/.build/release/fluidaudiocli

# Cleanup, through llama.cpp
brew install llama.cpp
llama-server -m work/cleanup.gguf --port 8089 -ngl 99 &
work/.venv-mlx/bin/python bench_cleanup.py
```

### Benchmarking on your own dictations

Turn on **Settings → Data → Save audio for accuracy testing**. Each take is then kept in
`~/Library/Application Support/LocalDictation/recordings/` as `<history id>.wav` (16 kHz mono)
and `<history id>.json` (Parakeet's raw text and sample range per segment, the cleaned and
pasted text, latency). Recordings are deleted with their history entry, and after 30 days or
once they pass 1 GB, oldest first.

```sh
python3 export_local.py --out work/local    # adds new takes; keeps clips and labels already exported
# Fill in "reference" in work/local/bench/meta.json with what you actually said
work/.venv-mlx/bin/python bench_asr.py --cli FluidAudio/.build/release/fluidaudiocli --work work/local
```

`bench_asr.py` scores only clips with a reference, and also reports the WER of the text the
app produced at the time (`asr`, transcribed segment by segment).

## What I found

On 130 held-out recordings (44 minutes), cleaning up Parakeet's transcripts of each
recording (`bench_cleanup.py` uses Wispr's raw transcripts instead, so its numbers differ slightly):

| Cleanup model | Content WER vs. Wispr's output | Notes |
|---|---|---|
| Raw transcript, no cleanup | 19.5 % | |
| Off-the-shelf 350M cleanup model | 17.1 % | Fast, but sometimes drops content |
| Qwen3 4B Instruct, prompted | 15.0 % | Faithful, but 1–3 s per dictation |
| 350M fine-tuned on history | 20.3 % | Too small; occasionally invents text |
| **LFM2.5 1.2B fine-tuned on history** | **10.5 %** | No dropped or invented content |

About 4 points of the remaining gap are speech-recognition differences, not cleanup.
