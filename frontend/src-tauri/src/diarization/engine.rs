//! # Diarization engine — sidecar client + model/asset plumbing
//!
//! The offline "talk-to-the-sidecar" infrastructure for speaker diarization
//! (F1 in the PRD). This module is a **pure library surface** of `async fn`s that
//! the (separately-owned) orchestration + command layer awaits. It contains **no
//! Tauri commands** and does **no DB access** — the app layer owns all writes.
//!
//! ## What lives here
//!
//! - [`diarize`] / [`embed`] — spawn the `diarize-helper` sidecar and exchange
//!   exactly one NDJSON request/response line (spawn-per-request, mirroring
//!   [`crate::apple::helper`]). The sidecar wraps sherpa-onnx.
//! - [`transcode_to_16k_mono_wav`] — the app persists 48 kHz AAC
//!   (`mic.m4a` / `system.m4a` / `audio.mp4`); the sidecar requires **16 kHz mono
//!   WAV**. This is the ffmpeg file→file bridge (mirrors [`crate::audio::encode`]).
//! - [`ensure_models`] — download the two ONNX models into the app-data models
//!   dir on first use (skip if present); return their paths.
//! - [`centroid_to_bytes`] / [`bytes_to_centroid`] — opaque-BLOB round-trip for
//!   the DB layer (the matcher in [`crate::diarization::matching`] works on
//!   `Vec<f32>`).
//!
//! ## Sidecar protocol (pinned — code against this exactly)
//!
//! Request  `{"type":"embed","wav_path":"<abs>"}`
//! Response `{"type":"embedding","dim":192,"vector":[<f32>...]}`
//!
//! Request  `{"type":"diarize","wav_path":"<abs>","num_speakers":<N|null>,"threshold":<f32|null>}`
//! Response `{"type":"segments","segments":[{"start":<f64>,"end":<f64>,
//!            "speaker":"spk_0"}...],"clusters":[{"speaker":"spk_0","dim":192,
//!            "centroid":[<f32>...]}...]}`
//!
//! Errors come back as `{"type":"error","message":"..."}`. Model paths are passed
//! to the sidecar via the CLI args `--segmentation <path>` and `--embedding
//! <path>`.
//!
//! ## Best-effort
//!
//! If the `diarize-helper` binary is absent, [`diarize`]/[`embed`] return `Err`
//! (never panic). `cargo check` and app launch succeed with no binary present.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

// ============================================================================
// Model URLs (sherpa-onnx releases)
// ============================================================================

/// pyannote segmentation model, shipped as a `.tar.bz2` whose payload contains a
/// `model.onnx` we extract and cache. See [`ensure_models`].
const SEGMENTATION_MODEL_URL: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2";

/// CAM++ speaker-embedding model, a direct `.onnx`.
/// NOTE: the release tag `speaker-recongition-models` is MISSPELLED upstream and
/// is CORRECT as written — do not "fix" it or the download 404s.
const EMBEDDING_MODEL_URL: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx";

/// Cached filename for the extracted segmentation `model.onnx`.
const SEG_MODEL_FILENAME: &str = "sherpa-onnx-pyannote-segmentation-3-0.onnx";
/// Cached filename for the CAM++ embedding model (matches the download basename).
const EMB_MODEL_FILENAME: &str = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx";

// ============================================================================
// Sidecar resolution constants (mirrors apple/notch resolvers)
// ============================================================================

/// Base name of the diarization sidecar binary.
const BIN_BASE: &str = "diarize-helper";
/// The only target triple this macOS-only app ships for.
const TARGET_TRIPLE: &str = "aarch64-apple-darwin";

/// Whole-exchange budget for a `diarize` (segmentation + clustering over a full
/// meeting is slow — be generous, this is always off the hot path).
const DIARIZE_TIMEOUT: Duration = Duration::from_secs(600);
/// Whole-exchange budget for a single `embed`.
const EMBED_TIMEOUT: Duration = Duration::from_secs(120);

// ============================================================================
// Public result types (serde field names match the pinned wire JSON)
// ============================================================================

/// One diarized span: `[start, end)` seconds labelled with a per-meeting speaker
/// tag (e.g. `"spk_0"`). Speaker tags are meeting-local; cross-meeting identity
/// is resolved by [`crate::diarization::matching`] against stored centroids.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiarSegment {
    pub start: f64,
    pub end: f64,
    pub speaker: String,
}

/// A per-meeting cluster: the running centroid (voiceprint) for one meeting-local
/// speaker tag. `dim` is the embedding dimension (192 for CAM++ `campplus_sv_zh_en`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiarCluster {
    pub speaker: String,
    pub dim: i64,
    pub centroid: Vec<f32>,
}

/// The full result of a `diarize` exchange: labelled segments plus one centroid
/// per meeting-local speaker.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiarizeResult {
    pub segments: Vec<DiarSegment>,
    pub clusters: Vec<DiarCluster>,
}

// ============================================================================
// Wire request/response (private — the pinned NDJSON protocol)
// ============================================================================

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum HelperRequest {
    /// `{"type":"embed","wav_path":"<abs>"}`
    Embed { wav_path: String },
    /// `{"type":"diarize","wav_path":"<abs>","num_speakers":<N|null>,"threshold":<f32|null>}`
    /// `threshold` is the AUTO-mode clustering threshold (higher = FEWER clusters);
    /// omitted/`null` → the sidecar's default. `skip_serializing_if` keeps it out of
    /// the wire when `None` so old sidecars that don't know the field still parse.
    Diarize {
        wav_path: String,
        num_speakers: Option<i64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        threshold: Option<f32>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum HelperResponse {
    /// `{"type":"embedding","dim":192,"vector":[...]}`
    Embedding {
        #[allow(dead_code)]
        dim: i64,
        vector: Vec<f32>,
    },
    /// `{"type":"segments","segments":[...],"clusters":[...]}`
    Segments {
        segments: Vec<DiarSegment>,
        clusters: Vec<DiarCluster>,
    },
    /// `{"type":"error","message":"..."}`
    Error { message: String },
    /// Forward-compat: any unrecognized `type`.
    #[serde(other)]
    Unknown,
}

// ============================================================================
// Public API: sidecar exchanges
// ============================================================================

/// Diarize a 16 kHz mono WAV: spawn the `diarize-helper` with both model paths,
/// send one `diarize` request, and parse the `segments` reply. `num_speakers`
/// pins the cluster count when known (from the calendar attendee list, F4);
/// `None` lets the helper cluster automatically. In that auto case, `threshold`
/// tunes the clustering aggressiveness (higher = FEWER clusters / more merging);
/// `None` lets the sidecar use its default. `threshold` is ignored by the sidecar
/// whenever `num_speakers` pins an exact count.
///
/// Surfaces a `{"type":"error"}` reply — and a missing binary/timeout/crash — as
/// `Err`. Runs entirely off any hot path; the caller decides threading.
pub async fn diarize(
    app: &AppHandle,
    wav_path: &str,
    num_speakers: Option<i64>,
    threshold: Option<f32>,
    seg_model: &str,
    emb_model: &str,
) -> Result<DiarizeResult> {
    let args = [
        "--segmentation".to_string(),
        seg_model.to_string(),
        "--embedding".to_string(),
        emb_model.to_string(),
    ];
    let req = HelperRequest::Diarize {
        wav_path: wav_path.to_string(),
        num_speakers,
        threshold,
    };
    match helper_oneshot(app, &args, &req, DIARIZE_TIMEOUT).await? {
        HelperResponse::Segments { segments, clusters } => Ok(DiarizeResult { segments, clusters }),
        HelperResponse::Error { message } => Err(anyhow!("diarize-helper error: {message}")),
        HelperResponse::Embedding { .. } | HelperResponse::Unknown => {
            Err(anyhow!("diarize-helper returned an unexpected response to diarize"))
        }
    }
}

/// Embed a single 16 kHz mono WAV utterance into a voiceprint vector: spawn the
/// `diarize-helper` with the embedding model, send one `embed` request, and
/// return the `vector`. Surfaces an `error` reply / spawn failure as `Err`.
pub async fn embed(app: &AppHandle, wav_path: &str, emb_model: &str) -> Result<Vec<f32>> {
    let args = ["--embedding".to_string(), emb_model.to_string()];
    let req = HelperRequest::Embed {
        wav_path: wav_path.to_string(),
    };
    match helper_oneshot(app, &args, &req, EMBED_TIMEOUT).await? {
        HelperResponse::Embedding { vector, .. } => Ok(vector),
        HelperResponse::Error { message } => Err(anyhow!("diarize-helper error: {message}")),
        HelperResponse::Segments { .. } | HelperResponse::Unknown => {
            Err(anyhow!("diarize-helper returned an unexpected response to embed"))
        }
    }
}

/// Spawn-per-request one-shot exchange: resolve the binary, spawn it with `args`,
/// write exactly one request line to stdin, read exactly one response line from
/// stdout, and parse it. Bounded by `timeout`; `kill_on_drop` reaps a
/// timed-out/dropped child. Mirrors [`crate::apple::helper`]'s `oneshot_exchange`.
///
/// `app` is accepted for API consistency (and future path/state needs); binary
/// resolution today is env/exe-relative and does not consult it.
async fn helper_oneshot(
    app: &AppHandle,
    args: &[String],
    req: &HelperRequest,
    timeout: Duration,
) -> Result<HelperResponse> {
    let _ = app; // resolution is env/exe-relative; kept for API consistency.

    let exchange = async {
        let bin = resolve_diarize_binary()?;

        // Spawn — stdin/stdout piped, stderr inherited (logs). NOT `nice`d.
        let mut child = tokio::process::Command::new(&bin)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("failed to spawn diarize-helper at {}", bin.display()))?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("failed to open diarize-helper stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("failed to open diarize-helper stdout"))?;

        // Write exactly one request line.
        let mut line = serde_json::to_string(req).context("failed to encode diarize request")?;
        line.push('\n');
        stdin
            .write_all(line.as_bytes())
            .await
            .context("failed to write diarize request")?;
        stdin.flush().await.context("failed to flush diarize request")?;
        drop(stdin); // EOF so the child can exit after replying.

        // Read exactly one response line.
        let mut reader = BufReader::new(stdout);
        let mut response_line = String::new();
        let n = reader
            .read_line(&mut response_line)
            .await
            .context("failed to read diarize-helper response")?;

        // Best-effort reap.
        let _ = child.wait().await;

        if n == 0 || response_line.trim().is_empty() {
            return Err(anyhow!(
                "diarize-helper closed without a response (process may have crashed)"
            ));
        }

        let parsed: HelperResponse = serde_json::from_str(response_line.trim())
            .with_context(|| format!("failed to parse diarize-helper response: {response_line:?}"))?;
        Ok::<_, anyhow::Error>(parsed)
    };

    tokio::time::timeout(timeout, exchange)
        .await
        .map_err(|_| anyhow!("diarize-helper timed out after {}s", timeout.as_secs()))?
}

/// Resolve the `diarize-helper` sidecar binary, or `Err` if absent. Mirrors the
/// apple/notch resolvers exactly:
/// 1. `ARI_DIARIZE_HELPER_BIN` env override.
/// 2. Next to the running exe: `diarize-helper-aarch64-apple-darwin` (exact,
///    then a fuzzy `diarize-helper*` scan — Tauri stages `externalBin` sidecars
///    beside the app binary with a target-triple suffix).
/// 3. Dev fallback: `<workspace>/target/{release,debug}/diarize-helper`.
fn resolve_diarize_binary() -> Result<PathBuf> {
    // 1. Environment override.
    if let Ok(env_path) = std::env::var("ARI_DIARIZE_HELPER_BIN") {
        if !env_path.is_empty() {
            let path = PathBuf::from(env_path);
            if path.exists() {
                log::debug!(
                    "diarize-helper: using ARI_DIARIZE_HELPER_BIN override: {}",
                    path.display()
                );
                return Ok(path);
            }
            log::debug!("diarize-helper: ARI_DIARIZE_HELPER_BIN set but path does not exist");
        }
    }

    // 2. Bundled next to the executable.
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            let exact = exe_dir.join(format!("{BIN_BASE}-{TARGET_TRIPLE}"));
            if exact.exists() {
                log::debug!("diarize-helper: found bundled binary {}", exact.display());
                return Ok(exact);
            }
            if let Ok(entries) = std::fs::read_dir(exe_dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                        if name.starts_with(BIN_BASE) && !name.ends_with(".d") {
                            log::debug!("diarize-helper: fuzzy-matched {}", path.display());
                            return Ok(path);
                        }
                    }
                }
            }
        }
    }

    // 3. Dev fallback: workspace target dir.
    if let Ok(manifest_dir) = std::env::var("CARGO_MANIFEST_DIR") {
        if let Some(root) = PathBuf::from(&manifest_dir)
            .parent()
            .and_then(|p| p.parent())
            .map(|p| p.to_path_buf())
        {
            for candidate in [
                root.join("target/release").join(BIN_BASE),
                root.join("target/debug").join(BIN_BASE),
            ] {
                if candidate.exists() {
                    log::debug!("diarize-helper: using dev binary {}", candidate.display());
                    return Ok(candidate);
                }
            }
        }
    }

    Err(anyhow!(
        "diarize-helper binary not found (set ARI_DIARIZE_HELPER_BIN or build the sidecar)"
    ))
}

// ============================================================================
// Public API: transcode 48 kHz AAC → 16 kHz mono WAV
// ============================================================================

/// Transcode any ffmpeg-readable input (the app's 48 kHz `mic.m4a` /
/// `system.m4a` / `audio.mp4`) to a **16 kHz mono `pcm_s16le` WAV** the sidecar
/// requires. File→file (not the raw-pipe path). Reuses [`find_ffmpeg_path`];
/// never hardcodes ffmpeg's location. Non-zero exit → `Err` carrying stderr.
pub async fn transcode_to_16k_mono_wav(input_path: &Path, out_wav: &Path) -> Result<()> {
    let ffmpeg = find_ffmpeg_path()
        .ok_or_else(|| anyhow!("ffmpeg not found — cannot transcode for diarization"))?;

    let mut command = tokio::process::Command::new(&ffmpeg);
    command
        .arg("-y") // overwrite output
        .arg("-nostdin")
        .arg("-i")
        .arg(input_path)
        .args(["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-f", "wav"])
        .arg(out_wav)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // Hide console window on Windows (macOS-only app, kept for parity w/ encode.rs).
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        command.creation_flags(CREATE_NO_WINDOW);
    }

    let output = command
        .output()
        .await
        .with_context(|| format!("failed to spawn ffmpeg at {}", ffmpeg.display()))?;

    if !output.status.success() {
        return Err(anyhow!(
            "ffmpeg transcode failed ({}): {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(())
}

// ============================================================================
// Public API: model provisioning
// ============================================================================

/// Ensure both diarization ONNX models exist in the app-data models dir,
/// downloading (and extracting the segmentation archive) on first use. Returns
/// `(segmentation_model_path, embedding_model_path)`. Idempotent: a model already
/// on disk is left untouched.
///
/// Models live under `<app_data_dir>/models/diarization/` (resolved via the Tauri
/// path API — never hardcoded), matching how Parakeet/whisper models are cached.
pub async fn ensure_models(app: &AppHandle) -> Result<(PathBuf, PathBuf)> {
    let models_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| anyhow!("failed to resolve app data dir: {e}"))?
        .join("models")
        .join("diarization");
    tokio::fs::create_dir_all(&models_dir)
        .await
        .with_context(|| format!("failed to create models dir {}", models_dir.display()))?;

    let seg_path = models_dir.join(SEG_MODEL_FILENAME);
    let emb_path = models_dir.join(EMB_MODEL_FILENAME);

    // Embedding model: a direct .onnx download.
    if !emb_path.exists() {
        log::info!(
            "diarization: downloading CAM++ embedding model → {}",
            emb_path.display()
        );
        download_file(EMBEDDING_MODEL_URL, &emb_path)
            .await
            .context("failed to download diarization embedding model")?;
    }

    // Segmentation model: a .tar.bz2 whose payload is `model.onnx`.
    if !seg_path.exists() {
        log::info!("diarization: downloading + extracting segmentation model");
        ensure_segmentation_model(app, &seg_path)
            .await
            .context("failed to provision diarization segmentation model")?;
    }

    Ok((seg_path, emb_path))
}

/// Download the segmentation `.tar.bz2` into a temp scratch dir, extract it, and
/// copy the contained `model.onnx` to `seg_path`.
///
/// Extraction shells out to the system `tar` (bsdtar on macOS transparently
/// decompresses bzip2). This deliberately avoids adding a `bzip2` crate: the
/// project has no bzip2 dependency, and `Cargo.toml` is an upstream-tracked file
/// we keep additive. `tar`/`xz2`/`zip` crates exist but none handles bzip2.
async fn ensure_segmentation_model(app: &AppHandle, seg_path: &Path) -> Result<()> {
    let scratch = app
        .path()
        .temp_dir()
        .map_err(|e| anyhow!("failed to resolve temp dir: {e}"))?
        .join(format!("ari-diar-seg-{}", std::process::id()));
    tokio::fs::create_dir_all(&scratch)
        .await
        .with_context(|| format!("failed to create scratch dir {}", scratch.display()))?;

    let archive = scratch.join("segmentation.tar.bz2");
    download_file(SEGMENTATION_MODEL_URL, &archive)
        .await
        .context("failed to download segmentation archive")?;

    let out = tokio::process::Command::new("tar")
        .arg("-xjf")
        .arg(&archive)
        .arg("-C")
        .arg(&scratch)
        .output()
        .await
        .context("failed to spawn `tar` to extract segmentation archive")?;
    if !out.status.success() {
        return Err(anyhow!(
            "tar extraction failed ({}): {}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        ));
    }

    let extracted = find_file_named(&scratch, "model.onnx")
        .ok_or_else(|| anyhow!("model.onnx not found in extracted segmentation archive"))?;
    tokio::fs::copy(&extracted, seg_path)
        .await
        .with_context(|| format!("failed to copy segmentation model to {}", seg_path.display()))?;

    // Best-effort cleanup of the scratch dir (archive + extracted tree).
    let _ = tokio::fs::remove_dir_all(&scratch).await;
    Ok(())
}

/// Stream-download `url` into `dest`. Writes to a sibling `*.part` file first,
/// then renames into place, so an interrupted download never leaves a truncated
/// file that a later `exists()` check would treat as "present". Follows redirects
/// (GitHub release assets 30x to a CDN). Mirrors the streaming shape used by the
/// Parakeet model downloader.
async fn download_file(url: &str, dest: &Path) -> Result<()> {
    use futures_util::StreamExt;

    let client = reqwest::Client::builder()
        .build()
        .context("failed to build HTTP client")?;
    let resp = client
        .get(url)
        .send()
        .await
        .with_context(|| format!("failed to GET {url}"))?;
    if !resp.status().is_success() {
        return Err(anyhow!("download of {url} failed with status {}", resp.status()));
    }

    if let Some(parent) = dest.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    let tmp = dest.with_extension("part");
    let file = tokio::fs::File::create(&tmp)
        .await
        .with_context(|| format!("failed to create {}", tmp.display()))?;
    let mut writer = tokio::io::BufWriter::new(file);

    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("error while streaming download")?;
        writer
            .write_all(&chunk)
            .await
            .context("error writing download chunk")?;
    }
    writer.flush().await.context("failed to flush download")?;
    drop(writer);

    tokio::fs::rename(&tmp, dest)
        .await
        .with_context(|| format!("failed to move download into place {}", dest.display()))?;
    Ok(())
}

/// Recursively find the first file named `name` under `root`. Small, synchronous
/// walk (the extracted archive is tiny).
fn find_file_named(root: &Path, name: &str) -> Option<PathBuf> {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        if let Ok(entries) = std::fs::read_dir(&dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                } else if path.file_name().and_then(|n| n.to_str()) == Some(name) {
                    return Some(path);
                }
            }
        }
    }
    None
}

// ============================================================================
// BLOB helpers: Vec<f32> <-> opaque little-endian bytes (for the DB layer)
// ============================================================================

/// Serialize a centroid/embedding to opaque little-endian bytes for BLOB storage.
/// Exact inverse of [`bytes_to_centroid`].
pub fn centroid_to_bytes(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for &f in v {
        out.extend_from_slice(&f.to_le_bytes());
    }
    out
}

/// Deserialize a little-endian BLOB back into a centroid/embedding. A trailing
/// partial (non-4-byte-aligned) tail is ignored. Exact inverse of
/// [`centroid_to_bytes`].
pub fn bytes_to_centroid(b: &[u8]) -> Vec<f32> {
    b.chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

// Reuse the existing ffmpeg locator (never hardcode a path).
use crate::audio::ffmpeg::find_ffmpeg_path;

// ============================================================================
// Unit tests — pure logic only (no sidecar, no network, no Tauri runtime)
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // ---- BLOB round-trip (required) ----

    #[test]
    fn centroid_bytes_round_trip_is_exact() {
        let v: Vec<f32> = vec![
            0.0,
            1.0,
            -1.0,
            0.5,
            -0.25,
            f32::MIN_POSITIVE,
            123456.789,
            -987654.321,
        ];
        let bytes = centroid_to_bytes(&v);
        assert_eq!(bytes.len(), v.len() * 4, "4 bytes per f32");
        let back = bytes_to_centroid(&bytes);
        assert_eq!(back, v, "round-trip must be bit-exact");
    }

    #[test]
    fn centroid_bytes_empty_round_trips() {
        assert!(centroid_to_bytes(&[]).is_empty());
        assert!(bytes_to_centroid(&[]).is_empty());
    }

    #[test]
    fn bytes_to_centroid_ignores_partial_tail() {
        // 6 bytes = one f32 + a 2-byte tail that must be dropped.
        let mut bytes = 3.5f32.to_le_bytes().to_vec();
        bytes.extend_from_slice(&[0xAB, 0xCD]);
        assert_eq!(bytes_to_centroid(&bytes), vec![3.5]);
    }

    #[test]
    fn centroid_bytes_are_little_endian() {
        // 1.0f32 == 0x3F800000; little-endian byte order is [00,00,80,3F].
        assert_eq!(centroid_to_bytes(&[1.0]), vec![0x00, 0x00, 0x80, 0x3F]);
    }

    // ---- wire encoding matches the pinned protocol ----

    #[test]
    fn embed_request_encodes_to_pinned_shape() {
        let req = HelperRequest::Embed {
            wav_path: "/tmp/x.wav".to_string(),
        };
        assert_eq!(
            serde_json::to_string(&req).unwrap(),
            r#"{"type":"embed","wav_path":"/tmp/x.wav"}"#
        );
    }

    #[test]
    fn diarize_request_encodes_num_speakers_and_null() {
        // threshold None → omitted from the wire (skip_serializing_if), so the
        // pinned shape is unchanged for callers that don't tune it.
        let some = HelperRequest::Diarize {
            wav_path: "/tmp/x.wav".to_string(),
            num_speakers: Some(3),
            threshold: None,
        };
        assert_eq!(
            serde_json::to_string(&some).unwrap(),
            r#"{"type":"diarize","wav_path":"/tmp/x.wav","num_speakers":3}"#
        );
        let none = HelperRequest::Diarize {
            wav_path: "/tmp/x.wav".to_string(),
            num_speakers: None,
            threshold: None,
        };
        assert_eq!(
            serde_json::to_string(&none).unwrap(),
            r#"{"type":"diarize","wav_path":"/tmp/x.wav","num_speakers":null}"#
        );
    }

    #[test]
    fn diarize_request_encodes_threshold_when_some() {
        let req = HelperRequest::Diarize {
            wav_path: "/tmp/x.wav".to_string(),
            num_speakers: None,
            threshold: Some(0.7),
        };
        assert_eq!(
            serde_json::to_string(&req).unwrap(),
            r#"{"type":"diarize","wav_path":"/tmp/x.wav","num_speakers":null,"threshold":0.7}"#
        );
    }

    // ---- response parsing matches the pinned protocol ----

    #[test]
    fn parses_embedding_response() {
        let line = r#"{"type":"embedding","dim":3,"vector":[0.1,0.2,0.3]}"#;
        match serde_json::from_str::<HelperResponse>(line).unwrap() {
            HelperResponse::Embedding { dim, vector } => {
                assert_eq!(dim, 3);
                assert_eq!(vector, vec![0.1, 0.2, 0.3]);
            }
            other => panic!("expected Embedding, got {other:?}"),
        }
    }

    #[test]
    fn parses_segments_response() {
        let line = r#"{"type":"segments","segments":[{"start":0.0,"end":1.5,"speaker":"spk_0"}],"clusters":[{"speaker":"spk_0","dim":2,"centroid":[0.5,0.5]}]}"#;
        match serde_json::from_str::<HelperResponse>(line).unwrap() {
            HelperResponse::Segments { segments, clusters } => {
                assert_eq!(segments.len(), 1);
                assert_eq!(segments[0].speaker, "spk_0");
                assert_eq!(segments[0].end, 1.5);
                assert_eq!(clusters.len(), 1);
                assert_eq!(clusters[0].dim, 2);
                assert_eq!(clusters[0].centroid, vec![0.5, 0.5]);
            }
            other => panic!("expected Segments, got {other:?}"),
        }
    }

    #[test]
    fn parses_error_response() {
        let line = r#"{"type":"error","message":"bad wav"}"#;
        match serde_json::from_str::<HelperResponse>(line).unwrap() {
            HelperResponse::Error { message } => assert_eq!(message, "bad wav"),
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn parses_unknown_type_as_unknown() {
        let line = r#"{"type":"somethingNew","x":1}"#;
        assert!(matches!(
            serde_json::from_str::<HelperResponse>(line).unwrap(),
            HelperResponse::Unknown
        ));
    }

    #[test]
    fn missing_binary_is_err_not_panic() {
        std::env::remove_var("ARI_DIARIZE_HELPER_BIN");
        let _ = resolve_diarize_binary(); // may Ok/Err by env; must not panic.
    }
}
