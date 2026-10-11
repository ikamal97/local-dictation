#!/bin/zsh
# Fine-tunes the cleanup model on your own dictation history and installs it for the app.
#
#   1. Export pairs from Wispr Flow     (export_wispr.py)
#   2. LoRA fine-tune LFM2.5 1.2B       (mlx-lm, on the Mac's GPU)
#   3. Fuse, fix conv layout, convert   (llama.cpp's GGUF converter)
#   4. Install to ~/Library/Application Support/LocalDictation/models/cleanup.gguf
#
# Needs: uv (https://docs.astral.sh/uv/), git, ~8 GB free disk. Takes ~30 min on an M-series Mac.
set -euo pipefail
cd "$(dirname "$0")"
WORK=${WORK:-work}
BASE=mlx-community/LFM2.5-1.2B-Instruct-4bit
mkdir -p "$WORK"

if [[ ! -d "$WORK/.venv-mlx" ]]; then
    uv venv -q --python 3.12 "$WORK/.venv-mlx"
    uv pip install -q --python "$WORK/.venv-mlx" mlx-lm jiwer
fi
if [[ ! -d "$WORK/llama.cpp" ]]; then
    git clone -q --depth 1 https://github.com/ggml-org/llama.cpp.git "$WORK/llama.cpp"
    uv venv -q --python 3.12 "$WORK/.venv-convert"
    uv pip install -q --python "$WORK/.venv-convert" -r "$WORK/llama.cpp/requirements/requirements-convert_hf_to_gguf.txt"
fi

"$WORK/.venv-mlx/bin/python" export_wispr.py --out "$WORK"

# Batch 4 with gradient checkpointing fits comfortably in 24 GB of unified memory.
"$WORK/.venv-mlx/bin/mlx_lm.lora" --model "$BASE" --train --data "$WORK/data" \
    --iters 1000 --batch-size 4 --grad-checkpoint --num-layers 16 --learning-rate 5e-5 \
    --mask-prompt --max-seq-length 768 --steps-per-eval 200 --save-every 250 \
    --adapter-path "$WORK/adapters"

"$WORK/.venv-mlx/bin/mlx_lm.fuse" --model "$BASE" --adapter-path "$WORK/adapters" \
    --dequantize --save-path "$WORK/fused"
# Older transformers releases used by the converter don't know this tokenizer class name.
sed -i '' 's/"tokenizer_class": *"TokenizersBackend"/"tokenizer_class": "PreTrainedTokenizerFast"/' "$WORK/fused/tokenizer_config.json"
"$WORK/.venv-convert/bin/python" fix_conv_layout.py "$WORK/fused"
(cd "$WORK/llama.cpp" && ../.venv-convert/bin/python convert_hf_to_gguf.py ../fused --outtype q8_0 --outfile ../cleanup.gguf)

DEST="$HOME/Library/Application Support/LocalDictation/models"
mkdir -p "$DEST"
cp "$WORK/cleanup.gguf" "$DEST/cleanup.gguf"
echo "Installed $DEST/cleanup.gguf — restart Local Dictation to use it."
echo "Optional: benchmark it with bench_cleanup.py (see README)."
