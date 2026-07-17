//! diarize-helper — standalone sherpa-onnx speaker diarization + embedding sidecar.
//!
//! Mirrors the `llama-helper` / `ari-notch` / `apple-helper` sidecar pattern:
//! a long-lived child process driven by the Rust core over an NDJSON
//! (newline-delimited JSON) protocol on stdin/stdout. One request object per
//! line in; one response object per line out. Diagnostic logging goes to
//! stderr only (never stdout — stdout is the wire).
//!
//! Why a sidecar and not in-process: sherpa-onnx statically links its OWN copy
//! of ONNX Runtime. The main Ari app already links `ort` 2.0.0-rc.10 for
//! Parakeet STT. Isolating sherpa-onnx in a separate process/binary keeps the
//! two ONNX Runtime builds from ever sharing a link graph or symbol table.
//!
//! ## Protocol (all `type`-tagged, snake_case — matches the house convention)
//!
//! Requests (stdin):
//!   {"type":"embed","wav_path":"/abs/path.wav"}
//!   {"type":"diarize","wav_path":"/abs/path.wav","num_speakers":3,"threshold":0.7}
//!       // num_speakers null/omitted → AUTO clustering; threshold null/omitted → 0.9.
//!       // In AUTO mode, HIGHER threshold = FEWER clusters (more merging), LOWER =
//!       // more clusters (more splitting). Ignored when num_speakers is a positive int.
//!   {"type":"ping"}
//!   {"type":"shutdown"}
//!
//! Responses (stdout):
//!   {"type":"embedding","dim":192,"vector":[...]}
//!   {"type":"segments","segments":[{"start":0.0,"end":2.1,"speaker":"spk_0"}, ...]}
//!   {"type":"pong"}
//!   {"type":"goodbye"}
//!   {"type":"error","message":"..."}
//!
//! ## Model paths
//! The models are NOT baked in — the app passes downloaded model file paths via
//! CLI flags or environment variables (resolved once at startup):
//!   --segmentation <path>  | env DIARIZE_SEGMENTATION_MODEL   (pyannote model.onnx)
//!   --embedding    <path>  | env DIARIZE_EMBEDDING_MODEL       (CAM++ .onnx, 192-dim)
//!
//! ## Audio contract
//! Both models expect **16 kHz mono** PCM. This sidecar reads a WAV file at
//! `wav_path` and hard-requires 16 kHz mono (errors otherwise). The app is
//! responsible for decoding its per-track `mic.m4a` / `system.m4a` to 16 kHz
//! mono WAV first (e.g. via the existing ffmpeg sidecar) before calling here.

use std::io::{self, BufRead, Write};

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};

use sherpa_onnx::{
    FastClusteringConfig, OfflineSpeakerDiarization, OfflineSpeakerDiarizationConfig,
    OfflineSpeakerSegmentationModelConfig, OfflineSpeakerSegmentationPyannoteModelConfig,
    SpeakerEmbeddingExtractor, SpeakerEmbeddingExtractorConfig,
};

/// Sample rate both the pyannote segmentation and CAM++ embedding models expect.
const REQUIRED_SAMPLE_RATE: u32 = 16_000;

// ============================================================================
// Wire protocol
// ============================================================================

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Request {
    /// Extract a single speaker embedding over the whole WAV.
    Embed { wav_path: String },
    /// Diarize a WAV into speaker-labeled segments.
    Diarize {
        wav_path: String,
        /// Known speaker count → exact clustering. `null` → auto (threshold).
        #[serde(default)]
        num_speakers: Option<i32>,
        /// AUTO-mode clustering threshold. `null`/absent → default 0.9. Higher =
        /// FEWER clusters (more merging); lower = more. Ignored when `num_speakers`
        /// is a positive int (exact clustering). `#[serde(default)]` keeps old
        /// callers (that omit the field) working.
        #[serde(default)]
        threshold: Option<f32>,
    },
    Ping,
    Shutdown,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Response {
    Embedding {
        dim: usize,
        vector: Vec<f32>,
    },
    Segments {
        segments: Vec<Segment>,
        /// One entry per distinct speaker label present in `segments`. Each holds
        /// the L2-normalized mean CAM++ embedding over that cluster's audio, so
        /// the app can cosine-match it against stored per-person voiceprints for
        /// cross-meeting re-ID. (sherpa's `spk_<i>` labels are per-file only.)
        clusters: Vec<Cluster>,
    },
    Pong,
    Goodbye,
    Error {
        message: String,
    },
    /// Emitted only by `--probe`.
    ProbeResult {
        runtime_ok: bool,
        embedding_model: Option<String>,
        segmentation_model: Option<String>,
        embedding_dim: Option<i32>,
        required_sample_rate: u32,
        message: String,
    },
}

#[derive(Debug, Serialize)]
struct Segment {
    start: f32,
    end: f32,
    speaker: String,
}

/// Per-speaker-cluster voiceprint: the mean CAM++ embedding over all of that
/// cluster's segment audio, L2-normalized (unit length → cosine downstream is
/// just a dot product). A degenerate cluster with no usable audio yields a
/// zero vector of length `dim` — the app's matcher treats zero-norm as no-match.
#[derive(Debug, Serialize)]
struct Cluster {
    speaker: String,
    dim: usize,
    centroid: Vec<f32>,
}

// ============================================================================
// Model path resolution (CLI flags > env vars)
// ============================================================================

#[derive(Debug, Clone, Default)]
struct ModelPaths {
    segmentation: Option<String>,
    embedding: Option<String>,
}

impl ModelPaths {
    fn resolve(args: &[String]) -> Self {
        let mut segmentation = std::env::var("DIARIZE_SEGMENTATION_MODEL").ok();
        let mut embedding = std::env::var("DIARIZE_EMBEDDING_MODEL").ok();

        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--segmentation" => {
                    segmentation = args.get(i + 1).cloned();
                    i += 2;
                }
                "--embedding" => {
                    embedding = args.get(i + 1).cloned();
                    i += 2;
                }
                _ => i += 1,
            }
        }
        Self {
            segmentation,
            embedding,
        }
    }
}

// ============================================================================
// Audio loading — 16 kHz mono WAV → Vec<f32> in [-1, 1]
// ============================================================================

fn load_wav_16k_mono(path: &str) -> Result<Vec<f32>> {
    let mut reader = hound::WavReader::open(path)
        .with_context(|| format!("failed to open WAV file: {path}"))?;
    let spec = reader.spec();

    if spec.channels != 1 {
        bail!(
            "expected mono WAV, got {} channels ({path}); the app must downmix before calling",
            spec.channels
        );
    }
    if spec.sample_rate != REQUIRED_SAMPLE_RATE {
        bail!(
            "expected {REQUIRED_SAMPLE_RATE} Hz WAV, got {} Hz ({path}); the app must resample before calling",
            spec.sample_rate
        );
    }

    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader
            .samples::<f32>()
            .collect::<Result<Vec<_>, _>>()
            .context("failed to read f32 WAV samples")?,
        hound::SampleFormat::Int => {
            let max = (1i64 << (spec.bits_per_sample - 1)) as f32;
            reader
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / max))
                .collect::<Result<Vec<_>, _>>()
                .context("failed to read int WAV samples")?
        }
    };

    if samples.is_empty() {
        bail!("WAV file contained no samples: {path}");
    }
    Ok(samples)
}

// ============================================================================
// Engine — lazily builds and caches the sherpa extractor / diarizer
// ============================================================================

struct Engine {
    models: ModelPaths,
    extractor: Option<SpeakerEmbeddingExtractor>,
}

impl Engine {
    fn new(models: ModelPaths) -> Self {
        Self {
            models,
            extractor: None,
        }
    }

    fn embedding_config(&self) -> Result<SpeakerEmbeddingExtractorConfig> {
        let model = self
            .models
            .embedding
            .clone()
            .ok_or_else(|| anyhow!("no embedding model path (set --embedding or DIARIZE_EMBEDDING_MODEL)"))?;
        Ok(SpeakerEmbeddingExtractorConfig {
            model: Some(model),
            num_threads: default_threads(),
            debug: false,
            ..Default::default()
        })
    }

    fn extractor(&mut self) -> Result<&SpeakerEmbeddingExtractor> {
        if self.extractor.is_none() {
            let cfg = self.embedding_config()?;
            let ex = SpeakerEmbeddingExtractor::create(&cfg)
                .ok_or_else(|| anyhow!("SpeakerEmbeddingExtractor::create returned None (bad model path or incompatible model?)"))?;
            self.extractor = Some(ex);
        }
        Ok(self.extractor.as_ref().unwrap())
    }

    fn embed(&mut self, wav_path: &str) -> Result<(usize, Vec<f32>)> {
        let samples = load_wav_16k_mono(wav_path)?;
        let ex = self.extractor()?;
        let stream = ex
            .create_stream()
            .ok_or_else(|| anyhow!("create_stream returned None"))?;
        stream.accept_waveform(REQUIRED_SAMPLE_RATE as i32, &samples);
        stream.input_finished();
        if !ex.is_ready(&stream) {
            bail!("embedding stream not ready (audio too short?)");
        }
        let vector = ex
            .compute(&stream)
            .ok_or_else(|| anyhow!("compute returned None"))?;
        Ok((vector.len(), vector))
    }

    fn diarization_config(
        &self,
        num_speakers: Option<i32>,
        threshold: Option<f32>,
    ) -> Result<OfflineSpeakerDiarizationConfig> {
        let seg = self
            .models
            .segmentation
            .clone()
            .ok_or_else(|| anyhow!("no segmentation model path (set --segmentation or DIARIZE_SEGMENTATION_MODEL)"))?;
        let emb = self
            .models
            .embedding
            .clone()
            .ok_or_else(|| anyhow!("no embedding model path (set --embedding or DIARIZE_EMBEDDING_MODEL)"))?;

        // num_speakers known → num_clusters = N (threshold ignored).
        // unknown → num_clusters = -1 (auto); the request's threshold gates the
        // cluster count (higher = FEWER clusters / more merging). The app always
        // sends a threshold in auto mode; the 0.9 fallback here is defense-in-depth
        // (0.5 over-split badly — a 1:1 reported 44 clusters).
        let (num_clusters, threshold) = match num_speakers {
            Some(n) if n > 0 => (n, 0.0),
            _ => (-1, threshold.unwrap_or(0.9)),
        };

        Ok(OfflineSpeakerDiarizationConfig {
            segmentation: OfflineSpeakerSegmentationModelConfig {
                pyannote: OfflineSpeakerSegmentationPyannoteModelConfig {
                    model: Some(seg),
                    ..Default::default()
                },
                num_threads: default_threads(),
                debug: false,
                ..Default::default()
            },
            embedding: SpeakerEmbeddingExtractorConfig {
                model: Some(emb),
                num_threads: default_threads(),
                debug: false,
                ..Default::default()
            },
            clustering: FastClusteringConfig {
                num_clusters,
                threshold,
            },
            ..Default::default()
        })
    }

    /// Build a fresh diarizer for THIS request's `num_speakers` + `threshold`.
    /// `num_clusters`/`threshold` are construction-time config in sherpa-onnx (not
    /// per-`process()` args), so we build per diarize call rather than caching —
    /// this guarantees the current request's threshold is honored and never a
    /// stale one. The sidecar is spawn-per-request, so there's no perf cost.
    fn diarizer(
        &self,
        num_speakers: Option<i32>,
        threshold: Option<f32>,
    ) -> Result<OfflineSpeakerDiarization> {
        let cfg = self.diarization_config(num_speakers, threshold)?;
        OfflineSpeakerDiarization::create(&cfg)
            .ok_or_else(|| anyhow!("OfflineSpeakerDiarization::create returned None (bad model paths?)"))
    }

    /// Run the CAM++ extractor over an arbitrary in-memory 16 kHz mono buffer.
    /// Returns `None` (not an error) when the audio is too short for the model
    /// to produce an embedding — the caller treats that as a degenerate cluster.
    fn embed_samples(&mut self, samples: &[f32]) -> Result<Option<Vec<f32>>> {
        let ex = self.extractor()?;
        let stream = ex
            .create_stream()
            .ok_or_else(|| anyhow!("create_stream returned None"))?;
        stream.accept_waveform(REQUIRED_SAMPLE_RATE as i32, samples);
        stream.input_finished();
        if !ex.is_ready(&stream) {
            // Too little audio for this cluster; not fatal.
            return Ok(None);
        }
        Ok(ex.compute(&stream))
    }

    fn diarize(
        &mut self,
        wav_path: &str,
        num_speakers: Option<i32>,
        threshold: Option<f32>,
    ) -> Result<(Vec<Segment>, Vec<Cluster>)> {
        let samples = load_wav_16k_mono(wav_path)?;
        let sd = self.diarizer(num_speakers, threshold)?;

        let expected = sd.sample_rate();
        if expected != REQUIRED_SAMPLE_RATE as i32 {
            bail!("model reports sample_rate {expected}, expected {REQUIRED_SAMPLE_RATE}");
        }

        let result = sd
            .process(&samples)
            .ok_or_else(|| anyhow!("diarization process returned None"))?;

        // Own the raw segments so the `sd` (and thus `self`) borrow ends here,
        // freeing `self` for the embedding extractor below.
        let raw = result.sort_by_start_time();

        // Group each cluster's audio by slicing the 16 kHz sample buffer to
        // [start*sr, end*sr) per segment and concatenating. BTreeMap keeps the
        // clusters ordered by speaker index (spk_0, spk_1, …).
        let sr = REQUIRED_SAMPLE_RATE as f32;
        let mut cluster_audio: std::collections::BTreeMap<i32, Vec<f32>> =
            std::collections::BTreeMap::new();
        let mut segments = Vec::with_capacity(raw.len());
        for s in &raw {
            segments.push(Segment {
                start: s.start,
                end: s.end,
                speaker: format!("spk_{}", s.speaker),
            });

            let begin = ((s.start * sr).floor().max(0.0) as usize).min(samples.len());
            let finish = ((s.end * sr).ceil().max(0.0) as usize).min(samples.len());
            if finish > begin {
                cluster_audio
                    .entry(s.speaker)
                    .or_default()
                    .extend_from_slice(&samples[begin..finish]);
            } else {
                // Ensure the cluster key exists even if this slice is empty, so a
                // speaker present in `segments` always gets a `clusters` entry.
                cluster_audio.entry(s.speaker).or_default();
            }
        }

        // Embed + L2-normalize each cluster's concatenated audio. dim() comes
        // from the extractor so degenerate clusters emit a correctly-sized zero.
        let dim = self.extractor()?.dim() as usize;
        let mut clusters = Vec::with_capacity(cluster_audio.len());
        for (speaker, audio) in cluster_audio {
            let centroid = if audio.is_empty() {
                vec![0.0f32; dim]
            } else {
                match self.embed_samples(&audio)? {
                    Some(v) => l2_normalize(v),
                    None => vec![0.0f32; dim],
                }
            };
            clusters.push(Cluster {
                speaker: format!("spk_{speaker}"),
                dim,
                centroid,
            });
        }

        Ok((segments, clusters))
    }
}

/// L2-normalize a vector in place-ish (returns a new owned vector). A zero-norm
/// input is returned unchanged (still zero) so the app reads it as no-match.
fn l2_normalize(mut v: Vec<f32>) -> Vec<f32> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > f32::EPSILON {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
    v
}

fn default_threads() -> i32 {
    std::thread::available_parallelism()
        .map(|n| ((n.get() / 2).max(1)) as i32)
        .unwrap_or(2)
}

// ============================================================================
// Probe — availability check, mirrors apple-helper's --probe
// ============================================================================

fn run_probe(models: &ModelPaths) -> Response {
    let mut engine = Engine::new(models.clone());
    let mut embedding_dim = None;
    let mut runtime_ok = true;
    let mut notes: Vec<String> = Vec::new();

    // The mere fact that this binary launched proves the sherpa-onnx static lib
    // (and its bundled ONNX Runtime) linked and loaded. If an embedding model
    // path is available, go further and actually instantiate the extractor so
    // the app can distinguish "runtime present" from "model usable".
    if models.embedding.is_some() {
        match engine.extractor() {
            Ok(ex) => {
                embedding_dim = Some(ex.dim());
                notes.push(format!("embedding extractor OK (dim={})", ex.dim()));
            }
            Err(e) => {
                runtime_ok = false;
                notes.push(format!("embedding extractor failed: {e}"));
            }
        }
    } else {
        notes.push("no embedding model path provided (--embedding/DIARIZE_EMBEDDING_MODEL)".into());
    }

    if models.segmentation.is_none() {
        notes.push("no segmentation model path provided (--segmentation/DIARIZE_SEGMENTATION_MODEL)".into());
    }

    Response::ProbeResult {
        runtime_ok,
        embedding_model: models.embedding.clone(),
        segmentation_model: models.segmentation.clone(),
        embedding_dim,
        required_sample_rate: REQUIRED_SAMPLE_RATE,
        message: if notes.is_empty() {
            "sherpa-onnx runtime linked".into()
        } else {
            notes.join("; ")
        },
    }
}

// ============================================================================
// Main loop
// ============================================================================

fn send(resp: &Response) -> Result<()> {
    let json = serde_json::to_string(resp)?;
    println!("{json}");
    io::stdout().flush()?;
    Ok(())
}

fn handle(engine: &mut Engine, req: Request) -> Response {
    match req {
        Request::Embed { wav_path } => match engine.embed(&wav_path) {
            Ok((dim, vector)) => Response::Embedding { dim, vector },
            Err(e) => Response::Error {
                message: format!("embed failed: {e:#}"),
            },
        },
        Request::Diarize {
            wav_path,
            num_speakers,
            threshold,
        } => match engine.diarize(&wav_path, num_speakers, threshold) {
            Ok((segments, clusters)) => Response::Segments { segments, clusters },
            Err(e) => Response::Error {
                message: format!("diarize failed: {e:#}"),
            },
        },
        Request::Ping => Response::Pong,
        Request::Shutdown => Response::Goodbye,
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let models = ModelPaths::resolve(&args);

    if args.iter().any(|a| a == "--probe") {
        let resp = run_probe(&models);
        send(&resp)?;
        return Ok(());
    }

    eprintln!(
        "🗣️  diarize-helper starting (segmentation={:?}, embedding={:?})",
        models.segmentation, models.embedding
    );

    let mut engine = Engine::new(models);
    let stdin = io::stdin();
    let mut lock = stdin.lock();
    let mut buffer = String::new();

    loop {
        buffer.clear();
        match lock.read_line(&mut buffer) {
            Ok(0) => {
                eprintln!("📪 EOF, exiting");
                break;
            }
            Ok(_) => {
                let line = buffer.trim();
                if line.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Request>(line) {
                    Ok(req) => {
                        let is_shutdown = matches!(req, Request::Shutdown);
                        let resp = handle(&mut engine, req);
                        send(&resp)?;
                        if is_shutdown {
                            eprintln!("🛑 shutdown requested");
                            break;
                        }
                    }
                    Err(e) => {
                        send(&Response::Error {
                            message: format!("invalid request: {e}"),
                        })?;
                    }
                }
            }
            Err(e) => {
                eprintln!("❌ stdin error: {e}");
                break;
            }
        }
    }

    eprintln!("👋 diarize-helper exiting");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_embed_request() {
        let r: Request = serde_json::from_str(r#"{"type":"embed","wav_path":"/a.wav"}"#).unwrap();
        assert!(matches!(r, Request::Embed { .. }));
    }

    #[test]
    fn parses_diarize_with_and_without_num_speakers() {
        let a: Request =
            serde_json::from_str(r#"{"type":"diarize","wav_path":"/a.wav","num_speakers":3}"#)
                .unwrap();
        match a {
            Request::Diarize { num_speakers, .. } => assert_eq!(num_speakers, Some(3)),
            _ => panic!("expected diarize"),
        }
        let b: Request =
            serde_json::from_str(r#"{"type":"diarize","wav_path":"/a.wav","num_speakers":null}"#)
                .unwrap();
        match b {
            Request::Diarize { num_speakers, .. } => assert_eq!(num_speakers, None),
            _ => panic!("expected diarize"),
        }
        // num_speakers omitted entirely → None (serde default)
        let c: Request =
            serde_json::from_str(r#"{"type":"diarize","wav_path":"/a.wav"}"#).unwrap();
        match c {
            Request::Diarize {
                num_speakers,
                threshold,
                ..
            } => {
                assert_eq!(num_speakers, None);
                // threshold absent → None (serde default); old callers keep working.
                assert_eq!(threshold, None);
            }
            _ => panic!("expected diarize"),
        }
    }

    #[test]
    fn parses_diarize_threshold_when_present() {
        let r: Request = serde_json::from_str(
            r#"{"type":"diarize","wav_path":"/a.wav","num_speakers":null,"threshold":0.7}"#,
        )
        .unwrap();
        match r {
            Request::Diarize { threshold, .. } => assert_eq!(threshold, Some(0.7)),
            _ => panic!("expected diarize"),
        }
    }

    #[test]
    fn serializes_segments_response() {
        let resp = Response::Segments {
            segments: vec![Segment {
                start: 0.0,
                end: 1.5,
                speaker: "spk_0".into(),
            }],
            clusters: vec![Cluster {
                speaker: "spk_0".into(),
                dim: 3,
                centroid: vec![0.0, 0.6, 0.8],
            }],
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains(r#""type":"segments""#));
        assert!(json.contains(r#""speaker":"spk_0""#));
        // The new per-cluster centroid block is present alongside segments.
        assert!(json.contains(r#""clusters""#));
        assert!(json.contains(r#""dim":3"#));
        assert!(json.contains(r#""centroid":[0.0,0.6,0.8]"#));
    }

    #[test]
    fn cluster_serialization_shape() {
        let c = Cluster {
            speaker: "spk_2".into(),
            dim: 192,
            centroid: vec![1.0, 0.0],
        };
        let json = serde_json::to_string(&c).unwrap();
        assert!(json.contains(r#""speaker":"spk_2""#));
        assert!(json.contains(r#""dim":192"#));
        assert!(json.contains(r#""centroid":[1.0,0.0]"#));
    }

    #[test]
    fn l2_normalize_unit_and_zero() {
        // A non-zero vector becomes unit length.
        let v = l2_normalize(vec![3.0, 4.0]);
        let norm = (v[0] * v[0] + v[1] * v[1]).sqrt();
        assert!((norm - 1.0).abs() < 1e-6, "expected unit norm, got {norm}");
        assert!((v[0] - 0.6).abs() < 1e-6);
        assert!((v[1] - 0.8).abs() < 1e-6);
        // A zero vector is left as zero (no NaNs from divide-by-zero).
        let z = l2_normalize(vec![0.0, 0.0, 0.0]);
        assert_eq!(z, vec![0.0, 0.0, 0.0]);
    }

    #[test]
    fn embedding_response_shape() {
        let resp = Response::Embedding {
            dim: 3,
            vector: vec![0.1, 0.2, 0.3],
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains(r#""type":"embedding""#));
        assert!(json.contains(r#""dim":3"#));
    }

    #[test]
    fn model_paths_cli_overrides_are_read() {
        let args = vec![
            "--segmentation".to_string(),
            "/seg.onnx".to_string(),
            "--embedding".to_string(),
            "/emb.onnx".to_string(),
        ];
        let m = ModelPaths::resolve(&args);
        assert_eq!(m.segmentation.as_deref(), Some("/seg.onnx"));
        assert_eq!(m.embedding.as_deref(), Some("/emb.onnx"));
    }
}
