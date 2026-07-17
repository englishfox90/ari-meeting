// llama.mjs — drives the app's built-in llama-helper sidecar to run the
// Qwen 3.5 4B GGUF summary model (the S1 BASELINE). Protocol verified against
// llama-helper/src/main.rs (2026-07-16):
//
//   Request  (stdin,  one JSON object per line): {"type":"generate", "prompt": <string>,
//     "max_tokens": i32?, "context_size": u32?, "model_path": string?,
//     "temperature": f32?, "top_k": i32?, "top_p": f32?, "presence_penalty": f32?,
//     "frequency_penalty": f32?, "repeat_penalty": f32?, "penalty_last_n": i32?,
//     "stop_tokens": string[]?, "stream": bool? }
//   Response (stdout, one JSON object per line, may include a `token` line stream
//     first when stream:true): {"type":"response", "text": string, "error": string?}
//
// Chat template + sampling ported from
// frontend/src-tauri/src/summary/summary_engine/models.rs (QWEN35_NONTHINKING_TEMPLATE,
// SamplingParams::qwen35_summary, get_available_models "qwen3.5:4b" entry, DEFAULT_MAX_TOKENS).

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';

export const DEFAULT_LLAMA_HELPER_PATH = path.resolve(
  import.meta.dirname,
  '../../../../frontend/src-tauri/binaries/llama-helper-aarch64-apple-darwin',
);

export const DEFAULT_QWEN_MODEL_PATH = path.join(
  os.homedir(),
  'Library',
  'Application Support',
  'com.meetily.ai',
  'models',
  'summary',
  'Qwen3.5-4B-Q4_K_M.gguf',
);

// --- frontend/src-tauri/src/summary/summary_engine/models.rs:257-269 (verbatim) ---
export const QWEN35_NONTHINKING_TEMPLATE =
  '<|im_start|>system\n{system_prompt}<|im_end|>\n<|im_start|>user\n{user_prompt}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n';

// --- frontend/src-tauri/src/summary/summary_engine/models.rs:272-279 (verbatim) ---
function escapeUserPromptControlMarkers(userPrompt) {
  return userPrompt
    .replaceAll('<|im_start|>', '< |im_start| >')
    .replaceAll('<|im_end|>', '< |im_end| >')
    .replaceAll('<start_of_turn>', '< start_of_turn >')
    .replaceAll('<end_of_turn>', '< end_of_turn >')
    .replaceAll('<think>', '< think >')
    .replaceAll('</think>', '< /think >');
}

/** Port of format_prompt("qwen3.5_nonthinking", ...) (models.rs:290-307). */
export function formatQwenPrompt(systemPrompt, userPrompt) {
  const escapedUser = escapeUserPromptControlMarkers(userPrompt);
  return QWEN35_NONTHINKING_TEMPLATE.replace('{system_prompt}', systemPrompt).replace(
    '{user_prompt}',
    escapedUser,
  );
}

// --- SamplingParams::qwen35_summary(["<|im_end|>"]) (models.rs:58-68) ---
export const QWEN35_SUMMARY_SAMPLING = {
  temperature: 0.5,
  top_k: 20,
  top_p: 0.8,
  presence_penalty: 0.3,
  frequency_penalty: 0.0,
  repeat_penalty: 1.05,
  penalty_last_n: 256,
  stop_tokens: ['<|im_end|>'],
};

// qwen3.5:4b ModelDef (models.rs:187-197): context_size 32768.
export const QWEN35_4B_CONTEXT_SIZE = 32768;
// models.rs:340 DEFAULT_MAX_TOKENS
export const DEFAULT_MAX_TOKENS = 4096;

/**
 * Spawn llama-helper, send exactly one `generate` request, collect the
 * terminal `response` line, then send `shutdown` and let the process exit.
 * One request per process spawn keeps this simple and correct for a batch
 * harness (no need for the app's idle-timeout keep-alive machinery).
 */
export function run({ system, user }, opts = {}) {
  const helperPath = opts.helperPath || DEFAULT_LLAMA_HELPER_PATH;
  const modelPath = opts.modelPath || DEFAULT_QWEN_MODEL_PATH;
  const contextSize = opts.contextSize || QWEN35_4B_CONTEXT_SIZE;
  const maxTokens = opts.maxTokens || DEFAULT_MAX_TOKENS;

  if (!fs.existsSync(helperPath)) {
    return Promise.reject(
      new Error(`llama-helper binary not found at ${helperPath}. Build it per build-and-run.md.`),
    );
  }
  if (!fs.existsSync(modelPath)) {
    return Promise.reject(
      new Error(`Qwen model not found at ${modelPath}. Launch the app once to auto-download it.`),
    );
  }

  const prompt = formatQwenPrompt(system, user);

  return new Promise((resolve, reject) => {
    const child = spawn(helperPath, [], { stdio: ['pipe', 'pipe', 'inherit'] });
    const rl = createInterface({ input: child.stdout });
    let settled = false;
    const timeoutMs = opts.timeoutMs || 900_000; // matches GENERATION_TIMEOUT_SECS (15 min)
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        child.kill('SIGKILL');
        reject(new Error('llama-helper timed out waiting for a response'));
      }
    }, timeoutMs);

    rl.on('line', (line) => {
      if (!line.trim()) return;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        return; // ignore non-JSON stray output (shouldn't happen; stderr is separate)
      }
      if (msg.type === 'response') {
        settled = true;
        clearTimeout(timer);
        rl.close();
        try {
          child.stdin.write(JSON.stringify({ type: 'shutdown' }) + '\n');
        } catch {
          /* process may already be exiting */
        }
        setTimeout(() => child.kill(), 2000);
        if (msg.error) {
          reject(new Error(`llama-helper generation error: ${msg.error}`));
        } else {
          resolve({ text: msg.text });
        }
      }
    });

    child.on('error', (err) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(err);
      }
    });

    child.on('exit', (code) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(new Error(`llama-helper exited early (code ${code}) with no response`));
      }
    });

    const request = {
      type: 'generate',
      prompt,
      max_tokens: maxTokens,
      context_size: contextSize,
      model_path: modelPath,
      ...QWEN35_SUMMARY_SAMPLING,
    };
    child.stdin.write(JSON.stringify(request) + '\n');
  });
}
