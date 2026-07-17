// gemma.mjs — MLX Gemma 4 E4B (4-bit) backend, S1's second candidate.
//
// Model chosen: mlx-community/gemma-4-e4b-it-4bit
//   - https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit
//   - Un-gated (mlx-community org — no google/gemma-4-E4B-it license gate,
//     verified reachable without an HF token), 4-bit (group_size 64,
//     affine), ~5.15 GB on disk (includes an unused audio+vision tower —
//     see below).
//   - Gemma 4 E4B: elastic/MatFormer family, ~4.5B *effective* active
//     params, 128K context — the full transcript fits in a single pass, no
//     chunking needed (unlike apple.mjs's ~4k-token FoundationModels path).
//   - Published as a multimodal ("Gemma4ForConditionalGeneration", with
//     audio_config + image/audio token ids) checkpoint, but mlx_lm's own
//     gemma4.py Model class strips vision_tower/audio_tower/
//     multi_modal_projector/embed_vision/embed_audio weights in
//     `sanitize()` and loads only `language_model` (gemma4_text.py) —
//     confirmed by reading the installed mlx_lm source, not assumed. So
//     `mlx_lm.load()` here is a pure text-generation load despite the
//     repo's "image-text-to-text" pipeline tag; the extra vision/audio
//     bytes are downloaded (part of the 5.15 GB) but never used.
//   - Downloads on first use via mlx_lm's HF cache; not committed.
//
// Runs via lib/backends/mlxShared.mjs -> mlx_runner.py, same as mlx.mjs.

import { runMlx } from './mlxShared.mjs';

export const MODEL_ID = 'mlx-community/gemma-4-e4b-it-4bit';

export async function run({ system, user }, opts = {}) {
  return runMlx(MODEL_ID, { system, user }, opts);
}
