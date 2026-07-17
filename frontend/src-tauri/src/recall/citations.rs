//! Inline source-citation verification for Ask answers. The model is asked to cite sources
//! inline as `[S1]`, `[S2]`, … matching the numbered Source blocks in the prompt. This
//! verifier drops any citation whose number is out of range, so the model can never invent a
//! citation (the recall "no invented citations" invariant). Cheap manual scan — no regex dep.

/// Remove `[S<n>]` markers whose `n` is not a valid 1-based source index; keep valid ones
/// (normalized to an uppercase `S`) for the UI to render as citation chips.
pub fn verify_source_citations(answer: &str, source_count: usize) -> String {
    let chars: Vec<char> = answer.chars().collect();
    let len = chars.len();
    let mut out = String::with_capacity(answer.len());
    let mut i = 0;

    while i < len {
        // Match the pattern `[` `S`/`s` <digits> `]`.
        if chars[i] == '[' && i + 1 < len && (chars[i + 1] == 'S' || chars[i + 1] == 's') {
            let digits_start = i + 2;
            let mut j = digits_start;
            while j < len && chars[j].is_ascii_digit() {
                j += 1;
            }
            if j > digits_start && j < len && chars[j] == ']' {
                let number: usize = chars[digits_start..j]
                    .iter()
                    .collect::<String>()
                    .parse()
                    .unwrap_or(0);
                if (1..=source_count).contains(&number) {
                    out.push_str(&format!("[S{number}]"));
                }
                // Invalid citation → dropped entirely.
                i = j + 1;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }

    out
}

/// Parse a `MM:SS` / `H:MM:SS` / `HH:MM:SS` label into seconds. Returns `None` for anything
/// malformed or with out-of-range minute/second fields.
pub fn parse_timestamp_label(label: &str) -> Option<u32> {
    let parts: Vec<&str> = label.trim().split(':').collect();
    match parts.as_slice() {
        [m, s] => {
            let minutes: u32 = m.trim().parse().ok()?;
            let seconds: u32 = s.trim().parse().ok()?;
            (seconds < 60).then_some(minutes * 60 + seconds)
        }
        [h, m, s] => {
            let hours: u32 = h.trim().parse().ok()?;
            let minutes: u32 = m.trim().parse().ok()?;
            let seconds: u32 = s.trim().parse().ok()?;
            (minutes < 60 && seconds < 60).then_some(hours * 3600 + minutes * 60 + seconds)
        }
        _ => None,
    }
}

fn matches_at(chars: &[char], at: usize, needle: &str) -> bool {
    needle
        .chars()
        .enumerate()
        .all(|(offset, expected)| chars.get(at + offset) == Some(&expected))
}

/// Verify inline `@ref(MM:SS)` timestamp markers against a meeting's timeline. A kept marker
/// stays as `@ref(MM:SS)` (the UI renders it as a play-badge); a rejected or unverifiable one
/// is replaced by its bare label text (readable, but not a badge — No-Fake-State).
///
/// `max_seconds = Some(dur)` keeps markers at or before `dur` (+2s tolerance) — used for
/// meeting-scoped answers where there is a single timeline. `None` strips ALL `@ref` markers —
/// used for global answers, where a bare `MM:SS` is ambiguous across meetings and must not
/// become a clickable badge.
pub fn filter_ref_timestamps(answer: &str, max_seconds: Option<u32>) -> String {
    let chars: Vec<char> = answer.chars().collect();
    let len = chars.len();
    let mut out = String::with_capacity(answer.len());
    let mut i = 0;

    while i < len {
        if chars[i] == '@' && matches_at(&chars, i, "@ref(") {
            let inner_start = i + 5;
            let mut j = inner_start;
            while j < len && chars[j] != ')' {
                j += 1;
            }
            if j < len && chars[j] == ')' {
                let label: String = chars[inner_start..j].iter().collect();
                let keep = match (parse_timestamp_label(&label), max_seconds) {
                    (Some(seconds), Some(max)) => seconds <= max.saturating_add(2),
                    _ => false,
                };
                if keep {
                    out.push_str(&format!("@ref({})", label.trim()));
                } else {
                    // Rejected/unverifiable/global — keep the readable label, drop the marker.
                    out.push_str(label.trim());
                }
                i = j + 1;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_timestamp_labels() {
        assert_eq!(parse_timestamp_label("00:40"), Some(40));
        assert_eq!(parse_timestamp_label("2:05"), Some(125));
        assert_eq!(parse_timestamp_label("1:02:15"), Some(3735));
        assert_eq!(parse_timestamp_label("not available"), None);
        assert_eq!(parse_timestamp_label("00:75"), None);
    }

    #[test]
    fn keeps_in_range_refs_and_demotes_out_of_range() {
        // Meeting duration 120s: @ref(01:30)=90s kept; @ref(05:00)=300s demoted to text.
        let answer = "Decision at @ref(01:30). Later note @ref(05:00).";
        assert_eq!(
            filter_ref_timestamps(answer, Some(120)),
            "Decision at @ref(01:30). Later note 05:00."
        );
    }

    #[test]
    fn strips_all_refs_when_no_timeline() {
        let answer = "Global mention @ref(01:30) here.";
        assert_eq!(filter_ref_timestamps(answer, None), "Global mention 01:30 here.");
    }

    #[test]
    fn keeps_valid_citations_and_normalizes_case() {
        let answer = "We decided it [S1]. Sean owns it [s2].";
        assert_eq!(
            verify_source_citations(answer, 2),
            "We decided it [S1]. Sean owns it [S2]."
        );
    }

    #[test]
    fn drops_out_of_range_and_malformed_citations() {
        // S3 is out of range (only 2 sources); [SX] and [S] are malformed → untouched.
        let answer = "A [S3] B [S1] C [SX] D [S]";
        assert_eq!(verify_source_citations(answer, 2), "A  B [S1] C [SX] D [S]");
    }

    #[test]
    fn leaves_ordinary_brackets_untouched() {
        let answer = "An array like [1, 2] and a note [see below].";
        assert_eq!(verify_source_citations(answer, 5), answer);
    }
}
