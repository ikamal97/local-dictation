"""Convert LFM2 short-conv weights from MLX layout to Hugging Face layout, in place.

MLX stores conv1d weights as (out, kernel, in); llama.cpp's converter expects the
Hugging Face layout (out, in, kernel). Without this, llama.cpp refuses to load the model
("tensor 'blk.0.shortconv.conv.weight' has wrong shape").

Usage: python fix_conv_layout.py <model-dir>
"""
import sys
from pathlib import Path

from safetensors.torch import load_file, save_file

for path in Path(sys.argv[1]).glob("model*.safetensors"):
    tensors = load_file(path)
    fixed = 0
    for key, value in tensors.items():
        if key.endswith("conv.weight") and value.dim() == 3 and value.shape[2] == 1:
            tensors[key] = value.permute(0, 2, 1).contiguous()
            fixed += 1
    save_file(tensors, path, metadata={"format": "pt"})
    print(f"{path.name}: fixed {fixed} conv weights")
