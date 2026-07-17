//! Apple helper IPC wire protocol.
//!
//! Transport is NDJSON: one JSON object per line, UTF-8. Field names are exact
//! camelCase (Swift `Codable` on the sidecar decodes/encodes the very same
//! `fixtures/*.json` files), so the wire shape here and the fixtures must stay
//! byte-compatible.
//!
//! Direction:
//! - [`AppleRequest`]  — Rust core → apple-helper sidecar
//! - [`AppleResponse`] — apple-helper sidecar → Rust core
//!
//! Forward-compatibility: both enums carry a `#[serde(other)] Unknown`
//! catch-all, so an unrecognized `type` deserializes to `Unknown` rather than
//! erroring — later phases add new variants without breaking older peers.

use serde::{Deserialize, Serialize};

/// Requests: Rust core → apple-helper sidecar. NDJSON, camelCase.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum AppleRequest {
    /// Ask the sidecar to report Apple STT/LLM availability.
    Probe,
    /// Ask the sidecar to shut down cleanly.
    Shutdown,
    /// Ask the sidecar to summarize `text` under `instruction` (FoundationModels).
    /// The variant-level rename maps `max_tokens` → `maxTokens` on the wire;
    /// `text`/`instruction` are already valid camelCase.
    #[serde(rename_all = "camelCase")]
    Summarize {
        text: String,
        instruction: String,
        max_tokens: u32,
    },
    /// Ask the sidecar to ensure on-device assets (e.g. Speech models) are
    /// installed, streaming zero+ `progress` replies then a terminal
    /// `ensureResult`. Single lowercase field — no rename needed.
    EnsureAssets { which: String },
    /// Ask the sidecar to transcribe one PCM segment via SpeechAnalyzer.
    /// The variant-level rename maps `pcm_base64` → `pcmBase64` on the wire;
    /// `locale` is already valid camelCase. `pcmBase64` is base64 of
    /// little-endian Float32 16 kHz mono PCM.
    #[serde(rename_all = "camelCase")]
    Transcribe { pcm_base64: String, locale: String },
    /// Ask the sidecar to embed a batch of `texts` via on-device NLEmbedding.
    /// Reply is a single [`AppleResponse::EmbedResult`] with one vector per input
    /// (same order) on success, or [`AppleResponse::Error`] on any failure. The
    /// single lowercase field `texts` is already valid camelCase — no rename.
    EmbedBatch { texts: Vec<String> },
    /// Forward-compat catch-all: any unknown `type` lands here.
    #[serde(other)]
    Unknown,
}

/// Responses: apple-helper sidecar → Rust core. Distinct `type` per reply.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum AppleResponse {
    /// Result of a [`AppleRequest::Probe`]: the availability snapshot.
    #[serde(rename_all = "camelCase")]
    ProbeResult {
        speech_available: bool,
        foundation_available: bool,
        os_ok: bool,
        apple_intelligence: bool,
        speech_assets_installed: bool,
    },
    /// A failure the sidecar wants surfaced with a human-readable reason.
    Error { message: String },
    /// Result of a [`AppleRequest::Summarize`]: the generated summary text.
    /// Single field `text` is already valid camelCase, so no rename is needed.
    SummarizeResult { text: String },
    /// A streamed asset-download progress tick (`0.0..=1.0`). Zero or more of
    /// these precede a terminal [`AppleResponse::EnsureResult`].
    Progress { fraction: f64 },
    /// Terminal result of a [`AppleRequest::EnsureAssets`]: whether the assets
    /// are now installed.
    EnsureResult { installed: bool },
    /// Result of a [`AppleRequest::Transcribe`]: the recognized `text` and an
    /// optional `confidence` (`0.0..=1.0`). `text`/`confidence` are already
    /// valid camelCase; `Option<f32>` serializes `null` when `None`, matching
    /// the Swift `Double?`.
    TranscribeResult { text: String, confidence: Option<f32> },
    /// Result of a [`AppleRequest::EmbedBatch`]: one embedding `vectors` entry per
    /// input text, in the SAME order. Each vector is 512-d (NLEmbedding sentence
    /// embedding). Single field `vectors` is already valid camelCase — no rename.
    EmbedResult { vectors: Vec<Vec<f32>> },
    /// Forward-compat catch-all: any unknown `type` lands here.
    #[serde(other)]
    Unknown,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// Parse both sides to `serde_json::Value` and compare — order-insensitive.
    fn assert_semantic_eq(a: &str, b: &str) {
        let va: Value = serde_json::from_str(a).expect("lhs is valid json");
        let vb: Value = serde_json::from_str(b).expect("rhs is valid json");
        assert_eq!(va, vb, "semantic JSON mismatch\n  lhs: {a}\n  rhs: {b}");
    }

    // ---- Request fixtures (Rust → sidecar) ----

    #[test]
    fn probe_request_roundtrips() {
        let fixture = include_str!("fixtures/probe.json");
        let parsed: AppleRequest =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleRequest");
        assert_eq!(parsed, AppleRequest::Probe);
        assert_ne!(parsed, AppleRequest::Unknown);
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn summarize_request_roundtrips() {
        let fixture = include_str!("fixtures/summarize.json");
        let parsed: AppleRequest =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleRequest");
        match &parsed {
            AppleRequest::Summarize {
                text,
                instruction,
                max_tokens,
            } => {
                assert!(text.contains("ship the release on Friday"));
                assert_eq!(
                    instruction,
                    "Summarize the key decisions and action items from this meeting transcript."
                );
                assert_eq!(*max_tokens, 512);
            }
            other => panic!("expected Summarize, got {other:?}"),
        }
        assert_ne!(parsed, AppleRequest::Unknown);
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn shutdown_request_roundtrips() {
        let fixture = include_str!("fixtures/shutdown.json");
        let parsed: AppleRequest =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleRequest");
        assert_eq!(parsed, AppleRequest::Shutdown);
        assert_ne!(parsed, AppleRequest::Unknown);
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn ensure_assets_request_roundtrips() {
        let fixture = include_str!("fixtures/ensure_assets.json");
        let parsed: AppleRequest =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleRequest");
        match &parsed {
            AppleRequest::EnsureAssets { which } => assert_eq!(which, "speech"),
            other => panic!("expected EnsureAssets, got {other:?}"),
        }
        assert_ne!(parsed, AppleRequest::Unknown);
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    // ---- Response fixtures (sidecar → Rust) ----

    #[test]
    fn probe_result_response_roundtrips() {
        let fixture = include_str!("fixtures/probe_result.json");
        let parsed: AppleResponse =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleResponse");
        assert_ne!(parsed, AppleResponse::Unknown, "fixture must be a known variant");
        match &parsed {
            AppleResponse::ProbeResult {
                speech_available,
                foundation_available,
                os_ok,
                apple_intelligence,
                speech_assets_installed,
            } => {
                assert!(*speech_available);
                assert!(*foundation_available);
                assert!(*os_ok);
                assert!(*apple_intelligence);
                assert!(!*speech_assets_installed);
            }
            other => panic!("expected ProbeResult, got {other:?}"),
        }
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn error_response_roundtrips() {
        let fixture = include_str!("fixtures/error.json");
        let parsed: AppleResponse =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleResponse");
        assert_ne!(parsed, AppleResponse::Unknown, "fixture must be a known variant");
        match &parsed {
            AppleResponse::Error { message } => {
                assert_eq!(message, "Apple Intelligence is not enabled");
            }
            other => panic!("expected Error, got {other:?}"),
        }
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn summarize_result_response_roundtrips() {
        let fixture = include_str!("fixtures/summarize_result.json");
        let parsed: AppleResponse =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleResponse");
        assert_ne!(parsed, AppleResponse::Unknown, "fixture must be a known variant");
        match &parsed {
            AppleResponse::SummarizeResult { text } => {
                assert!(text.contains("ship the release on Friday"));
            }
            other => panic!("expected SummarizeResult, got {other:?}"),
        }
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn progress_response_roundtrips() {
        let fixture = include_str!("fixtures/progress.json");
        let parsed: AppleResponse =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleResponse");
        assert_ne!(parsed, AppleResponse::Unknown, "fixture must be a known variant");
        match &parsed {
            AppleResponse::Progress { fraction } => assert_eq!(*fraction, 0.42),
            other => panic!("expected Progress, got {other:?}"),
        }
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn ensure_result_response_roundtrips() {
        let fixture = include_str!("fixtures/ensure_result.json");
        let parsed: AppleResponse =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleResponse");
        assert_ne!(parsed, AppleResponse::Unknown, "fixture must be a known variant");
        match &parsed {
            AppleResponse::EnsureResult { installed } => assert!(*installed),
            other => panic!("expected EnsureResult, got {other:?}"),
        }
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn transcribe_request_roundtrips() {
        let fixture = include_str!("fixtures/transcribe.json");
        let parsed: AppleRequest =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleRequest");
        match &parsed {
            AppleRequest::Transcribe { pcm_base64, locale } => {
                assert_eq!(pcm_base64, "AAAAAAAAAAAAAAAAAAAAAA==");
                assert_eq!(locale, "en-US");
            }
            other => panic!("expected Transcribe, got {other:?}"),
        }
        assert_ne!(parsed, AppleRequest::Unknown);
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn transcribe_result_response_roundtrips() {
        let fixture = include_str!("fixtures/transcribe_result.json");
        let parsed: AppleResponse =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleResponse");
        assert_ne!(parsed, AppleResponse::Unknown, "fixture must be a known variant");
        match &parsed {
            AppleResponse::TranscribeResult { text, confidence } => {
                assert_eq!(text, "Let's start with the roadmap.");
                assert_eq!(*confidence, Some(0.94));
            }
            other => panic!("expected TranscribeResult, got {other:?}"),
        }
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn embed_batch_request_roundtrips() {
        let fixture = include_str!("fixtures/embed_batch.json");
        let parsed: AppleRequest =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleRequest");
        match &parsed {
            AppleRequest::EmbedBatch { texts } => {
                assert_eq!(texts.len(), 2);
                assert!(texts[0].contains("ship the release on Friday"));
                assert!(texts[1].contains("finish the API by Thursday"));
            }
            other => panic!("expected EmbedBatch, got {other:?}"),
        }
        assert_ne!(parsed, AppleRequest::Unknown);
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    #[test]
    fn embed_result_response_roundtrips() {
        let fixture = include_str!("fixtures/embed_result.json");
        let parsed: AppleResponse =
            serde_json::from_str(fixture).expect("fixture deserializes to AppleResponse");
        assert_ne!(parsed, AppleResponse::Unknown, "fixture must be a known variant");
        match &parsed {
            AppleResponse::EmbedResult { vectors } => {
                assert_eq!(vectors.len(), 2);
                assert_eq!(vectors[0], vec![0.1, 0.2, 0.3]);
                assert_eq!(vectors[1], vec![-0.4, 0.5, -0.6]);
            }
            other => panic!("expected EmbedResult, got {other:?}"),
        }
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    // ---- camelCase mapping assertions ----

    #[test]
    fn probe_result_serializes_camel_case_tag_and_fields() {
        let value = serde_json::to_value(AppleResponse::ProbeResult {
            speech_available: true,
            foundation_available: false,
            os_ok: true,
            apple_intelligence: false,
            speech_assets_installed: true,
        })
        .unwrap();
        assert_eq!(value["type"], "probeResult");
        assert_eq!(value["speechAvailable"], true);
        assert_eq!(value["foundationAvailable"], false);
        assert_eq!(value["osOk"], true);
        assert_eq!(value["appleIntelligence"], false);
        assert_eq!(value["speechAssetsInstalled"], true);
    }

    // ---- Forward-compatibility: unknown `type` → Unknown ----

    #[test]
    fn unknown_request_type_deserializes_to_unknown() {
        // A type the protocol will never define — must degrade to `Unknown`,
        // never error. (Deliberately not a real/future variant name; `transcribe`
        // is now a real request variant, so it can't stand in for "unknown".)
        let line = r#"{"type":"definitelyNotARealAppleRequestType","x":1}"#;
        let parsed: AppleRequest = serde_json::from_str(line).expect("must not error");
        assert_eq!(parsed, AppleRequest::Unknown);
    }

    #[test]
    fn unknown_response_type_deserializes_to_unknown() {
        // A type the protocol will never define — must degrade to `Unknown`,
        // never error. (Deliberately not a real/future variant name.)
        let line = r#"{"type":"definitelyNotARealAppleResponseType","text":"hi"}"#;
        let parsed: AppleResponse = serde_json::from_str(line).expect("must not error");
        assert_eq!(parsed, AppleResponse::Unknown);
    }
}
