//! Split a meeting's ordered transcript segments into overlapping windows suitable for
//! embedding + retrieval. Each chunk carries the recording-relative time span and a
//! display timestamp so retrieved chunks can cite a moment.

use crate::database::models::Transcript;

/// Target chunk size in characters (~500 tokens at ~4 chars/token). Keeps chunks well
/// inside the embedder's context while staying large enough to hold a coherent thought.
const TARGET_CHARS: usize = 2_000;
/// Segments carried into the next chunk so a fact spanning a boundary stays retrievable.
const OVERLAP_SEGMENTS: usize = 1;

pub struct ChunkDraft {
    pub chunk_index: i64,
    pub text: String,
    pub start_time: Option<f64>,
    pub end_time: Option<f64>,
    pub timestamp_label: Option<String>,
    pub token_estimate: i64,
}

fn build_chunk(index: i64, segments: &[&Transcript]) -> Option<ChunkDraft> {
    let text = segments
        .iter()
        .map(|s| s.transcript.trim())
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if text.trim().is_empty() {
        return None;
    }
    let start_time = segments.iter().find_map(|s| s.audio_start_time);
    let end_time = segments.iter().rev().find_map(|s| s.audio_end_time);
    let timestamp_label = segments
        .iter()
        .find(|s| !s.timestamp.trim().is_empty())
        .map(|s| s.timestamp.trim().to_string());
    let token_estimate = (text.chars().count() / 4) as i64;
    Some(ChunkDraft {
        chunk_index: index,
        text,
        start_time,
        end_time,
        timestamp_label,
        token_estimate,
    })
}

/// Chunk transcript segments (expected in chronological order) into overlapping windows.
pub fn chunk_transcripts(segments: &[Transcript]) -> Vec<ChunkDraft> {
    let mut chunks = Vec::new();
    let mut current: Vec<&Transcript> = Vec::new();
    let mut current_chars = 0usize;
    let mut index = 0i64;

    for segment in segments {
        let text = segment.transcript.trim();
        if text.is_empty() {
            continue;
        }
        current.push(segment);
        current_chars += text.chars().count();

        if current_chars >= TARGET_CHARS {
            if let Some(draft) = build_chunk(index, &current) {
                chunks.push(draft);
                index += 1;
            }
            let keep_from = current.len().saturating_sub(OVERLAP_SEGMENTS);
            current = current[keep_from..].to_vec();
            current_chars = current
                .iter()
                .map(|s| s.transcript.trim().chars().count())
                .sum();
        }
    }

    // Flush the tail, unless it's only the carried-over overlap (already covered).
    let is_pure_overlap = !chunks.is_empty() && current.len() <= OVERLAP_SEGMENTS;
    if !current.is_empty() && !is_pure_overlap {
        if let Some(draft) = build_chunk(index, &current) {
            chunks.push(draft);
        }
    }

    chunks
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(id: &str, text: &str, start: f64) -> Transcript {
        Transcript {
            id: id.to_string(),
            meeting_id: "m1".to_string(),
            transcript: text.to_string(),
            timestamp: format!("{:02}:{:02}", (start as i64) / 60, (start as i64) % 60),
            summary: None,
            action_items: None,
            key_points: None,
            audio_start_time: Some(start),
            audio_end_time: Some(start + 5.0),
            duration: Some(5.0),
            speaker_id: None,
        }
    }

    #[test]
    fn short_transcript_makes_one_chunk_with_time_span() {
        let segments = vec![seg("a", "hello world", 0.0), seg("b", "second line", 6.0)];
        let chunks = chunk_transcripts(&segments);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].start_time, Some(0.0));
        assert_eq!(chunks[0].end_time, Some(11.0));
        assert_eq!(chunks[0].timestamp_label.as_deref(), Some("00:00"));
        assert!(chunks[0].text.contains("hello world"));
        assert!(chunks[0].text.contains("second line"));
    }

    #[test]
    fn long_transcript_splits_into_multiple_chunks() {
        let big = "word ".repeat(500); // ~2500 chars
        let segments = vec![seg("a", &big, 0.0), seg("b", &big, 60.0), seg("c", "tail", 120.0)];
        let chunks = chunk_transcripts(&segments);
        assert!(chunks.len() >= 2, "expected multiple chunks, got {}", chunks.len());
        // Indices are sequential from 0.
        for (expected, chunk) in chunks.iter().enumerate() {
            assert_eq!(chunk.chunk_index, expected as i64);
        }
    }

    #[test]
    fn empty_input_yields_no_chunks() {
        assert!(chunk_transcripts(&[]).is_empty());
    }
}
