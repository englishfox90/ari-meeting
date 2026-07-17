#!/usr/bin/env python3
"""mlx_runner.py — S1 MLX inference runner used by lib/backends/mlx.mjs and
lib/backends/gemma.mjs. Not run directly by a human normally; invoked as a
subprocess via `uv run --with mlx-lm python3 mlx_runner.py` with a single
JSON object on stdin:

    {"model": "<hf-repo-id>", "system": "...", "user": "...",
     "max_tokens": 4096, "temperature": 0.5, "top_p": 0.8}

and prints exactly one JSON object to stdout on success:

    {"text": "...", "latency_ms": 12345, "peak_rss_mb": 1234.5,
     "peak_mlx_memory_gb": 3.2, "model": "<hf-repo-id>",
     "prompt_tokens": N, "generation_tokens": N}

or, on failure, prints `{"error": "..."}` to stdout and exits nonzero.

Fairness note (per the S1 brief): we do NOT hand-wrap {system, user} in
Qwen's own im_start/im_end tokens the way lib/backends/llama.mjs does for
the GGUF baseline. Instead we hand the tokenizer's own
`apply_chat_template([{role:"system",...},{role:"user",...}], tokenize=False,
add_generation_prompt=True)` — every model gets ITS OWN native chat
template, applied to the identical {system, user} content every other
backend receives. This is the one deliberate asymmetry in the comparison,
and it's the fair one: forcing Qwen's template onto Gemma (or vice versa)
would measure template mismatch, not model quality.

Both mlx-community checkpoints used by this harness (see mlx.mjs / gemma.mjs
for exact repo ids) are published as multimodal ("ForConditionalGeneration")
checkpoints, but mlx_lm's own model classes for both architectures
(`qwen3_5.py::Model.sanitize`, `gemma4.py::Model.sanitize`) explicitly strip
vision_tower/audio_tower/multi_modal_projector weights and load only the
text tower — verified by reading mlx_lm's installed source
(site-packages/mlx_lm/models/{qwen3_5,gemma4}.py), not assumed. So
`mlx_lm.load(repo_id)` here loads a pure text model despite the repo's
"image-text-to-text" pipeline tag.
"""

import json
import resource
import sys
import time


def main():
    raw = sys.stdin.read()
    try:
        req = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"invalid JSON on stdin: {e}"}))
        sys.exit(1)

    model_id = req.get("model")
    system = req.get("system", "")
    user = req.get("user", "")
    max_tokens = int(req.get("max_tokens", 4096))
    temperature = float(req.get("temperature", 0.5))
    top_p = float(req.get("top_p", 0.8))

    if not model_id:
        print(json.dumps({"error": "missing required 'model' field"}))
        sys.exit(1)

    try:
        from mlx_lm import generate, load
        from mlx_lm.sample_utils import make_sampler
    except ImportError as e:
        print(json.dumps({"error": f"mlx_lm not importable: {e}. Run via 'uv run --with mlx-lm'."}))
        sys.exit(1)

    try:
        t_load_start = time.perf_counter()
        model, tokenizer = load(model_id)
        load_ms = int((time.perf_counter() - t_load_start) * 1000)
    except Exception as e:  # noqa: BLE001 — surface any load failure verbatim to the caller
        print(json.dumps({"error": f"mlx_lm.load('{model_id}') failed: {e}"}))
        sys.exit(1)

    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]

    # Qwen's own template exposes an `enable_thinking` toggle (chat_template.jinja:
    # "if enable_thinking is defined and enable_thinking is false"). The app's
    # GGUF baseline always forces non-thinking mode (QWEN35_NONTHINKING_TEMPLATE
    # starts the assistant turn with an empty <think></think> block), so we pass
    # enable_thinking=False here too for a fair "final markdown report" comparison
    # rather than measuring reasoning-trace verbosity. Templates that don't define
    # this kwarg (Gemma's does not) simply ignore it — apply_chat_template passes
    # unknown kwargs through to Jinja as template globals, which is a no-op if
    # unreferenced.
    try:
        prompt = tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True, enable_thinking=False
        )
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"error": f"apply_chat_template failed for '{model_id}': {e}"}))
        sys.exit(1)

    sampler = make_sampler(temp=temperature, top_p=top_p)

    try:
        t_gen_start = time.perf_counter()
        text = generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=sampler,
            verbose=False,
        )
        gen_ms = int((time.perf_counter() - t_gen_start) * 1000)
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"error": f"generation failed for '{model_id}': {e}"}))
        sys.exit(1)

    # ru_maxrss is bytes on macOS, KB on Linux — this harness targets macOS
    # Apple Silicon only (per CLAUDE.md), so we assume bytes.
    peak_rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)

    result = {
        "text": text,
        "latency_ms": gen_ms,
        "load_ms": load_ms,
        "peak_rss_mb": round(peak_rss_mb, 1),
        "model": model_id,
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
