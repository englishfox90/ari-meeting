// apple.mjs — drives the apple-helper sidecar (Apple FoundationModels
// on-device LLM, macOS 26+ / Apple Intelligence). Protocol verified against
// apple-helper/Sources/apple-helper/Protocol.swift and main.swift (2026-07-16):
// NDJSON, camelCase, one JSON object per stdin/stdout line, each response
// carrying a distinct `type` discriminator (not a single "response" tag).
//
//   probe request:     {"type":"probe"}
//   probe response:     {"type":"probeResult","speechAvailable":bool,"foundationAvailable":bool,
//                         "osOk":bool,"appleIntelligence":bool,"speechAssetsInstalled":bool}
//   summarize request:  {"type":"summarize","text":<user prompt>,"instruction":<system prompt>,"maxTokens":N}
//   summarize response: {"type":"summarizeResult","text":string}  or  {"type":"error","message":string}
//
// Note: FoundationModels' session takes `instruction` as the session
// instructions and `text` as the prompt content (Summarize.swift composes
// "\(instruction)\n\nTranscript:\n\(text)" itself) — so we pass Call ③'s
// system prompt as `instruction` and Call ③'s user prompt (the
// <transcript_chunks>... block) as `text`, matching the Rust/Ollama backends'
// {system, user} split as closely as the sidecar's own contract allows.

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import path from 'node:path';
import fs from 'node:fs';

export const DEFAULT_APPLE_HELPER_PATH = path.resolve(
  import.meta.dirname,
  '../../../../frontend/src-tauri/binaries/apple-helper-aarch64-apple-darwin',
);

function spawnHelper(helperPath) {
  if (!fs.existsSync(helperPath)) {
    throw new Error(`apple-helper binary not found at ${helperPath}. Build it via the swift-build skill.`);
  }
  return spawn(helperPath, [], { stdio: ['pipe', 'pipe', 'inherit'] });
}

/** Send `{"type":"probe"}` and resolve with the probeResult booleans. */
export function probe(opts = {}) {
  const helperPath = opts.helperPath || DEFAULT_APPLE_HELPER_PATH;
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawnHelper(helperPath);
    } catch (err) {
      reject(err);
      return;
    }
    const rl = createInterface({ input: child.stdout });
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error('apple-helper probe timed out'));
    }, 15_000);

    rl.on('line', (line) => {
      if (!line.trim()) return;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        return;
      }
      if (msg.type === 'probeResult' || msg.type === 'error') {
        clearTimeout(timer);
        rl.close();
        child.stdin.write(JSON.stringify({ type: 'shutdown' }) + '\n');
        setTimeout(() => child.kill(), 1000);
        if (msg.type === 'error') reject(new Error(msg.message));
        else resolve(msg);
      }
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.stdin.write(JSON.stringify({ type: 'probe' }) + '\n');
  });
}

/**
 * Run one summarize call. `system` becomes FoundationModels'
 * `instruction`; `user` (the <transcript_chunks> block) becomes `text`.
 * FoundationModels has a small (~4k token) context window in practice — the
 * app itself gates BuiltInAI/AppleFoundation chunking on this
 * (service.rs: AppleFoundation -> 3500 token_threshold) — so this backend is
 * expected to fail loudly on long real transcripts rather than silently
 * truncate; that failure is itself useful S1 signal, not a harness bug.
 */
export function run({ system, user }, opts = {}) {
  const helperPath = opts.helperPath || DEFAULT_APPLE_HELPER_PATH;
  const maxTokens = opts.maxTokens || 2048;

  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawnHelper(helperPath);
    } catch (err) {
      reject(err);
      return;
    }
    const rl = createInterface({ input: child.stdout });
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error('apple-helper summarize timed out'));
    }, opts.timeoutMs || 120_000);

    rl.on('line', (line) => {
      if (!line.trim()) return;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        return;
      }
      if (msg.type === 'summarizeResult') {
        clearTimeout(timer);
        rl.close();
        child.stdin.write(JSON.stringify({ type: 'shutdown' }) + '\n');
        setTimeout(() => child.kill(), 1000);
        resolve({ text: msg.text });
      } else if (msg.type === 'error') {
        clearTimeout(timer);
        rl.close();
        child.stdin.write(JSON.stringify({ type: 'shutdown' }) + '\n');
        setTimeout(() => child.kill(), 1000);
        reject(new Error(msg.message));
      }
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`apple-helper exited early (code ${code}) with no response`));
    });

    child.stdin.write(
      JSON.stringify({ type: 'summarize', text: user, instruction: system, maxTokens }) + '\n',
    );
  });
}
