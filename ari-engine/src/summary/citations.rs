//! Deterministic timestamp-citation post-processing.
//!
//! The LLM is instructed to cite moments as `@ref(MM:SS)` / `@ref(H:MM:SS)`,
//! copied verbatim from a `[MM:SS]` marker in the source transcript passed to
//! `generate_meeting_summary`. In practice two things go wrong:
//!
//! 1. Weak models (e.g. Apple FoundationModels) emit a citation that is
//!    close to, but not exactly, a real marker (`@ref(34:38)` vs the real
//!    `[34:43]` line).
//! 2. The map-reduce path (long transcripts on Ollama/BuiltInAI) summarizes
//!    marker-less chunk text before the final pass, so citations are often
//!    missing entirely even though the underlying moment is identifiable
//!    from the surrounding text.
//!
//! This module is a pure, deterministic pass — no LLM call, no I/O — that
//! runs the generated summary markdown back against the ORIGINAL transcript
//! (which always carries real `[MM:SS] Name: text` markers) to VERIFY, SNAP,
//! or conservatively BACK-FILL citations. Per the app's No-Fake-State rule,
//! this never invents a timestamp: every `@ref(...)` it produces or leaves
//! behind traces to a real transcript line, and when it can't establish that
//! with confidence it removes/omits rather than guesses.

use once_cell::sync::Lazy;
use regex::{Captures, Regex};
use std::collections::HashSet;

/// How close (in seconds) a model-emitted `@ref(...)` may be to a real
/// transcript marker before we consider it a near-miss worth snapping rather
/// than a hallucination worth dropping. Tuned to cover "off by one adjacent
/// transcript line" (typically a few seconds of drift from rounding or the
/// model citing the start of the *next* utterance) without silently
/// accepting a citation that points at a genuinely different moment.
const SNAP_TOLERANCE_SECS: u32 = 8;

/// Minimum lexical-overlap coverage (see `score`) required before we
/// back-fill a missing citation onto a table `Ref` cell or a Decision/Action
/// bullet. Deliberately >0.5 majority-coverage: back-filling is the riskiest
/// operation here (there was no model-claimed citation to verify against),
/// so we bias hard toward leaving a blank over guessing wrong.
const BACKFILL_MIN_SCORE: f32 = 0.5;

/// Absolute floor on the number of shared, non-stopword tokens required for
/// a back-fill match, independent of the coverage ratio. Prevents short
/// summary lines (e.g. a two-word bullet) from hitting a spuriously perfect
/// score off a single shared word.
const MIN_TOKEN_OVERLAP: usize = 3;

// ---------------------------------------------------------------------
// Transcript parsing
// ---------------------------------------------------------------------

/// Matches a leading `[MM:SS]` or `[H:MM:SS]` transcript marker. The first
/// numeric group is intentionally unconstrained (not just `\d{1,2}`):
/// `buildSummaryTranscriptPayload` on the frontend never rolls raw minutes
/// over into an hour component, so a >59 minute meeting emits markers like
/// `[75:23]`, not `[1:15:23]`. Both shapes are accepted; the last one or two
/// groups (seconds, and minutes-with-seconds) are constrained to `00`-`59`.
static SEGMENT_MARKER_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^\[(\d{1,4}):([0-5]\d)(?::([0-5]\d))?\]\s*(.*)$").unwrap()
});

/// A single transcript line with a real, ground-truth timestamp.
struct Segment {
    seconds: u32,
    text: String,
}

fn parse_segments(source_transcript: &str) -> Vec<Segment> {
    let mut segments: Vec<Segment> = source_transcript
        .lines()
        .filter_map(|line| {
            let caps = SEGMENT_MARKER_RE.captures(line)?;
            let seconds = seconds_from_marker_caps(&caps, 1, 2, 3);
            let text = caps.get(4).map(|m| m.as_str()).unwrap_or("").trim().to_string();
            Some(Segment { seconds, text })
        })
        .collect();
    segments.sort_by_key(|s| s.seconds);
    segments
}

/// Shared seconds computation for both transcript markers and `@ref(...)`
/// tokens: group `a` is either raw minutes (2-part form) or hours (3-part
/// form); group `c` (when present) makes it the 3-part form.
fn seconds_from_marker_caps(caps: &Captures, a: usize, b: usize, c: usize) -> u32 {
    let g = |i: usize| -> u32 { caps.get(i).and_then(|m| m.as_str().parse().ok()).unwrap_or(0) };
    match caps.get(c) {
        Some(_) => g(a) * 3600 + g(b) * 60 + g(c),
        None => g(a) * 60 + g(b),
    }
}

/// Renders seconds back into the canonical citation label: zero-padded
/// `MM:SS` under an hour, `H:MM:SS` (hours unpadded, minutes/seconds
/// zero-padded) beyond it — matching what `buildSummaryTranscriptPayload`
/// emits for transcript markers and what the final-report system prompt
/// instructs the model to produce.
fn format_hms(total_seconds: u32) -> String {
    let h = total_seconds / 3600;
    let m = (total_seconds % 3600) / 60;
    let s = total_seconds % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m:02}:{s:02}")
    }
}

// ---------------------------------------------------------------------
// Pass 1: verify / snap / drop existing @ref(...) tokens
// ---------------------------------------------------------------------

/// Captures an optional single leading space/tab (so a dropped token can
/// clean up after itself) plus the `@ref(...)` body.
static REF_TOKEN_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[ \t]?@ref\((\d{1,4}):([0-5]\d)(?::([0-5]\d))?\)").unwrap()
});

/// Nearest segment to `target_seconds`, returned as `(segment_seconds,
/// abs_diff)`. Ties (equal distance) favor the earlier segment.
fn nearest_segment(segments: &[Segment], target_seconds: u32) -> Option<(u32, u32)> {
    segments
        .iter()
        .map(|s| (s.seconds, s.seconds.abs_diff(target_seconds)))
        .min_by_key(|&(_, diff)| diff)
}

fn process_ref_tokens(summary_markdown: &str, segments: &[Segment]) -> (String, usize, usize, usize) {
    let mut verified = 0usize;
    let mut snapped = 0usize;
    let mut dropped = 0usize;

    let rewritten = REF_TOKEN_RE
        .replace_all(summary_markdown, |caps: &Captures| {
            let matched = caps.get(0).unwrap().as_str();
            let leading_ws = if matched.starts_with(' ') || matched.starts_with('\t') {
                &matched[..1]
            } else {
                ""
            };
            let target_seconds = seconds_from_marker_caps(caps, 1, 2, 3);

            match nearest_segment(segments, target_seconds) {
                Some((_seg_seconds, 0)) => {
                    verified += 1;
                    // Keep the model's own formatting verbatim on an exact match.
                    matched.to_string()
                }
                Some((seg_seconds, diff)) if diff <= SNAP_TOLERANCE_SECS => {
                    snapped += 1;
                    format!("{leading_ws}@ref({})", format_hms(seg_seconds))
                }
                _ => {
                    dropped += 1;
                    String::new()
                }
            }
        })
        .into_owned();

    (rewritten, verified, snapped, dropped)
}

// ---------------------------------------------------------------------
// Pass 2: conservative back-fill (tables' Ref column + Decision/Action bullets)
// ---------------------------------------------------------------------

static STOPWORDS: &[&str] = &[
    "the", "a", "an", "to", "of", "and", "or", "is", "are", "was", "be", "for", "on", "in", "it",
    "that", "this", "we", "i", "you", "he", "she", "they", "will", "with", "at", "as", "so",
    "but", "if", "do", "does",
];

/// Lowercases, strips punctuation, tokenizes on whitespace, and drops
/// stopwords + tokens shorter than 3 characters. Returned as a de-duplicated
/// set so repeated words in either the summary line or the transcript don't
/// inflate the coverage ratio.
fn content_tokens(text: &str) -> HashSet<String> {
    text.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .filter(|t| t.len() >= 3 && !STOPWORDS.contains(t))
        .map(|t| t.to_string())
        .collect()
}

/// Finds the best-scoring 1-2 adjacent-segment window matching `query`.
/// Returns `(seconds_of_first_segment_in_window, score)` when the window
/// clears both `BACKFILL_MIN_SCORE` and `MIN_TOKEN_OVERLAP`; `None`
/// otherwise (an omission, per No-Fake-State, is always the safe fallback).
fn best_match(query: &str, segments: &[Segment]) -> Option<(u32, f32)> {
    let query_tokens = content_tokens(query);
    if query_tokens.is_empty() {
        return None;
    }

    // (score, window_size, seconds, overlap) for every 1- and 2-segment
    // window. A 2-segment window's token set is a superset of its first
    // segment's alone, so it can tie or beat a more precise 1-segment match
    // purely by absorbing the neighbor's tokens — the ranking below breaks
    // ties toward the narrower window (and, failing that, the earlier
    // segment) so an adjacent unrelated line never steals the citation from
    // a segment that already matches on its own.
    let mut candidates: Vec<(f32, usize, u32, usize)> = Vec::new();

    for (i, seg) in segments.iter().enumerate() {
        let seg_tokens = content_tokens(&seg.text);

        let overlap1 = query_tokens.intersection(&seg_tokens).count();
        let score1 = overlap1 as f32 / query_tokens.len() as f32;
        candidates.push((score1, 1, seg.seconds, overlap1));

        if let Some(next) = segments.get(i + 1) {
            let merged_tokens: HashSet<String> = seg_tokens
                .union(&content_tokens(&next.text))
                .cloned()
                .collect();
            let overlap2 = query_tokens.intersection(&merged_tokens).count();
            let score2 = overlap2 as f32 / query_tokens.len() as f32;
            candidates.push((score2, 2, seg.seconds, overlap2));
        }
    }

    candidates
        .into_iter()
        .filter(|&(score, _, _, overlap)| score >= BACKFILL_MIN_SCORE && overlap >= MIN_TOKEN_OVERLAP)
        .max_by(|a, b| {
            a.0.total_cmp(&b.0)
                .then_with(|| b.1.cmp(&a.1)) // prefer the narrower (1-segment) window
                .then_with(|| b.2.cmp(&a.2)) // then the earlier segment
        })
        .map(|(score, _, seconds, _)| (seconds, score))
}

fn is_heading(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    if trimmed.starts_with('#') {
        Some(trimmed.trim_start_matches('#').trim())
    } else {
        None
    }
}

fn heading_wants_backfill(heading_text: &str) -> bool {
    let lower = heading_text.to_lowercase();
    lower.contains("decision") || lower.contains("action")
}

static BULLET_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(\s*[-*+]\s+)(.*)$").unwrap());

fn split_table_cells(line: &str) -> Vec<String> {
    let trimmed = line.trim();
    let inner = trimmed.trim_start_matches('|').trim_end_matches('|');
    inner.split('|').map(|c| c.trim().to_string()).collect()
}

fn is_separator_row(line: &str) -> bool {
    let cells = split_table_cells(line);
    !cells.is_empty()
        && cells
            .iter()
            .all(|c| !c.is_empty() && c.contains('-') && c.chars().all(|ch| ch == '-' || ch == ':'))
}

fn is_table_row(line: &str) -> bool {
    line.trim_start().starts_with('|')
}

fn clean_header_cell(cell: &str) -> String {
    cell.replace("**", "").trim().to_lowercase()
}

fn ref_cell_is_empty(cell: &str) -> bool {
    let c = cell.replace("**", "");
    let c = c.trim();
    c.is_empty() || matches!(c.to_lowercase().as_str(), "none" | "-" | "—" | "n/a")
}

fn rebuild_table_row(cells: &[String]) -> String {
    format!("| {} |", cells.join(" | "))
}

fn backfill_missing(markdown: &str, segments: &[Segment]) -> (String, usize) {
    let lines: Vec<&str> = markdown.lines().collect();
    let mut out: Vec<String> = Vec::with_capacity(lines.len());
    let mut backfilled = 0usize;
    let mut heading_wants_refs = false;

    let mut i = 0usize;
    while i < lines.len() {
        let line = lines[i];

        if let Some(heading_text) = is_heading(line) {
            heading_wants_refs = heading_wants_backfill(heading_text);
            out.push(line.to_string());
            i += 1;
            continue;
        }

        // Table detection: header row immediately followed by a separator row.
        if is_table_row(line)
            && i + 1 < lines.len()
            && is_separator_row(lines[i + 1])
        {
            let header_cells = split_table_cells(line);
            let ref_col = header_cells
                .iter()
                .position(|c| clean_header_cell(c) == "ref");

            out.push(line.to_string());
            out.push(lines[i + 1].to_string());
            i += 2;

            if let Some(ref_col) = ref_col {
                while i < lines.len() && is_table_row(lines[i]) {
                    let mut cells = split_table_cells(lines[i]);
                    if ref_col < cells.len() && ref_cell_is_empty(&cells[ref_col]) {
                        let content: String = cells
                            .iter()
                            .enumerate()
                            .filter(|(idx, _)| *idx != ref_col)
                            .map(|(_, c)| c.as_str())
                            .collect::<Vec<_>>()
                            .join(" ");
                        if let Some((seconds, _)) = best_match(&content, segments) {
                            cells[ref_col] = format!("@ref({})", format_hms(seconds));
                            backfilled += 1;
                        }
                        out.push(rebuild_table_row(&cells));
                    } else {
                        out.push(lines[i].to_string());
                    }
                    i += 1;
                }
            } else {
                // No Ref column in this table; copy body rows unmodified.
                while i < lines.len() && is_table_row(lines[i]) {
                    out.push(lines[i].to_string());
                    i += 1;
                }
            }
            continue;
        }

        // Decision/Action bullets missing a citation.
        if heading_wants_refs && !line.contains("@ref(") {
            if let Some(caps) = BULLET_RE.captures(line) {
                let prefix = &caps[1];
                let body = &caps[2];
                if let Some((seconds, _)) = best_match(body, segments) {
                    out.push(format!("{prefix}{body} @ref({})", format_hms(seconds)));
                    backfilled += 1;
                    i += 1;
                    continue;
                }
            }
        }

        out.push(line.to_string());
        i += 1;
    }

    let mut joined = out.join("\n");
    // `str::lines()` drops the trailing newline; put it back if the input had
    // one, so this pass is a no-op on prose that it doesn't touch.
    if markdown.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }

    (joined, backfilled)
}

// ---------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------

/// Stats from a single `apply_citations` pass, surfaced for logging only.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CitationStats {
    pub verified: usize,
    pub snapped: usize,
    pub dropped: usize,
    pub backfilled: usize,
}

/// Deterministically verifies, snaps, and conservatively back-fills
/// `@ref(...)` timestamp citations in `summary_markdown` against the real
/// `[MM:SS]`-marked lines in `source_transcript`. Pure function: no I/O, no
/// LLM calls, safe to call from any context. Never fabricates a timestamp —
/// every citation it emits traces to a real transcript line, and anything it
/// can't establish with confidence is dropped/omitted rather than guessed.
pub fn apply_citations(summary_markdown: &str, source_transcript: &str) -> (String, CitationStats) {
    let segments = parse_segments(source_transcript);

    let (after_refs, verified, snapped, dropped) = process_ref_tokens(summary_markdown, &segments);
    let (after_backfill, backfilled) = backfill_missing(&after_refs, &segments);

    (
        after_backfill,
        CitationStats { verified, snapped, dropped, backfilled },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE_TRANSCRIPT: &str = "\
[00:12] Paul: Let's kick off the beta review.
[01:05] Marcus: I'll own getting the beta build signed off by Friday.
[02:30] Paul: Sounds good, thanks Marcus.
[10:00] Paul: Let's also talk about the pricing page redesign.
[10:20] Priya: I can lead the pricing page redesign this sprint.
[34:43] Paul: One more thing - we decided to delay the launch to next month.
[35:01] Marcus: Agreed, launch delay makes sense given the beta timeline.
";

    #[test]
    fn exact_ref_is_verified_and_kept_unchanged() {
        let summary = "- Marcus owns the beta signoff @ref(01:05)";
        let (out, stats) = apply_citations(summary, FIXTURE_TRANSCRIPT);
        assert!(out.contains("@ref(01:05)"));
        assert_eq!(stats.verified, 1);
        assert_eq!(stats.snapped, 0);
        assert_eq!(stats.dropped, 0);
    }

    #[test]
    fn near_miss_ref_is_snapped_to_real_marker() {
        let summary = "- Launch delayed to next month @ref(34:38)";
        let (out, stats) = apply_citations(summary, FIXTURE_TRANSCRIPT);
        assert!(out.contains("@ref(34:43)"));
        assert!(!out.contains("@ref(34:38)"));
        assert_eq!(stats.snapped, 1);
        assert_eq!(stats.verified, 0);
        assert_eq!(stats.dropped, 0);
    }

    #[test]
    fn out_of_range_ref_is_dropped() {
        let summary = "- Something claimed to happen late @ref(99:59)";
        let (out, stats) = apply_citations(summary, FIXTURE_TRANSCRIPT);
        assert!(!out.contains("@ref(99:59)"));
        assert!(!out.contains("@ref("));
        assert_eq!(stats.dropped, 1);
        assert_eq!(stats.verified, 0);
        assert_eq!(stats.snapped, 0);
    }

    #[test]
    fn empty_table_ref_cell_is_backfilled_on_strong_overlap() {
        let summary = "\
## Action Items

| Owner | Action | Ref |
| --- | --- | --- |
| Marcus | I'll own getting the beta build signed off by Friday | None |
";
        let (out, stats) = apply_citations(summary, FIXTURE_TRANSCRIPT);
        assert_eq!(stats.backfilled, 1);
        assert!(out.contains("@ref(01:05)"));
        // The "None" placeholder must be gone, replaced by the citation.
        assert!(!out.contains("| None |"));
    }

    #[test]
    fn table_ref_cell_left_blank_when_overlap_is_weak() {
        let summary = "\
## Action Items

| Owner | Action | Ref |
| --- | --- | --- |
| Someone | Do a totally unrelated thing with no transcript match | None |
";
        let (out, stats) = apply_citations(summary, FIXTURE_TRANSCRIPT);
        assert_eq!(stats.backfilled, 0);
        assert!(!out.contains("@ref("));
        // Left as-is (still "None"): omission over fabrication.
        assert!(out.contains("| None |"));
    }

    #[test]
    fn decision_bullet_without_ref_gets_backfilled_on_strong_match() {
        let summary = "\
## Key Decisions

- Decided to delay the launch to next month
";
        let (out, stats) = apply_citations(summary, FIXTURE_TRANSCRIPT);
        assert_eq!(stats.backfilled, 1);
        assert!(out.contains("@ref(34:43)"));
    }

    #[test]
    fn prose_paragraph_is_never_modified() {
        let summary = "\
## Summary

This was a productive meeting about the beta build and the pricing page redesign, with no explicit timestamps mentioned anywhere in this prose paragraph.
";
        let (out, stats) = apply_citations(summary, FIXTURE_TRANSCRIPT);
        assert_eq!(out, summary);
        assert_eq!(stats.backfilled, 0);
        assert_eq!(stats.verified, 0);
        assert_eq!(stats.snapped, 0);
        assert_eq!(stats.dropped, 0);
    }
}
