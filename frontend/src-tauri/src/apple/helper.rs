//! apple-helper sidecar manager (Phase 1: stateless `probe`).
//!
//! Design: **spawn-per-request**, not a kept-warm singleton. The only Phase-1
//! operation is a fast, stateless `probe` — there is no warm model or session
//! state worth keeping alive between calls, so the simplest correct design is to
//! spawn the resolved binary, exchange exactly one request/response line over
//! NDJSON, and let the child exit. This is deliberately SIMPLER than
//! `summary/summary_engine/sidecar.rs` (which keeps a warm llama.cpp process and
//! `nice`s it) — the apple-helper is never `nice`d and holds no warm state.
//!
//! Robustness (No-Fake-State): every failure path — binary absent, spawn error,
//! timeout, an `Error` reply, or an unrecognized reply — yields an HONEST
//! unavailable [`ProbeStatus`] (all five bools `false`) carrying a populated
//! `error` describing why. We never fabricate availability.

use std::process::Stdio;
use std::time::Duration;

use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio_util::sync::CancellationToken;

use super::protocol::{AppleRequest, AppleResponse};
use super::resolver::resolve_apple_binary;

/// Timeout for the whole probe exchange. Probe is fast; keep this short so a
/// wedged sidecar never stalls the UI.
const PROBE_TIMEOUT: Duration = Duration::from_secs(15);

/// Timeout for a summarize exchange. FoundationModels generation is far slower
/// than a probe, so this is generous — mirror `claude_cli`'s long budget.
const SUMMARIZE_TIMEOUT: Duration = Duration::from_secs(180);

/// Timeout for one `transcribe` exchange. Transcribing a single short VAD
/// segment is not instant (model warm-up + inference) but is far from minutes,
/// so this is moderate — it exists only to bound a wedged sidecar.
const TRANSCRIBE_TIMEOUT: Duration = Duration::from_secs(120);

/// Timeout for the whole `ensure_assets` stream. On-device Speech asset
/// downloads can take minutes over a slow connection, so this is very generous —
/// it exists only to bound a wedged sidecar, not the download itself.
const ENSURE_ASSETS_TIMEOUT: Duration = Duration::from_secs(900);

/// Timeout for one `embed_batch` exchange. NLEmbedding is pure CPU work and fast
/// per item, but a batch can be large — keep this generous to bound a wedged
/// sidecar without capping legitimate batches.
const EMBED_TIMEOUT: Duration = Duration::from_secs(120);

/// Availability snapshot the frontend consumes to render Apple STT/LLM status.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeStatus {
    pub speech_available: bool,
    pub foundation_available: bool,
    pub os_ok: bool,
    pub apple_intelligence: bool,
    pub speech_assets_installed: bool,
    /// None when the probe succeeded; Some(reason) when Apple STT/LLM is
    /// unavailable (binary missing, spawn/timeout failure, or an error reply).
    /// Honest No-Fake-State.
    pub error: Option<String>,
}

impl ProbeStatus {
    /// An honest "unavailable" status: all capabilities false, reason attached.
    fn unavailable(reason: impl Into<String>) -> Self {
        Self {
            speech_available: false,
            foundation_available: false,
            os_ok: false,
            apple_intelligence: false,
            speech_assets_installed: false,
            error: Some(reason.into()),
        }
    }
}

// ============================================================================
// Pure framing helpers (unit-tested WITHOUT any process / tokio)
// ============================================================================

/// Encode a request as a single JSON line WITHOUT a trailing newline (the caller
/// appends `\n` when writing to the sidecar's stdin).
pub fn encode_request(req: &AppleRequest) -> Result<String, String> {
    serde_json::to_string(req).map_err(|e| format!("failed to encode apple request: {e}"))
}

/// Parse a single NDJSON response line from the sidecar.
pub fn parse_response(line: &str) -> Result<AppleResponse, String> {
    serde_json::from_str(line.trim())
        .map_err(|e| format!("failed to parse apple response: {e} (line: {line:?})"))
}

/// Encode f32 PCM samples as base64 of their little-endian byte representation:
/// each `f32` becomes 4 little-endian bytes, then the whole buffer is
/// standard-base64 encoded (with padding). Pure; no I/O. The Swift sidecar
/// decodes the mirror shape (base64 → little-endian Float32 16 kHz mono PCM).
pub fn encode_pcm_base64(samples: &[f32]) -> String {
    use base64::Engine;
    let mut bytes = Vec::with_capacity(samples.len() * 4);
    for s in samples {
        bytes.extend_from_slice(&s.to_le_bytes());
    }
    base64::engine::general_purpose::STANDARD.encode(&bytes)
}

/// One classified step of an `ensure_assets` response stream. This is the
/// PURE decision logic — mapping a parsed [`AppleResponse`] to what the reader
/// loop should do — factored out so it can be unit-tested without any process.
#[derive(Debug, PartialEq)]
pub enum StreamStep {
    /// A real progress tick (`0.0..=1.0`) to forward to the caller.
    Progress(f64),
    /// Terminal success: `installed` reflects the sidecar's report.
    Done(bool),
    /// Terminal failure with a human-readable reason.
    Failed(String),
    /// Anything else (probe result, unknown type) — ignore for forward-compat.
    Unexpected,
}

/// Classify one streamed [`AppleResponse`] into a [`StreamStep`]. Pure; no I/O.
pub fn classify_stream(resp: AppleResponse) -> StreamStep {
    match resp {
        AppleResponse::Progress { fraction } => StreamStep::Progress(fraction),
        AppleResponse::EnsureResult { installed } => StreamStep::Done(installed),
        AppleResponse::Error { message } => StreamStep::Failed(message),
        _ => StreamStep::Unexpected,
    }
}

// ============================================================================
// Async public API
// ============================================================================

/// Probe Apple STT/LLM availability by spawning the apple-helper, sending one
/// `Probe`, and parsing one reply under a short timeout. ALWAYS returns a
/// [`ProbeStatus`] — never errors — with an honest `error` reason on any
/// failure.
pub async fn probe() -> ProbeStatus {
    match send_oneshot(&AppleRequest::Probe, PROBE_TIMEOUT, None).await {
        Ok(AppleResponse::ProbeResult {
            speech_available,
            foundation_available,
            os_ok,
            apple_intelligence,
            speech_assets_installed,
        }) => ProbeStatus {
            speech_available,
            foundation_available,
            os_ok,
            apple_intelligence,
            speech_assets_installed,
            error: None,
        },
        Ok(AppleResponse::Error { message }) => ProbeStatus::unavailable(message),
        Ok(AppleResponse::SummarizeResult { .. })
        | Ok(AppleResponse::Progress { .. })
        | Ok(AppleResponse::EnsureResult { .. })
        | Ok(AppleResponse::TranscribeResult { .. })
        | Ok(AppleResponse::EmbedResult { .. })
        | Ok(AppleResponse::Unknown) => {
            ProbeStatus::unavailable("apple-helper returned an unrecognized response type")
        }
        Err(reason) => ProbeStatus::unavailable(reason),
    }
}

/// Summarize `text` under `instruction` via the apple-helper's FoundationModels
/// `summarize` mode. Spawns the sidecar, exchanges one request/response line
/// under a generous timeout, and races against `cancellation` when provided.
/// Returns the summary text, or an honest error (No-Fake-State) on any failure.
pub async fn summarize(
    text: &str,
    instruction: &str,
    max_tokens: u32,
    cancellation: Option<&CancellationToken>,
) -> Result<String, String> {
    // Cheap pre-check so we never spawn a doomed child on an already-cancelled run.
    if let Some(token) = cancellation {
        if token.is_cancelled() {
            return Err("Summary generation was cancelled".to_string());
        }
    }

    let req = AppleRequest::Summarize {
        text: text.to_string(),
        instruction: instruction.to_string(),
        max_tokens,
    };

    match send_oneshot(&req, SUMMARIZE_TIMEOUT, cancellation).await? {
        // Strip never-legitimate placeholder timestamps the compact on-device
        // model tends to echo verbatim (e.g. literal `[MM:SS]`) before returning —
        // No-Fake-State: never surface an invented timestamp.
        AppleResponse::SummarizeResult { text } => {
            Ok(super::text_cleanup::strip_placeholder_timestamps(&text))
        }
        AppleResponse::Error { message } => Err(message),
        AppleResponse::ProbeResult { .. }
        | AppleResponse::Progress { .. }
        | AppleResponse::EnsureResult { .. }
        | AppleResponse::TranscribeResult { .. }
        | AppleResponse::EmbedResult { .. }
        | AppleResponse::Unknown => {
            Err("apple-helper returned an unrecognized response to summarize".to_string())
        }
    }
}

/// Transcribe one PCM segment via the apple-helper's SpeechAnalyzer `transcribe`
/// mode. `samples` are f32 16 kHz mono PCM; `locale` is a BCP-47 tag (e.g.
/// `"en-US"`) — the Swift side resolves the closest supported locale. Spawns the
/// sidecar, exchanges one request/response line under a moderate timeout, and
/// returns `(text, confidence)` or an honest error (No-Fake-State) on failure.
pub async fn transcribe(samples: &[f32], locale: &str) -> Result<(String, Option<f32>), String> {
    let req = AppleRequest::Transcribe {
        pcm_base64: encode_pcm_base64(samples),
        locale: locale.to_string(),
    };

    match send_oneshot(&req, TRANSCRIBE_TIMEOUT, None).await? {
        AppleResponse::TranscribeResult { text, confidence } => Ok((text, confidence)),
        AppleResponse::Error { message } => Err(message),
        AppleResponse::ProbeResult { .. }
        | AppleResponse::SummarizeResult { .. }
        | AppleResponse::Progress { .. }
        | AppleResponse::EnsureResult { .. }
        | AppleResponse::EmbedResult { .. }
        | AppleResponse::Unknown => {
            Err("apple-helper returned an unrecognized response to transcribe".to_string())
        }
    }
}

/// Embed a batch of `texts` on-device via the apple-helper's NLEmbedding
/// `embedBatch` mode. Spawns the sidecar, exchanges one request/response line
/// under a moderate timeout, and returns one vector per input (in order) or an
/// honest error (No-Fake-State) on any failure. Each vector is 512-d.
pub async fn embed_batch(texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
    let req = AppleRequest::EmbedBatch {
        texts: texts.to_vec(),
    };

    match send_oneshot(&req, EMBED_TIMEOUT, None).await? {
        AppleResponse::EmbedResult { vectors } => Ok(vectors),
        AppleResponse::Error { message } => Err(message),
        AppleResponse::ProbeResult { .. }
        | AppleResponse::SummarizeResult { .. }
        | AppleResponse::Progress { .. }
        | AppleResponse::EnsureResult { .. }
        | AppleResponse::TranscribeResult { .. }
        | AppleResponse::Unknown => {
            Err("apple-helper returned an unrecognized response to embedBatch".to_string())
        }
    }
}

/// Ensure on-device `which` assets (e.g. `"speech"`) are installed, STREAMING
/// real download progress. Spawns the sidecar, sends one `EnsureAssets` line,
/// then reads MULTIPLE response lines: zero+ `progress` ticks (each forwarded
/// verbatim to `on_progress`) followed by a terminal `ensureResult` (→ `Ok`) or
/// `error` (→ `Err`). No progress value is ever fabricated — every one comes
/// from a real `progress` line. The whole operation is bounded by a generous
/// timeout and races `cancellation` when provided (No-Fake-State on failure).
pub async fn ensure_assets(
    which: &str,
    on_progress: impl Fn(f64) + Send,
    cancellation: Option<&CancellationToken>,
) -> Result<bool, String> {
    // Cheap pre-check so we never spawn a doomed child on an already-cancelled run.
    if let Some(token) = cancellation {
        if token.is_cancelled() {
            return Err("Asset installation was cancelled".to_string());
        }
    }

    let req = AppleRequest::EnsureAssets {
        which: which.to_string(),
    };
    let stream = ensure_assets_stream(&req, &on_progress);

    if let Some(token) = cancellation {
        tokio::select! {
            r = tokio::time::timeout(ENSURE_ASSETS_TIMEOUT, stream) => {
                r.map_err(|_| {
                    format!("apple-helper timed out after {}s", ENSURE_ASSETS_TIMEOUT.as_secs())
                })?
            }
            _ = token.cancelled() => Err("Asset installation was cancelled".to_string()),
        }
    } else {
        tokio::time::timeout(ENSURE_ASSETS_TIMEOUT, stream)
            .await
            .map_err(|_| {
                format!("apple-helper timed out after {}s", ENSURE_ASSETS_TIMEOUT.as_secs())
            })?
    }
}

/// The raw spawn→send-one-line→read-MANY-lines flow for `ensure_assets`, WITHOUT
/// timeout or cancellation wrapping (that lives in [`ensure_assets`]). Uses
/// `kill_on_drop` so a dropped (cancelled/timed-out) child is terminated/reaped.
async fn ensure_assets_stream(
    req: &AppleRequest,
    on_progress: &(impl Fn(f64) + Send),
) -> Result<bool, String> {
    // 1. Resolve the binary (absence is non-fatal → honest error upstream). NO `nice`.
    let bin = resolve_apple_binary().map_err(|e| format!("apple-helper unavailable: {e}"))?;

    // 2. Spawn — stdin/stdout piped, stderr inherited.
    let mut child = tokio::process::Command::new(&bin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("failed to spawn apple-helper at {}: {e}", bin.display()))?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "failed to open apple-helper stdin".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "failed to open apple-helper stdout".to_string())?;

    // 3. Write exactly one request line, then drop stdin so the child sees EOF
    //    and can finish streaming and exit.
    let mut line = encode_request(req)?;
    line.push('\n');
    stdin
        .write_all(line.as_bytes())
        .await
        .map_err(|e| format!("failed to write apple request: {e}"))?;
    stdin
        .flush()
        .await
        .map_err(|e| format!("failed to flush apple request: {e}"))?;
    drop(stdin);

    // 4. Read response lines until a terminal step (Done/Failed) or EOF.
    let mut reader = BufReader::new(stdout);
    let mut response_line = String::new();
    loop {
        response_line.clear();
        let read = reader
            .read_line(&mut response_line)
            .await
            .map_err(|e| format!("failed to read apple response: {e}"))?;

        if read == 0 {
            // Stream ended before any terminal step — honest failure.
            let _ = child.wait().await;
            return Err("apple-helper ended without an install result".to_string());
        }

        if response_line.trim().is_empty() {
            continue;
        }

        match classify_stream(parse_response(&response_line)?) {
            StreamStep::Progress(fraction) => on_progress(fraction),
            StreamStep::Done(installed) => {
                let _ = child.wait().await;
                return Ok(installed);
            }
            StreamStep::Failed(message) => {
                let _ = child.wait().await;
                return Err(message);
            }
            // Forward-compat: ignore unexpected lines and keep reading.
            StreamStep::Unexpected => continue,
        }
    }
}

/// Generic one-shot exchange: spawn the apple-helper, send exactly one request
/// line, read exactly one response line, parse it. Bounds the whole exchange by
/// `timeout` and, when `cancellation` is provided, races against it. On timeout
/// or cancellation the child's future is dropped, and `kill_on_drop` reaps it.
async fn send_oneshot(
    req: &AppleRequest,
    timeout: Duration,
    cancellation: Option<&CancellationToken>,
) -> Result<AppleResponse, String> {
    let exchange = oneshot_exchange(req);
    if let Some(token) = cancellation {
        tokio::select! {
            r = tokio::time::timeout(timeout, exchange) => {
                r.map_err(|_| format!("apple-helper timed out after {}s", timeout.as_secs()))?
            }
            _ = token.cancelled() => Err("Summary generation was cancelled".to_string()),
        }
    } else {
        tokio::time::timeout(timeout, exchange)
            .await
            .map_err(|_| format!("apple-helper timed out after {}s", timeout.as_secs()))?
    }
}

/// The raw spawn→send-one-line→read-one-line→parse flow, WITHOUT timeout or
/// cancellation wrapping (that lives in [`send_oneshot`]). Uses `kill_on_drop`
/// so a dropped (cancelled/timed-out) child is terminated and reaped.
async fn oneshot_exchange(req: &AppleRequest) -> Result<AppleResponse, String> {
    // 1. Resolve the binary (absence is non-fatal → honest error upstream).
    let bin = resolve_apple_binary().map_err(|e| format!("apple-helper unavailable: {e}"))?;

    // 2. Spawn — stdin/stdout piped, stderr inherited. NO `nice`.
    let mut child = tokio::process::Command::new(&bin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("failed to spawn apple-helper at {}: {e}", bin.display()))?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "failed to open apple-helper stdin".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "failed to open apple-helper stdout".to_string())?;

    // 3. Write exactly one request line.
    let mut line = encode_request(req)?;
    line.push('\n');
    stdin
        .write_all(line.as_bytes())
        .await
        .map_err(|e| format!("failed to write apple request: {e}"))?;
    stdin
        .flush()
        .await
        .map_err(|e| format!("failed to flush apple request: {e}"))?;
    // Drop stdin so the child sees EOF and can exit after replying.
    drop(stdin);

    // 4. Read exactly one response line.
    let mut reader = BufReader::new(stdout);
    let mut response_line = String::new();
    let read = reader
        .read_line(&mut response_line)
        .await
        .map_err(|e| format!("failed to read apple response: {e}"))?;

    // Best-effort reap so we don't leak a zombie.
    let _ = child.wait().await;

    if read == 0 || response_line.trim().is_empty() {
        return Err("apple-helper closed without a response (process may have crashed)".to_string());
    }

    // 5. Parse the reply.
    parse_response(&response_line)
}

/// Best-effort teardown for app exit. With the spawn-per-request design there is
/// no long-lived child to stop, so this is a no-op that returns immediately —
/// it must never block app exit.
pub async fn force_shutdown() -> Result<(), String> {
    log::debug!("apple-helper: force_shutdown is a no-op (spawn-per-request design)");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_probe_is_exact_single_line() {
        let encoded = encode_request(&AppleRequest::Probe).expect("encodes");
        // No trailing newline; exact JSON shape the Swift sidecar expects.
        assert_eq!(encoded, r#"{"type":"probe"}"#);
        assert!(!encoded.ends_with('\n'));
    }

    #[test]
    fn encode_shutdown_is_exact() {
        let encoded = encode_request(&AppleRequest::Shutdown).expect("encodes");
        assert_eq!(encoded, r#"{"type":"shutdown"}"#);
    }

    #[test]
    fn parse_probe_result_line() {
        let line = include_str!("fixtures/probe_result.json");
        match parse_response(line).expect("parses") {
            AppleResponse::ProbeResult {
                speech_available,
                foundation_available,
                os_ok,
                apple_intelligence,
                speech_assets_installed,
            } => {
                assert!(speech_available);
                assert!(foundation_available);
                assert!(os_ok);
                assert!(apple_intelligence);
                assert!(!speech_assets_installed);
            }
            other => panic!("expected ProbeResult, got {other:?}"),
        }
    }

    #[test]
    fn parse_error_line() {
        let line = include_str!("fixtures/error.json");
        match parse_response(line).expect("parses") {
            AppleResponse::Error { message } => {
                assert_eq!(message, "Apple Intelligence is not enabled");
            }
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn encode_summarize_matches_fixture_shape() {
        use serde_json::Value;
        let req = AppleRequest::Summarize {
            text: "Alice: Let's ship the release on Friday. Bob: I'll finish the API by Thursday. Alice: Great, I'll handle the changelog.".to_string(),
            instruction: "Summarize the key decisions and action items from this meeting transcript.".to_string(),
            max_tokens: 512,
        };
        let encoded = encode_request(&req).expect("encodes");
        // No trailing newline (the caller appends it).
        assert!(!encoded.ends_with('\n'));
        let got: Value = serde_json::from_str(&encoded).expect("encoded is valid json");
        let want: Value =
            serde_json::from_str(include_str!("fixtures/summarize.json")).expect("fixture json");
        assert_eq!(got, want, "encoded summarize must match fixtures/summarize.json");
        // The variant-level rename must produce camelCase `maxTokens` on the wire.
        assert_eq!(got["maxTokens"], 512);
    }

    #[test]
    fn parse_summarize_result_line() {
        let line = include_str!("fixtures/summarize_result.json");
        match parse_response(line).expect("parses") {
            AppleResponse::SummarizeResult { text } => {
                assert!(text.contains("ship the release on Friday"));
            }
            other => panic!("expected SummarizeResult, got {other:?}"),
        }
    }

    #[test]
    fn parse_unknown_type_line_is_unknown_not_err() {
        let line = r#"{"type":"somethingNew","x":1}"#;
        assert_eq!(parse_response(line).expect("parses"), AppleResponse::Unknown);
    }

    #[test]
    fn parse_malformed_json_is_err() {
        assert!(parse_response("{not json").is_err());
    }

    #[test]
    fn encode_pcm_base64_of_four_zeros_is_sixteen_zero_bytes() {
        // Four f32 zeros = 16 little-endian zero bytes → 24 base64 chars (padded).
        assert_eq!(encode_pcm_base64(&[0.0; 4]), "AAAAAAAAAAAAAAAAAAAAAA==");
    }

    #[test]
    fn encode_pcm_base64_matches_transcribe_fixture() {
        // The shared fixture's pcmBase64 encodes exactly four f32 zeros.
        let fixture = include_str!("fixtures/transcribe.json");
        let req: AppleRequest = serde_json::from_str(fixture).expect("fixture parses");
        match req {
            AppleRequest::Transcribe { pcm_base64, .. } => {
                assert_eq!(encode_pcm_base64(&[0.0; 4]), pcm_base64);
            }
            other => panic!("expected Transcribe, got {other:?}"),
        }
    }

    #[test]
    fn encode_pcm_base64_is_little_endian() {
        // 1.0_f32 little-endian bytes are 00 00 80 3F.
        use base64::Engine;
        let want = base64::engine::general_purpose::STANDARD.encode([0x00, 0x00, 0x80, 0x3F]);
        assert_eq!(encode_pcm_base64(&[1.0]), want);
    }

    // ---- classify_stream (pure ensure_assets decision logic) ----

    #[test]
    fn classify_progress_line() {
        let resp = parse_response(include_str!("fixtures/progress.json")).expect("parses");
        assert_eq!(classify_stream(resp), StreamStep::Progress(0.42));
    }

    #[test]
    fn classify_ensure_result_line() {
        let resp = parse_response(include_str!("fixtures/ensure_result.json")).expect("parses");
        assert_eq!(classify_stream(resp), StreamStep::Done(true));
    }

    #[test]
    fn classify_error_line_is_failed() {
        let resp = parse_response(include_str!("fixtures/error.json")).expect("parses");
        assert_eq!(
            classify_stream(resp),
            StreamStep::Failed("Apple Intelligence is not enabled".to_string())
        );
    }

    #[test]
    fn classify_probe_result_is_unexpected() {
        let resp = parse_response(include_str!("fixtures/probe_result.json")).expect("parses");
        assert_eq!(classify_stream(resp), StreamStep::Unexpected);
    }

    #[test]
    fn classify_unknown_is_unexpected() {
        assert_eq!(classify_stream(AppleResponse::Unknown), StreamStep::Unexpected);
    }
}
