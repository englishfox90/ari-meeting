// mlxShared.mjs — shared subprocess driver for the two MLX backends
// (mlx.mjs = Qwen-MLX, gemma.mjs = Gemma-E4B-MLX). Both shell out to
// mlx_runner.py via `uv run --with mlx-lm`, per the project convention
// already used by tools/diarization_calibrate.py for ad-hoc Python deps —
// no committed venv, no product-code dependency.
//
// Sampling note (fairness — see README "Adding the MLX backends" section):
// we pass temperature=0.5, top_p=0.8 to mirror the two knobs
// llama.mjs's QWEN35_SUMMARY_SAMPLING uses for the GGUF baseline. mlx_lm's
// sampler (mlx_lm.sample_utils.make_sampler) has no direct equivalent of
// llama.cpp's presence_penalty/repeat_penalty, so those are NOT replicated
// here — this is a real, acknowledged asymmetry between the GGUF and MLX
// paths, not an oversight.

import { spawn } from 'node:child_process';
import path from 'node:path';

const RUNNER_PATH = path.resolve(import.meta.dirname, 'mlx_runner.py');

export const DEFAULT_MLX_MAX_TOKENS = 4096;
export const DEFAULT_MLX_TEMPERATURE = 0.5;
export const DEFAULT_MLX_TOP_P = 0.8;

/**
 * Run one {system, user} pair through mlx_runner.py for the given HF model
 * repo id. Returns {text, latencyMs, loadMs, peakRssMb, model}.
 */
export function runMlx(modelId, { system, user }, opts = {}) {
  const maxTokens = opts.maxTokens || DEFAULT_MLX_MAX_TOKENS;
  const temperature = opts.temperature ?? DEFAULT_MLX_TEMPERATURE;
  const topP = opts.topP ?? DEFAULT_MLX_TOP_P;
  const timeoutMs = opts.timeoutMs || 1_800_000; // 30 min — first run per model downloads several GB

  const request = {
    model: modelId,
    system,
    user,
    max_tokens: maxTokens,
    temperature,
    top_p: topP,
  };

  return new Promise((resolve, reject) => {
    const child = spawn('uv', ['run', '--with', 'mlx-lm', 'python3', RUNNER_PATH], {
      stdio: ['pipe', 'pipe', 'inherit'], // stderr inherited so download progress/tracebacks are visible live
      cwd: path.dirname(RUNNER_PATH),
    });

    let stdout = '';
    let settled = false;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        child.kill('SIGKILL');
        reject(new Error(`mlx_runner.py timed out after ${timeoutMs}ms (model ${modelId})`));
      }
    }, timeoutMs);

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString('utf8');
    });

    child.on('error', (err) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(new Error(`Failed to spawn 'uv' for mlx_runner.py: ${err.message}. Is uv installed?`));
      }
    });

    child.on('exit', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);

      // mlx_runner.py prints exactly one JSON object as its last stdout line.
      const lines = stdout.trim().split('\n').filter((l) => l.trim().length > 0);
      const lastLine = lines[lines.length - 1];
      let parsed;
      try {
        parsed = lastLine ? JSON.parse(lastLine) : null;
      } catch {
        parsed = null;
      }

      if (!parsed) {
        reject(
          new Error(
            `mlx_runner.py (model ${modelId}) produced no parseable JSON output (exit code ${code}). ` +
              `Raw stdout tail: ${stdout.slice(-500)}`,
          ),
        );
        return;
      }
      if (parsed.error) {
        reject(new Error(`mlx_runner.py (model ${modelId}) error: ${parsed.error}`));
        return;
      }
      resolve({
        text: parsed.text,
        latencyMs: parsed.latency_ms,
        loadMs: parsed.load_ms,
        peakRssMb: parsed.peak_rss_mb,
        model: parsed.model,
      });
    });

    child.stdin.write(JSON.stringify(request));
    child.stdin.end();
  });
}
