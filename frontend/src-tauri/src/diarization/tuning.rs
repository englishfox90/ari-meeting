//! # Diarization runtime tuning
//!
//! A tiny, best-effort loader for a runtime-editable diarization tuning file so
//! the user can tune clustering **without recompiling** — they edit a JSON file
//! and re-run diarization.
//!
//! The file is OPTIONAL and lives at `<app_data_dir>/diarization-tuning.json`
//! (resolved via the Tauri path API, exactly like [`crate::diarization::engine::ensure_models`]
//! resolves its models dir — never hardcoded). Shape (all fields optional):
//!
//! ```json
//! { "clusterThreshold": 0.7, "speakerCount": "auto" }
//! ```
//!
//! - `clusterThreshold` (f32, default **0.9**) — AUTO-mode clustering threshold.
//!   HIGHER = FEWER clusters (more merging); LOWER = more clusters (more splitting).
//!   The default is deliberately far higher than the sidecar's old hardcoded `0.5`
//!   to reduce the over-splitting a `0.5` caused (a 1:1 reported 44 speakers). Used
//!   only in auto mode.
//! - `mergeThreshold` (f32, default **0.7**) — app-side greedy centroid post-merge
//!   cutoff (see [`crate::diarization::postprocess`]). Two clusters merge while
//!   their centroid cosine is `>= this`. Higher = fewer merges.
//! - `minClusterSecs` (f64, default **10.0**) and `minClusterFrac` (f64, default
//!   **0.02**) — the speech-time floor: a cluster survives only if its total speech
//!   is `>= max(minClusterSecs, minClusterFrac × total speech)`. Smaller clusters
//!   are dissolved (segments reassigned to the nearest surviving cluster or dropped).
//! - `speakerCount` (default `"auto"`) — one of:
//!   - `"auto"`  → ignore the calendar attendee count entirely; cluster with the
//!     threshold above (the calendar prior is **advisory → off**).
//!   - `"calendar"` → use the clamped calendar prior (`(participants−1).clamp(1,8)`),
//!     i.e. the old forced behavior.
//!   - an integer N (JSON number OR numeric string) → force exactly N speakers,
//!     clamped to `1..=20`.
//!
//! This module is **best-effort and never fails diarization**: a missing file OR
//! a parse error both fall back to defaults (logged), so a malformed tuning file
//! can never break a real diarization run.

use serde::Deserialize;
use tauri::{AppHandle, Manager};

/// Filename of the optional tuning file under the app-data dir.
const TUNING_FILENAME: &str = "diarization-tuning.json";

/// Default AUTO-mode clustering threshold when the file is absent or omits it.
/// Far higher than the sidecar's legacy `0.5` to curb over-splitting (empirically
/// validated: 0.9 + app-side post-merge/floor yields correct counts).
const DEFAULT_CLUSTER_THRESHOLD: f32 = 0.9;

/// Default app-side greedy centroid post-merge cutoff (see [`crate::diarization::postprocess`]).
const DEFAULT_MERGE_THRESHOLD: f32 = 0.7;
/// Default absolute speech-time floor (seconds) for a cluster to survive.
const DEFAULT_MIN_CLUSTER_SECS: f64 = 10.0;
/// Default fractional speech-time floor (× total speech) for a cluster to survive.
const DEFAULT_MIN_CLUSTER_FRAC: f64 = 0.02;

/// Sane clamp range for a user-forced fixed speaker count.
const FIXED_SPEAKER_MIN: i64 = 1;
const FIXED_SPEAKER_MAX: i64 = 20;

/// How the speaker count is decided for a diarize run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpeakerCountMode {
    /// Ignore the calendar count; cluster purely by threshold (advisory → off).
    Auto,
    /// Use the clamped calendar attendee prior (old forced behavior).
    Calendar,
    /// Force exactly N speakers (already clamped to `1..=20`).
    Fixed(i64),
}

/// Resolved tuning knobs for one diarize run.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DiarTuning {
    /// AUTO-mode clustering threshold (higher = fewer clusters).
    pub cluster_threshold: f32,
    /// App-side greedy centroid post-merge cutoff (higher = fewer merges).
    pub merge_threshold: f32,
    /// Absolute speech-time floor (seconds) for a cluster to survive.
    pub min_cluster_secs: f64,
    /// Fractional speech-time floor (× total speech) for a cluster to survive.
    pub min_cluster_frac: f64,
    /// How to decide the speaker count.
    pub speaker_count: SpeakerCountMode,
}

impl Default for DiarTuning {
    fn default() -> Self {
        Self {
            cluster_threshold: DEFAULT_CLUSTER_THRESHOLD,
            merge_threshold: DEFAULT_MERGE_THRESHOLD,
            min_cluster_secs: DEFAULT_MIN_CLUSTER_SECS,
            min_cluster_frac: DEFAULT_MIN_CLUSTER_FRAC,
            speaker_count: SpeakerCountMode::Auto,
        }
    }
}

impl DiarTuning {
    /// Build the [`crate::diarization::postprocess::PostProcessConfig`] this tuning
    /// implies (merge/floor knobs; reassignment cutoff keeps its default).
    pub fn postprocess_config(&self) -> crate::diarization::postprocess::PostProcessConfig {
        crate::diarization::postprocess::PostProcessConfig {
            merge_threshold: self.merge_threshold,
            floor_abs_secs: self.min_cluster_secs,
            floor_frac: self.min_cluster_frac,
            ..crate::diarization::postprocess::PostProcessConfig::default()
        }
    }
}

/// Raw on-disk shape. All fields optional; unknown fields ignored. Lenient about
/// `speakerCount` being a string (`"auto"`/`"calendar"`/`"3"`) or a JSON number.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawTuning {
    #[serde(default)]
    cluster_threshold: Option<f32>,
    #[serde(default)]
    merge_threshold: Option<f32>,
    #[serde(default)]
    min_cluster_secs: Option<f64>,
    #[serde(default)]
    min_cluster_frac: Option<f64>,
    #[serde(default)]
    speaker_count: Option<serde_json::Value>,
}

/// Load the optional tuning file. Missing file OR parse error → defaults (logged).
/// Never returns `Err` — diarization must never fail because of this file.
pub async fn load(app: &AppHandle) -> DiarTuning {
    let path = match app.path().app_data_dir() {
        Ok(dir) => dir.join(TUNING_FILENAME),
        Err(e) => {
            log::info!("🎙️ diarize: could not resolve app-data dir ({e}) — using default tuning");
            return DiarTuning::default();
        }
    };

    let contents = match tokio::fs::read_to_string(&path).await {
        Ok(c) => c,
        Err(_) => {
            // Missing file is the common case (no config = defaults); log at info.
            log::info!(
                "🎙️ diarize: no tuning file at {} — using defaults (threshold={}, mode=auto)",
                path.display(),
                DEFAULT_CLUSTER_THRESHOLD
            );
            return DiarTuning::default();
        }
    };

    let raw: RawTuning = match serde_json::from_str(&contents) {
        Ok(r) => r,
        Err(e) => {
            log::warn!(
                "🎙️ diarize: failed to parse {} ({e}) — using default tuning",
                path.display()
            );
            return DiarTuning::default();
        }
    };

    let cluster_threshold = raw.cluster_threshold.unwrap_or(DEFAULT_CLUSTER_THRESHOLD);
    let merge_threshold = raw.merge_threshold.unwrap_or(DEFAULT_MERGE_THRESHOLD);
    let min_cluster_secs = raw.min_cluster_secs.unwrap_or(DEFAULT_MIN_CLUSTER_SECS);
    let min_cluster_frac = raw.min_cluster_frac.unwrap_or(DEFAULT_MIN_CLUSTER_FRAC);
    let speaker_count = parse_speaker_count(raw.speaker_count.as_ref());

    let tuning = DiarTuning {
        cluster_threshold,
        merge_threshold,
        min_cluster_secs,
        min_cluster_frac,
        speaker_count,
    };
    log::info!(
        "🎙️ diarize: loaded tuning from {} → {:?}",
        path.display(),
        tuning
    );
    tuning
}

/// Interpret the lenient `speakerCount` value into a [`SpeakerCountMode`].
/// Accepts `"auto"`/`"calendar"` (case-insensitive), an integer as a JSON number,
/// or an integer as a numeric string. Anything unrecognized → `Auto` (default).
fn parse_speaker_count(value: Option<&serde_json::Value>) -> SpeakerCountMode {
    let Some(value) = value else {
        return SpeakerCountMode::Auto;
    };

    match value {
        serde_json::Value::String(s) => {
            let t = s.trim();
            match t.to_ascii_lowercase().as_str() {
                "auto" => SpeakerCountMode::Auto,
                "calendar" => SpeakerCountMode::Calendar,
                _ => match t.parse::<i64>() {
                    Ok(n) => SpeakerCountMode::Fixed(n.clamp(FIXED_SPEAKER_MIN, FIXED_SPEAKER_MAX)),
                    Err(_) => {
                        log::warn!(
                            "🎙️ diarize: unrecognized speakerCount \"{s}\" — using auto"
                        );
                        SpeakerCountMode::Auto
                    }
                },
            }
        }
        serde_json::Value::Number(n) => match n.as_i64() {
            Some(v) => SpeakerCountMode::Fixed(v.clamp(FIXED_SPEAKER_MIN, FIXED_SPEAKER_MAX)),
            None => {
                // A float like 3.0 → round toward zero.
                let v = n.as_f64().map(|f| f as i64).unwrap_or(0);
                SpeakerCountMode::Fixed(v.clamp(FIXED_SPEAKER_MIN, FIXED_SPEAKER_MAX))
            }
        },
        _ => SpeakerCountMode::Auto,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_tuning_is_auto_and_point_nine() {
        let d = DiarTuning::default();
        assert_eq!(d.speaker_count, SpeakerCountMode::Auto);
        assert!((d.cluster_threshold - 0.9).abs() < 1e-6);
        assert!((d.merge_threshold - 0.7).abs() < 1e-6);
        assert!((d.min_cluster_secs - 10.0).abs() < 1e-6);
        assert!((d.min_cluster_frac - 0.02).abs() < 1e-6);
    }

    #[test]
    fn postprocess_config_reflects_tuning() {
        let d = DiarTuning::default();
        let pp = d.postprocess_config();
        assert!((pp.merge_threshold - 0.7).abs() < 1e-6);
        assert!((pp.floor_abs_secs - 10.0).abs() < 1e-6);
        assert!((pp.floor_frac - 0.02).abs() < 1e-6);
        // Reassignment cutoff keeps the postprocess default.
        assert!((pp.reassign_min_cosine - 0.5).abs() < 1e-6);
    }

    #[test]
    fn missing_new_keys_fall_back_to_defaults() {
        // A file with only clusterThreshold set: the new merge/floor keys default.
        let raw: RawTuning =
            serde_json::from_str(r#"{"clusterThreshold":0.85}"#).unwrap();
        assert_eq!(raw.cluster_threshold, Some(0.85));
        assert_eq!(raw.merge_threshold, None);
        assert_eq!(raw.min_cluster_secs, None);
        assert_eq!(raw.min_cluster_frac, None);
    }

    #[test]
    fn new_keys_parse_when_present() {
        let raw: RawTuning = serde_json::from_str(
            r#"{"mergeThreshold":0.75,"minClusterSecs":15.0,"minClusterFrac":0.05}"#,
        )
        .unwrap();
        assert_eq!(raw.merge_threshold, Some(0.75));
        assert_eq!(raw.min_cluster_secs, Some(15.0));
        assert_eq!(raw.min_cluster_frac, Some(0.05));
    }

    #[test]
    fn parses_auto_and_calendar_strings() {
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!("auto"))),
            SpeakerCountMode::Auto
        );
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!("AUTO"))),
            SpeakerCountMode::Auto
        );
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!("calendar"))),
            SpeakerCountMode::Calendar
        );
    }

    #[test]
    fn parses_integer_as_number_or_string() {
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!(3))),
            SpeakerCountMode::Fixed(3)
        );
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!("5"))),
            SpeakerCountMode::Fixed(5)
        );
    }

    #[test]
    fn clamps_fixed_count_to_sane_range() {
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!(0))),
            SpeakerCountMode::Fixed(1)
        );
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!(999))),
            SpeakerCountMode::Fixed(20)
        );
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!("-4"))),
            SpeakerCountMode::Fixed(1)
        );
    }

    #[test]
    fn unrecognized_or_missing_falls_back_to_auto() {
        assert_eq!(parse_speaker_count(None), SpeakerCountMode::Auto);
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!("banana"))),
            SpeakerCountMode::Auto
        );
        assert_eq!(
            parse_speaker_count(Some(&serde_json::json!(true))),
            SpeakerCountMode::Auto
        );
    }

    #[test]
    fn missing_fields_use_defaults() {
        let raw: RawTuning = serde_json::from_str("{}").unwrap();
        assert_eq!(raw.cluster_threshold, None);
        let mode = parse_speaker_count(raw.speaker_count.as_ref());
        assert_eq!(mode, SpeakerCountMode::Auto);
    }
}
