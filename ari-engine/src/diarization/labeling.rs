//! # Speaker labeling helpers (F1 → F2/F3 bridge)
//!
//! Pure-read helpers that turn the diarization output (per-transcript `speaker_id`
//! stamps + persistent `speakers`/`persons` rows) into **human speaker names** for
//! downstream consumers: the summary path (per-line prefixes), the F3 context block,
//! and F2 fact extraction.
//!
//! These live here (not in `persons/`) because the resolution chain starts at the
//! diarization layer's `speaker_id`. They are read-only — no DB writes — and honest:
//! a speaker that resolves to no name is **omitted**, never given a fabricated label.
//!
//! Resolution chain per speaker (each step is best-effort):
//!   `speaker_id → Speaker.person_id → PersonRepository::get → PersonRow.display_name`,
//!   falling back to `Speaker.label` (e.g. "Speaker 2"), else the speaker is skipped.
//!
//! Names are resolved **once per meeting** into a `HashMap` — never N+1'd per line.

use std::collections::HashMap;

use anyhow::Result;
use sqlx::SqlitePool;

use crate::database::repositories::meeting::MeetingsRepository;
use crate::database::repositories::person::PersonRepository;
use crate::database::repositories::speaker::SpeakerRepository;

/// Build a `HashMap<speaker_id, display_name>` for every speaker in the meeting that
/// resolves to a usable name. Resolution: linked person's `display_name`, else the
/// speaker's own `label`, else the speaker is omitted (no fabricated names).
///
/// Resolves each speaker exactly once (no per-transcript-line DB hits).
async fn resolve_speaker_names(
    pool: &SqlitePool,
    meeting_id: &str,
) -> Result<HashMap<String, String>> {
    let speakers = SpeakerRepository::list_for_meeting(pool, meeting_id).await?;
    let mut names: HashMap<String, String> = HashMap::with_capacity(speakers.len());

    for speaker in speakers {
        // 1. Prefer the linked person's display name.
        let resolved = match &speaker.person_id {
            Some(pid) => match PersonRepository::get(pool, pid).await {
                Ok(Some(p)) => Some(p.display_name),
                Ok(None) => None,
                Err(e) => {
                    log::warn!(
                        "🏷️ labeling: failed to resolve person {pid} for speaker {} (continuing): {e}",
                        speaker.id
                    );
                    None
                }
            },
            None => None,
        };

        // 2. Fall back to the speaker's own label (e.g. "Speaker 2").
        let mut resolved = resolved.or_else(|| {
            speaker
                .label
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        });

        // 3. Owner fallback (P1): an owner-state voiceprint whose person link didn't
        // resolve (e.g. person_id NULL on an import path) still IS a real identity —
        // resolve the configured owner's display name, else the honest "You". Never
        // fabricated: the row is explicitly enrolled as the owner.
        if resolved.is_none() && speaker.enrollment_state == "owner" {
            resolved = Some(match PersonRepository::get_owner(pool).await {
                Ok(Some(owner)) => owner.display_name,
                _ => "You".to_string(),
            });
        }

        // 4. No name at all → omit (honest: provisional/unlabeled speakers get no name).
        if let Some(name) = resolved {
            names.insert(speaker.id, name);
        }
    }

    Ok(names)
}

/// Resolve per-transcript speaker labels for a meeting.
///
/// Returns `(transcript_id, speaker_name)` for every transcript row whose `speaker_id`
/// resolves to a name. Rows with a NULL or unresolved `speaker_id` are **omitted** —
/// the caller gets no entry for them (never a fabricated name). Order follows
/// `audio_start_time` (the paginated read is already time-ordered).
///
/// Names are resolved once per meeting up front, so this never N+1's the DB per line.
pub async fn resolve_meeting_speaker_labels(
    pool: &SqlitePool,
    meeting_id: &str,
) -> Result<Vec<(String, String)>> {
    let names = resolve_speaker_names(pool, meeting_id).await?;
    if names.is_empty() {
        return Ok(Vec::new());
    }

    // Large limit → all rows; already ordered by audio_start_time.
    let (transcripts, _total) =
        MeetingsRepository::get_meeting_transcripts_paginated(pool, meeting_id, i64::MAX, 0).await?;

    let mut out = Vec::new();
    for t in transcripts {
        if let Some(sid) = t.speaker_id.as_deref() {
            if let Some(name) = names.get(sid) {
                out.push((t.id, name.clone()));
            }
        }
    }
    Ok(out)
}

/// Build the meeting's full transcript as newline-joined lines, prefixing each line
/// with the resolved speaker name when known: `"{Name}: {text}"`. Lines whose speaker
/// is unknown are emitted bare (`"{text}"`) — no fabricated name.
///
/// Returns `None` when the meeting has **zero** resolved speakers (so callers can fall
/// back to their prior, unlabeled behavior). Line order follows `audio_start_time`.
pub async fn build_labeled_transcript_text(
    pool: &SqlitePool,
    meeting_id: &str,
) -> Result<Option<String>> {
    let names = resolve_speaker_names(pool, meeting_id).await?;
    if names.is_empty() {
        return Ok(None);
    }

    let (transcripts, _total) =
        MeetingsRepository::get_meeting_transcripts_paginated(pool, meeting_id, i64::MAX, 0).await?;

    let mut lines: Vec<String> = Vec::with_capacity(transcripts.len());
    for t in transcripts {
        let text = t.transcript.trim();
        if text.is_empty() {
            continue;
        }
        let name = t.speaker_id.as_deref().and_then(|sid| names.get(sid));
        match name {
            Some(name) => lines.push(format!("{}: {}", name, text)),
            None => lines.push(text.to_string()),
        }
    }

    if lines.is_empty() {
        return Ok(None);
    }
    Ok(Some(lines.join("\n")))
}
