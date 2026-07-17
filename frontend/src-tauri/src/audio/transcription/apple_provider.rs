// audio/transcription/apple_provider.rs
//
// Apple on-device (SpeechAnalyzer) transcription provider. Bridges the
// apple-helper sidecar's `transcribe` mode into the unified
// TranscriptionProvider trait, so BOTH live recording and file
// import/retranscription can use Apple STT.

use super::provider::{TranscriptionProvider, TranscriptResult, TranscriptionError};
use async_trait::async_trait;

/// Below this many 16 kHz samples (100 ms) a segment is too short to be worth
/// spawning the sidecar for — return an honest empty, non-partial result so the
/// caller skips it (mirrors how import/retranscription drop sub-1600-sample
/// segments). No-Fake-State: empty means empty, never invented text.
const MIN_SAMPLES: usize = 1600;

/// Transcription provider backed by Apple's on-device SpeechAnalyzer via the
/// apple-helper sidecar. Holds no warm state — each call spawns a one-shot
/// exchange (see `apple::helper::transcribe`).
pub struct AppleTranscriptionProvider {
    locale_default: String,
}

impl AppleTranscriptionProvider {
    pub fn new() -> Self {
        Self {
            // "auto" is the sentinel the sidecar resolves to `Locale.current` —
            // the same locale its install/probe paths use. Defaulting here to
            // "auto" (not a hardcoded "en-US") keeps non-English users correct.
            locale_default: "auto".into(),
        }
    }
}

impl Default for AppleTranscriptionProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl TranscriptionProvider for AppleTranscriptionProvider {
    async fn transcribe(
        &self,
        audio: Vec<f32>,
        language: Option<String>,
    ) -> std::result::Result<TranscriptResult, TranscriptionError> {
        // Guard trivially-short audio: return an honest empty result rather than
        // spawning the sidecar for a segment too short to recognize.
        if audio.len() < MIN_SAMPLES {
            return Ok(TranscriptResult {
                text: String::new(),
                confidence: None,
                is_partial: false,
            });
        }

        // `language` may be a bare code like "en"; the Swift side resolves the
        // closest supported locale, so pass it through and fall back to the
        // default BCP-47 tag when absent.
        let locale = language.unwrap_or_else(|| self.locale_default.clone());
        match crate::apple::helper::transcribe(&audio, &locale).await {
            Ok((text, confidence)) => Ok(TranscriptResult {
                text: text.trim().to_string(),
                confidence,
                is_partial: false,
            }),
            Err(e) => Err(TranscriptionError::EngineFailed(e)),
        }
    }

    async fn is_model_loaded(&self) -> bool {
        // System model; real availability is gated at selection time via
        // `apple_probe`, not here.
        true
    }

    async fn get_current_model(&self) -> Option<String> {
        Some("apple".into())
    }

    fn provider_name(&self) -> &'static str {
        "apple"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn metadata_is_apple() {
        let p = AppleTranscriptionProvider::new();
        assert_eq!(p.provider_name(), "apple");
        assert_eq!(p.get_current_model().await, Some("apple".to_string()));
        assert!(p.is_model_loaded().await);
    }

    #[tokio::test]
    async fn short_audio_returns_empty_non_partial() {
        let p = AppleTranscriptionProvider::new();
        // Under MIN_SAMPLES — must not spawn the sidecar; honest empty result.
        let out = p
            .transcribe(vec![0.0; 100], None)
            .await
            .expect("short audio yields empty Ok, not an error");
        assert!(out.text.is_empty());
        assert!(!out.is_partial);
        assert_eq!(out.confidence, None);
    }
}
