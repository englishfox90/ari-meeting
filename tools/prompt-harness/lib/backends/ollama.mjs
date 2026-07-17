// ollama.mjs — optional backend driving a local Ollama daemon.
// Degrades gracefully (throws a clear, catchable error) if Ollama isn't
// running; callers should treat that as "backend unavailable", not a harness
// bug. CRITICAL per the task brief: `options.num_ctx` MUST be set explicitly
// or Ollama silently truncates context to its ~4k default, which would
// silently corrupt long real-meeting transcripts (this bit the app itself —
// see the `token_threshold` / METADATA_CACHE.get_or_fetch dance in
// frontend/src-tauri/src/summary/service.rs, which exists specifically to
// avoid Ollama's default-context surprise).

const DEFAULT_ENDPOINT = 'http://localhost:11434';
const DEFAULT_NUM_CTX = 16384;

export async function isOllamaRunning(endpoint = DEFAULT_ENDPOINT) {
  try {
    const res = await fetch(`${endpoint}/api/tags`, { signal: AbortSignal.timeout(2000) });
    return res.ok;
  } catch {
    return false;
  }
}

export async function run({ system, user }, opts = {}) {
  const endpoint = opts.endpoint || DEFAULT_ENDPOINT;
  const model = opts.model || 'gemma3:1b';
  const numCtx = opts.numCtx || DEFAULT_NUM_CTX;

  let res;
  try {
    res = await fetch(`${endpoint}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        stream: false,
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user },
        ],
        options: { num_ctx: numCtx },
      }),
      signal: AbortSignal.timeout(opts.timeoutMs || 300_000),
    });
  } catch (err) {
    throw new Error(
      `Ollama unreachable at ${endpoint} (is the daemon running? 'ollama serve'). Original error: ${err.message}`,
    );
  }

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`Ollama request failed: ${res.status} ${res.statusText} ${body}`);
  }

  const json = await res.json();
  const text = json?.message?.content;
  if (typeof text !== 'string' || text.length === 0) {
    throw new Error(`Ollama returned no content: ${JSON.stringify(json)}`);
  }
  return { text };
}
