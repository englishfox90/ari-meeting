//! Cleanup of never-legitimate placeholder timestamps from Apple on-device
//! summaries.
//!
//! Ari feeds the summarizer a transcript whose lines are prefixed with REAL
//! `[MM:SS]` markers, and the summary template asks the model to cite them (and
//! to fill a "Segment Time stamp" table column). A capable model substitutes the
//! real digits (e.g. `[12:03]`); the compact on-device FoundationModels model
//! frequently echoes the LITERAL format token instead — `MM:SS`, `[MM:SS]`,
//! `(MM:SS)`, `HH:MM:SS` — leaving fake placeholder timestamps in the output.
//!
//! Those literals are never valid content (no real summary says "MM:SS"), so we
//! strip them from the Apple provider's output only (No-Fake-State: never show an
//! invented timestamp). The frontend "Referenced moments" layer already ignores
//! them (its regex requires digits), so this is purely about the visible text /
//! table. Where the model produced no real time, the cell is simply left blank —
//! honest, not fabricated.
//!
//! This is deliberately conservative: it only removes tokens built from the
//! placeholder letters `H`/`M`/`S` in a time shape, never anything with digits.

use std::sync::LazyLock;

use regex::Regex;

/// A placeholder time token wrapped in brackets or parentheses, e.g. `[MM:SS]`,
/// `(MM:SS)`, `[HH:MM:SS]`. Components are the literal letters H/M/S only.
static WRAPPED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[\[(]\s*[HMS]{1,2}:[MS]{2}(?::[MS]{2})?\s*[\])]").expect("valid regex")
});

/// A bare placeholder time token, e.g. `MM:SS`, `HH:MM:SS`, not wrapped.
static BARE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b[HMS]{1,2}:[MS]{2}(?::[MS]{2})?\b").expect("valid regex")
});

/// Empty brackets/parentheses left behind after removing a wrapped token, e.g.
/// `[]`, `[ ]`, `()`, `(  )`.
static EMPTY_DELIMS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[\[(]\s*[\])]").expect("valid regex"));

/// Collapse runs of spaces/tabs (not newlines) into a single space.
static MULTISPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[ \t]{2,}").expect("valid regex"));

/// A space that ended up directly before sentence punctuation after a removal,
/// e.g. `analysis .` → `analysis.`
static SPACE_BEFORE_PUNCT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r" +([.,;:])").expect("valid regex"));

/// Strip never-legitimate placeholder timestamps (`MM:SS`, `[MM:SS]`,
/// `(HH:MM:SS)`, …) that a weak on-device model echoes verbatim, then tidy the
/// small residue (empty `[]`/`()`, doubled spaces, a space before punctuation)
/// WITHOUT disturbing line structure (markdown tables/lists are preserved).
///
/// Pure and side-effect free. Only touches literal H/M/S time shapes — anything
/// containing digits (a real timestamp) is left exactly as-is.
pub fn strip_placeholder_timestamps(text: &str) -> String {
    // Order matters: remove wrapped tokens first (so their brackets go too),
    // then any bare tokens, then clean up whatever residue remains.
    let step1 = WRAPPED.replace_all(text, "");
    let step2 = BARE.replace_all(&step1, "");
    let step3 = EMPTY_DELIMS.replace_all(&step2, "");
    let step4 = MULTISPACE.replace_all(&step3, " ");
    let step5 = SPACE_BEFORE_PUNCT.replace_all(&step4, "$1");

    // Trim trailing spaces/tabs on each line without collapsing blank lines or
    // touching markdown table pipes' meaningful structure.
    step5
        .split('\n')
        .map(|line| line.trim_end_matches([' ', '\t']))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removes_bare_and_wrapped_placeholders() {
        assert_eq!(
            strip_placeholder_timestamps("Integrate MCP for ticket data analysis (MM:SS)."),
            "Integrate MCP for ticket data analysis."
        );
        assert_eq!(
            strip_placeholder_timestamps("Decision made [MM:SS] about scope."),
            "Decision made about scope."
        );
        assert_eq!(
            strip_placeholder_timestamps("Ran long HH:MM:SS overall"),
            "Ran long overall"
        );
    }

    #[test]
    fn cleans_markdown_table_cells_without_breaking_structure() {
        let input = "| Caleb | Explore MCP | [MM:SS] | [MM:SS] | [MM:SS] |";
        // The placeholder cells become blank; pipes/structure remain intact.
        assert_eq!(
            strip_placeholder_timestamps(input),
            "| Caleb | Explore MCP | | | |"
        );
    }

    #[test]
    fn preserves_real_digit_timestamps() {
        let input = "Kickoff [12:03] and wrap at [1:02:15].";
        assert_eq!(strip_placeholder_timestamps(input), input);
    }

    #[test]
    fn preserves_newlines_and_blank_lines() {
        let input = "Line one (MM:SS)\n\n- bullet [MM:SS]\n";
        assert_eq!(strip_placeholder_timestamps(input), "Line one\n\n- bullet\n");
    }

    #[test]
    fn leaves_ordinary_text_untouched() {
        let input = "No timestamps here — just a normal sentence with times like 3:30 PM.";
        assert_eq!(strip_placeholder_timestamps(input), input);
    }

    #[test]
    fn does_not_touch_non_time_colons() {
        // "MS:" style acronyms without the time shape must survive.
        let input = "Owner: Bob; Status: done";
        assert_eq!(strip_placeholder_timestamps(input), input);
    }
}
