// mlx.mjs — MLX Qwen-class 4B backend, the S1 candidate meant to match the
// app's shipped Qwen3.5-4B-Q4_K_M.gguf baseline as closely as possible.
//
// Model chosen: mlx-community/Qwen3.5-4B-MLX-4bit
//   - https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit
//   - Un-gated (mlx-community org, no Google/Qwen license gate), 4-bit
//     (group_size 64, affine) — the closest same-size, same-quant-tier MLX
//     build of the exact model the app ships, verified by reading the repo's
//     config.json directly (model_type "qwen3_5", 4-bit quantization_config).
//   - Published with a multimodal ("Qwen3_5ForConditionalGeneration",
//     image/video token ids) config, but mlx_lm's own qwen3_5.py Model class
//     strips vision weights in `sanitize()` and loads only the text tower —
//     confirmed by reading the installed mlx_lm source, not assumed. So
//     `mlx_lm.load()` here is a pure text-generation load despite the repo's
//     "image-text-to-text" pipeline tag.
//   - Downloads on first use via mlx_lm's HF cache (~/.cache/huggingface) —
//     several GB; not committed, not copied into this repo.
//
// Runs via lib/backends/mlxShared.mjs -> mlx_runner.py (uv-managed Python,
// since this Node harness has no Python deps of its own).

import { runMlx } from './mlxShared.mjs';

export const MODEL_ID = 'mlx-community/Qwen3.5-4B-MLX-4bit';

export async function run({ system, user }, opts = {}) {
  return runMlx(MODEL_ID, { system, user }, opts);
}
