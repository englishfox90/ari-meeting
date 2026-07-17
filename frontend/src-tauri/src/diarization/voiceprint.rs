//! # Voiceprint identicon signatures (F1 visual mark)
//!
//! A small, **read-only** command surface that turns a speaker's real CAM++
//! voiceprint centroid (a 192-dim f32 vector persisted as a little-endian BLOB
//! in `speakers.centroid`) into a compact, deterministic *signature* the
//! frontend renders as a "voice ring" identicon.
//!
//! This visualizes REAL data only (honouring the app's No-Fake-State rule): the
//! signature is a direct, order-preserving down-sampling of the centroid — never
//! a hash. Two cosine-similar voices therefore produce visually similar rings (a
//! desirable emergent property), and as a voiceprint refines across meetings the
//! ring subtly evolves with it.
//!
//! ## Responsibilities
//! - **This module** owns only the *pure* f32 math (decode + down-sample +
//!   normalize) — trivially unit-testable, no DB, no I/O — plus a thin Tauri
//!   command that reads speakers via the sanctioned repository and maps them.
//! - **DB access** goes through the existing public, read-only
//!   [`SpeakerRepository::list_for_meeting`]; this module never writes and never
//!   inlines a query.

use serde::Serialize;

use crate::database::repositories::speaker::SpeakerRepository;
use crate::state::AppState;

/// How many radial buckets a centroid is reduced to. Small enough to keep the
/// IPC payload tiny and the ring elegant at 16px; large enough to stay unique.
pub const SIGNATURE_BUCKETS: usize = 32;

/// One speaker's render-ready voiceprint signature: the centroid down-sampled to
/// [`SIGNATURE_BUCKETS`] values, each normalized to `[0, 1]`. Speakers whose
/// centroid is missing or has no variation are omitted entirely (the frontend
/// then shows a neutral placeholder, never a fabricated glyph).
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct VoiceprintSignature {
    pub speaker_id: String,
    pub values: Vec<f32>,
}

/// A person's render-ready voiceprint signature, derived from their CANONICAL
/// enrolled speaker (the strongest confirmed/owner voiceprint). Drives the large
/// "voice ring" on the person drill-down. Persons with no enrolled voiceprint are
/// simply absent (the frontend then renders nothing — No-Fake-State).
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PersonVoiceprintSignature {
    pub person_id: String,
    pub values: Vec<f32>,
}

/// Keep only the FIRST signature per `person_id` from a list already ordered so
/// each person's canonical row sorts first within its group (as
/// [`SpeakerRepository::list_canonical_enrolled`] returns). Pure and
/// order-preserving — trivially unit-testable, no DB.
pub fn dedupe_first_per_person(
    signatures: Vec<PersonVoiceprintSignature>,
) -> Vec<PersonVoiceprintSignature> {
    let mut seen = std::collections::HashSet::new();
    signatures
        .into_iter()
        .filter(|s| seen.insert(s.person_id.clone()))
        .collect()
}

/// Decode a little-endian `f32` BLOB (as stored in `speakers.centroid`) into a
/// vector of floats. Trailing bytes that don't complete a 4-byte lane are
/// ignored (defensive; a well-formed centroid is always a multiple of 4).
pub fn bytes_to_f32_le(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

/// Reduce an embedding to `buckets` values (mean of each contiguous slice) and
/// normalize the result to `[0, 1]` via per-vector min/max.
///
/// Returns `None` for an empty embedding or one with no variation (all buckets
/// equal) — both would only ever yield a flat, meaningless ring, so we decline
/// to invent one. Non-finite inputs (NaN/inf) also yield `None`.
///
/// The mapping is intentionally **direct** (no hashing): preserving the relative
/// magnitudes keeps cosine-similar voices visually similar.
pub fn downsample_normalize(embedding: &[f32], buckets: usize) -> Option<Vec<f32>> {
    if embedding.is_empty() || buckets == 0 {
        return None;
    }
    let n = embedding.len();
    let mut means: Vec<f32> = Vec::with_capacity(buckets);
    for i in 0..buckets {
        let start = (i * n) / buckets;
        let mut end = ((i + 1) * n) / buckets;
        if end <= start {
            end = (start + 1).min(n); // guarantee a non-empty slice when n < buckets
        }
        let slice = &embedding[start..end];
        let sum: f32 = slice.iter().copied().sum();
        means.push(sum / slice.len() as f32);
    }

    let min = means.iter().copied().fold(f32::INFINITY, f32::min);
    let max = means.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let range = max - min;
    if !range.is_finite() || range <= f32::EPSILON {
        return None; // degenerate / no variation → honest "no glyph"
    }
    Some(
        means
            .iter()
            .map(|v| ((v - min) / range).clamp(0.0, 1.0))
            .collect(),
    )
}

/// Read command: the per-speaker voiceprint signatures for a finished meeting.
///
/// Reads the meeting's speakers via the existing read-only repository, decodes
/// each real centroid, and down-samples it server-side (keeping the IPC payload
/// tiny). Speakers with no usable centroid are simply absent from the result —
/// never represented by a fabricated signature.
#[tauri::command]
pub async fn speaker_voiceprint_signatures(
    meeting_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<VoiceprintSignature>, String> {
    let pool = state.db_manager.pool();
    let speakers = SpeakerRepository::list_for_meeting(pool, &meeting_id)
        .await
        .map_err(|e| format!("failed to load speakers for meeting {meeting_id}: {e}"))?;

    let signatures = speakers
        .into_iter()
        .filter_map(|s| {
            let embedding = bytes_to_f32_le(&s.centroid);
            downsample_normalize(&embedding, SIGNATURE_BUCKETS).map(|values| VoiceprintSignature {
                speaker_id: s.id,
                values,
            })
        })
        .collect();
    Ok(signatures)
}

/// Read command: the voiceprint signature for ONE person, from their canonical
/// enrolled speaker. Returns `None` when the person has no usable enrolled
/// voiceprint (never enrolled, or a degenerate centroid) — the frontend then
/// renders nothing rather than a fabricated glyph.
#[tauri::command]
pub async fn person_voiceprint_signature(
    person_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<Option<PersonVoiceprintSignature>, String> {
    let pool = state.db_manager.pool();
    let speaker = SpeakerRepository::canonical_enrolled_for_person(pool, &person_id)
        .await
        .map_err(|e| format!("failed to load voiceprint for person {person_id}: {e}"))?;

    Ok(speaker.and_then(|s| {
        let embedding = bytes_to_f32_le(&s.centroid);
        downsample_normalize(&embedding, SIGNATURE_BUCKETS).map(|values| {
            PersonVoiceprintSignature {
                person_id,
                values,
            }
        })
    }))
}

/// Read command: the canonical voiceprint signature for every person that has an
/// enrolled voiceprint, in one call (for the People list). Persons whose centroid
/// is unusable are omitted. One signature per person (the canonical row).
#[tauri::command]
pub async fn person_voiceprint_signatures(
    state: tauri::State<'_, AppState>,
) -> Result<Vec<PersonVoiceprintSignature>, String> {
    let pool = state.db_manager.pool();
    let speakers = SpeakerRepository::list_canonical_enrolled(pool)
        .await
        .map_err(|e| format!("failed to load person voiceprint signatures: {e}"))?;

    let signatures = speakers
        .into_iter()
        .filter_map(|s| {
            let person_id = s.person_id?;
            let embedding = bytes_to_f32_le(&s.centroid);
            downsample_normalize(&embedding, SIGNATURE_BUCKETS).map(|values| {
                PersonVoiceprintSignature {
                    person_id,
                    values,
                }
            })
        })
        .collect();
    Ok(dedupe_first_per_person(signatures))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_little_endian_f32() {
        let mut bytes = Vec::new();
        for v in [1.0f32, -2.5, 0.0, 3.25] {
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        assert_eq!(bytes_to_f32_le(&bytes), vec![1.0, -2.5, 0.0, 3.25]);
    }

    #[test]
    fn ignores_trailing_partial_lane() {
        let mut bytes = 7.0f32.to_le_bytes().to_vec();
        bytes.extend_from_slice(&[0xAB, 0xCD]); // 2 stray bytes
        assert_eq!(bytes_to_f32_le(&bytes), vec![7.0]);
    }

    #[test]
    fn downsample_produces_requested_bucket_count() {
        let embedding: Vec<f32> = (0..192).map(|i| i as f32).collect();
        let sig = downsample_normalize(&embedding, 32).expect("has variation");
        assert_eq!(sig.len(), 32);
    }

    #[test]
    fn downsample_normalizes_to_unit_range() {
        let embedding: Vec<f32> = (0..192).map(|i| i as f32).collect();
        let sig = downsample_normalize(&embedding, 32).unwrap();
        // Monotonically increasing input → first bucket is the min (0.0), last the max (1.0).
        assert!((sig[0] - 0.0).abs() < 1e-6);
        assert!((sig[sig.len() - 1] - 1.0).abs() < 1e-6);
        assert!(sig.iter().all(|&v| (0.0..=1.0).contains(&v)));
    }

    #[test]
    fn downsample_means_are_correct() {
        // 8 values, 4 buckets → each bucket is the mean of a pair.
        let embedding = [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0];
        // means: 1, 5, 9, 13 → min 1, max 13, range 12 → 0, 1/3, 2/3, 1
        let sig = downsample_normalize(&embedding, 4).unwrap();
        assert_eq!(sig.len(), 4);
        assert!((sig[0] - 0.0).abs() < 1e-6);
        assert!((sig[1] - 1.0 / 3.0).abs() < 1e-6);
        assert!((sig[2] - 2.0 / 3.0).abs() < 1e-6);
        assert!((sig[3] - 1.0).abs() < 1e-6);
    }

    #[test]
    fn deterministic_same_input_same_output() {
        let embedding: Vec<f32> = (0..192).map(|i| (i as f32 * 0.37).sin()).collect();
        let a = downsample_normalize(&embedding, 32);
        let b = downsample_normalize(&embedding, 32);
        assert_eq!(a, b);
    }

    #[test]
    fn empty_and_flat_vectors_yield_none() {
        assert_eq!(downsample_normalize(&[], 32), None);
        assert_eq!(downsample_normalize(&[0.0; 192], 32), None); // no variation
        assert_eq!(downsample_normalize(&[5.0; 192], 32), None);
    }

    #[test]
    fn non_finite_input_yields_none() {
        let mut embedding = vec![0.5f32; 192];
        embedding[0] = f32::NAN;
        assert_eq!(downsample_normalize(&embedding, 32), None);
    }

    #[test]
    fn dedupe_keeps_first_signature_per_person() {
        let sig = |id: &str, v: f32| PersonVoiceprintSignature {
            person_id: id.to_string(),
            values: vec![v],
        };
        // Ordered as the repo returns: canonical of each person sorts first.
        let input = vec![sig("a", 0.9), sig("a", 0.1), sig("b", 0.5), sig("a", 0.2)];
        let out = dedupe_first_per_person(input);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0], sig("a", 0.9)); // first "a" kept, later ones dropped
        assert_eq!(out[1], sig("b", 0.5));
    }

    #[test]
    fn handles_fewer_values_than_buckets() {
        let embedding = [0.0, 1.0, 2.0, 3.0];
        let sig = downsample_normalize(&embedding, 32).expect("still produces a signature");
        assert_eq!(sig.len(), 32);
        assert!(sig.iter().all(|&v| (0.0..=1.0).contains(&v)));
    }
}
