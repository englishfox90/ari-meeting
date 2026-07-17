//! Meeting-attributed ledger citations (F9).
//!
//! The series ledger is produced by folding each member meeting's summary — which
//! carries verified `@ref(MM:SS)` tokens — through an LLM reduce. In the ledger a bare
//! `@ref(04:21)` is ambiguous: which meeting? This module makes citations
//! meeting-attributed so the series page can render clickable badges that deep-link to the
//! right meeting at the right offset.
//!
//! Two deterministic, pure passes (no I/O, no LLM):
//!
//! 1. [`qualify_refs`] — BEFORE the reduce, rewrite each source summary's `@ref(<TS>)`
//!    (and the legacy `[MM:SS]` bracket form) into `@mref(m<N>@<TS>)`, where `<N>` is the
//!    1-based index of that meeting in the series' chronological member ordering (exactly
//!    `MeetingSeriesRepository::list_members` order). The LLM then carries these verbatim.
//! 2. [`validate_qualified_refs`] — AFTER the reduce, drop any `@mref` whose `<N>` is out of
//!    range (LLM mangling / hallucination guard), degrading it to the plain `<TS>` text so
//!    the time is still shown but never as a dead badge. This is the No-Fake-State guard.
//!
//! The `@mref(...)` marker is deliberately DISTINCT from the summary `@ref(...)` marker so
//! summary citation code (`summary::citations`, `summary-timestamps.ts`) never touches it,
//! and vice versa. The forms are:
//!   - summary:  `@ref(04:21)`
//!   - ledger:   `@mref(m2@04:21)`   (m2 = 2nd meeting of the series, at 04:21)

use once_cell::sync::Lazy;
use regex::{Captures, Regex};

/// A timestamp body: `M:SS` / `MM:SS` / `H:MM:SS`. The first group is intentionally
/// `\d{1,4}` (not `\d{1,2}`) to mirror `summary::citations::REF_TOKEN_RE` — a >59-minute
/// meeting can emit markers like `75:23` rather than rolling into an hour component. The
/// last groups (minutes/seconds) are constrained to `00`-`59`.
const TS_BODY: &str = r"\d{1,4}:[0-5]\d(?::[0-5]\d)?";

/// Matches a summary `@ref(<TS>)` token, capturing the timestamp body.
static REF_TOKEN_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(&format!(r"@ref\(({TS_BODY})\)")).unwrap());

/// Matches the legacy bracket citation form `[<TS>]`, capturing the timestamp body. The
/// literal square brackets + a `MM:SS` shape mean plain numbers / ISO dates never match —
/// same guard `summary-timestamps.ts` (`BRACKET_TIMESTAMP_RE`) relies on.
static BRACKET_TOKEN_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(&format!(r"\[({TS_BODY})\]")).unwrap());

/// Matches a qualified ledger citation `@mref(m<N>@<TS>)`, capturing `N` and the `<TS>` body.
static MREF_TOKEN_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(&format!(r"@mref\(m(\d+)@({TS_BODY})\)")).unwrap());

/// Rewrite every `@ref(<TS>)` and legacy `[<TS>]` citation in `summary_markdown` into a
/// meeting-attributed `@mref(m<N>@<TS>)`, with `N = member_index_1based`. All other text is
/// left byte-for-byte unchanged. Pure: no I/O, no LLM.
///
/// Call this on EACH member's summary markdown just before it is folded into the reduce
/// prompt, so the qualified marker survives the LLM pass and can be validated afterward.
pub fn qualify_refs(summary_markdown: &str, member_index_1based: usize) -> String {
    // Pass 1: @ref(TS) → @mref(mN@TS)
    let after_ref = REF_TOKEN_RE.replace_all(summary_markdown, |caps: &Captures| {
        format!("@mref(m{}@{})", member_index_1based, &caps[1])
    });

    // Pass 2: legacy [TS] → @mref(mN@TS). Runs on the pass-1 output; the two forms are
    // disjoint (one requires `@ref(...)`, the other literal `[...]`) so order is irrelevant.
    let after_bracket = BRACKET_TOKEN_RE.replace_all(&after_ref, |caps: &Captures| {
        format!("@mref(m{}@{})", member_index_1based, &caps[1])
    });

    after_bracket.into_owned()
}

/// Drop any `@mref(m<N>@<TS>)` whose `N` is not in `1..=member_count`, replacing it with the
/// plain `<TS>` text (so the moment is still readable, just not a dead badge). In-range
/// markers are kept verbatim. Pure: no I/O, no LLM.
///
/// This is the No-Fake-State guard against the LLM inventing or corrupting a meeting index
/// during the reduce. `member_count` is the total number of members in the series (the
/// valid range of `N`, matching `SeriesDetail.members` length).
pub fn validate_qualified_refs(ledger_markdown: &str, member_count: usize) -> String {
    MREF_TOKEN_RE
        .replace_all(ledger_markdown, |caps: &Captures| {
            let n: usize = caps[1].parse().unwrap_or(0);
            if n >= 1 && n <= member_count {
                // Keep the marker exactly as the model emitted it.
                caps[0].to_string()
            } else {
                // Out of range → degrade to plain time text (never a dead badge).
                caps[2].to_string()
            }
        })
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qualifies_single_ref() {
        let input = "- Ship the beta @ref(04:21)";
        assert_eq!(qualify_refs(input, 2), "- Ship the beta @mref(m2@04:21)");
    }

    #[test]
    fn qualifies_multiple_refs_with_same_index() {
        let input = "Decision @ref(1:02) and action @ref(12:30) and late @ref(1:05:09).";
        assert_eq!(
            qualify_refs(input, 3),
            "Decision @mref(m3@1:02) and action @mref(m3@12:30) and late @mref(m3@1:05:09)."
        );
    }

    #[test]
    fn qualifies_legacy_bracket_form() {
        let input = "Marcus owned signoff [01:05]";
        assert_eq!(qualify_refs(input, 1), "Marcus owned signoff @mref(m1@01:05)");
    }

    #[test]
    fn passthrough_when_no_refs() {
        let input = "## Decisions\n- We agreed to delay launch.\nSee doc [link](http://x/1:2).";
        assert_eq!(qualify_refs(input, 4), input);
    }

    #[test]
    fn does_not_match_plain_numbers_or_dates() {
        // No brackets / no @ref → untouched.
        let input = "Budget was 4:21 discussed on 2026-07-15, ratio 3:2.";
        assert_eq!(qualify_refs(input, 1), input);
    }

    #[test]
    fn validate_keeps_in_range() {
        let input = "Do X @mref(m1@04:21) and Y @mref(m3@10:00).";
        assert_eq!(validate_qualified_refs(input, 3), input);
    }

    #[test]
    fn validate_drops_out_of_range_to_plain_time() {
        let input = "Ok @mref(m1@04:21) but bogus @mref(m9@10:00) here.";
        assert_eq!(
            validate_qualified_refs(input, 3),
            "Ok @mref(m1@04:21) but bogus 10:00 here."
        );
    }

    #[test]
    fn validate_drops_zero_index() {
        let input = "Bad @mref(m0@00:30).";
        assert_eq!(validate_qualified_refs(input, 5), "Bad 00:30.");
    }

    #[test]
    fn validate_passthrough_without_markers() {
        let input = "## Recurring themes\n- Pricing keeps coming up.";
        assert_eq!(validate_qualified_refs(input, 2), input);
    }

    #[test]
    fn roundtrip_qualify_then_validate() {
        let summary = "- Delay launch @ref(34:43)\n- Sign off @ref(01:05)";
        let qualified = qualify_refs(summary, 2);
        // Model preserved them → all in range → validation is a no-op.
        assert_eq!(validate_qualified_refs(&qualified, 4), qualified);
        assert!(qualified.contains("@mref(m2@34:43)"));
        assert!(qualified.contains("@mref(m2@01:05)"));
    }
}
