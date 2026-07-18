// Meeting Series (F9) — series detection. Called from `calendar::sync::sync_range_core`
// after auto-match, once per linked calendar event in the synced range.
//
// Detection is deliberately conservative for v1: it only groups events that BOTH have a
// stable EventKit series key (`calendarItemExternalIdentifier`) AND carry recurrence rules.
// Heuristic (no-calendar) series detection is a later phase.

use crate::database::repositories::calendar::CalendarEventRow;
use crate::database::repositories::meeting_series::MeetingSeriesRepository;
use once_cell::sync::Lazy;
use regex::Regex;
use sqlx::SqlitePool;
use std::collections::HashMap;
use uuid::Uuid;

/// Ensure a `meeting_series` exists for `event`'s recurrence key and that `event`'s linked
/// meeting is registered as a member of it.
///
/// No-op (returns `Ok(())`) unless the event is linked to a recording, has recurrence rules,
/// and carries a series key. Idempotent: re-running for the same event neither duplicates the
/// series (keyed by `series_key`) nor the membership (`upsert_member` on the PK).
pub async fn detect_series_for_event(
    pool: &SqlitePool,
    event: &CalendarEventRow,
) -> Result<(), sqlx::Error> {
    let meeting_id = match event.meeting_id.as_deref() {
        Some(id) => id,
        None => return Ok(()),
    };
    if event.has_recurrence == 0 {
        return Ok(());
    }
    let series_key = match event.series_key.as_deref() {
        Some(key) if !key.trim().is_empty() => key,
        _ => return Ok(()),
    };

    let now = chrono::Utc::now().to_rfc3339();

    // Find or create the series keyed by the stable recurrence identifier.
    let series_id = match MeetingSeriesRepository::find_series_by_key(pool, series_key).await? {
        Some(series) => series.id,
        None => {
            let id = Uuid::new_v4().to_string();
            let title = if event.title.trim().is_empty() {
                "Recurring meeting"
            } else {
                event.title.as_str()
            };
            MeetingSeriesRepository::insert_series(
                pool,
                &id,
                Some(series_key),
                title,
                None, // detected_type
                None, // cadence
                None, // owner_person_id
                &now,
            )
            .await?;
            id
        }
    };

    // Register this occurrence's meeting as an auto-linked member. Prefer the specific
    // occurrence time; fall back to the event start.
    let occurrence_time = event
        .occurrence_date
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .or(Some(event.start_time.as_str()));

    MeetingSeriesRepository::upsert_member(
        pool,
        &series_id,
        meeting_id,
        occurrence_time,
        "auto",
        &now,
    )
    .await?;

    Ok(())
}

// ===== Heuristic (non-calendar) series detection =====

// Regexes applied (in order) by `normalize_series_title` to strip volatile per-occurrence
// tokens (dates, week/instance numbers) so that recurring meetings with the same base title
// normalize equal. Deliberately conservative — only clearly date/number-shaped tokens are
// removed, never ordinary words.
static NORMALIZE_PATTERNS: Lazy<Vec<Regex>> = Lazy::new(|| {
    vec![
        // ISO date: 2026-07-15 / 2026/7/5
        Regex::new(r"\b\d{4}[-/]\d{1,2}[-/]\d{1,2}\b").unwrap(),
        // Numeric date: 7/15, 07/15/2026, 7.15 (day.month)
        Regex::new(r"\b\d{1,2}[/.]\d{1,2}(?:[/.]\d{2,4})?\b").unwrap(),
        // Month-name date: "Jul 15", "July 15th, 2026", "Jan. 3"
        Regex::new(
            r"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:\s*,?\s*\d{4})?\b",
        )
        .unwrap(),
        // Week / instance number: "week 3", "wk 3", "w3"
        Regex::new(r"(?i)\b(?:week|wk|w)\s*#?\s*\d+\b").unwrap(),
        // Trailing "#12" instance marker
        Regex::new(r"#\s*\d+").unwrap(),
        // Parenthetical pure number: "(3)"
        Regex::new(r"\(\s*\d+\s*\)").unwrap(),
        // Any now-empty parentheses left behind after a date inside them was removed
        Regex::new(r"\(\s*\)").unwrap(),
    ]
});

// Collapses any run of whitespace to a single space.
static WHITESPACE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());

/// Normalize a meeting title to a stable key for heuristic series grouping.
///
/// Lowercases, trims, strips leading/trailing dates ("2026-07-15", "Jul 15", "7/15"),
/// trailing instance markers ("#3", "(3)", "week 4"), then collapses whitespace and trims
/// leftover separators. Conservative by design: "Weekly 1:1 - Nia (Jul 8)" and
/// "Weekly 1:1 - Nia (Jul 15)" both normalize to "weekly 1:1 - nia".
pub fn normalize_series_title(title: &str) -> String {
    let mut s = title.to_lowercase();
    for re in NORMALIZE_PATTERNS.iter() {
        s = re.replace_all(&s, " ").into_owned();
    }
    // Collapse whitespace.
    s = WHITESPACE.replace_all(&s, " ").into_owned();
    // Trim leading/trailing whitespace and dangling separators left by stripped tokens.
    let trimmed = s.trim().trim_matches(|c: char| {
        c.is_whitespace() || matches!(c, '-' | '–' | '—' | ':' | '|' | '·' | ',' | '.')
    });
    // A final whitespace collapse + trim after separator trimming.
    WHITESPACE.replace_all(trimmed, " ").trim().to_string()
}

/// Cluster meetings that are not in any series by normalized title, and for each cluster of
/// 2+ meetings ensure a heuristic series exists (series_key = NULL, detected via title) with
/// all its meetings linked as `auto` members.
///
/// Returns the number of NEW series created. Idempotent: the unseriesed query excludes
/// meetings already in a series, so a second run creates nothing new. Existing heuristic
/// series with a matching normalized title are reused (find-or-create), never duplicated.
pub async fn rescan_heuristic_series(pool: &SqlitePool) -> Result<usize, sqlx::Error> {
    let meetings = MeetingSeriesRepository::list_unseriesed_meetings(pool).await?;

    // Group unseriesed meetings by normalized title, preserving created_at order.
    let mut groups: HashMap<String, Vec<crate::database::repositories::meeting_series::UnseriesedMeetingRow>> =
        HashMap::new();
    for m in meetings {
        let key = normalize_series_title(&m.title);
        if key.is_empty() {
            continue;
        }
        groups.entry(key).or_default().push(m);
    }

    // Existing heuristic (series_key = NULL) series, keyed by their own normalized title, so a
    // cluster can attach to an already-created series instead of spawning a duplicate.
    let existing = MeetingSeriesRepository::list_series(pool).await?;
    let mut existing_by_norm: HashMap<String, String> = HashMap::new();
    for s in existing.into_iter().filter(|s| s.series_key.is_none()) {
        existing_by_norm
            .entry(normalize_series_title(&s.title))
            .or_insert(s.id);
    }

    let now = chrono::Utc::now().to_rfc3339();
    let mut new_series = 0usize;

    for (norm_key, members) in groups {
        if members.len() < 2 {
            continue;
        }

        let series_id = match existing_by_norm.get(&norm_key) {
            Some(id) => id.clone(),
            None => {
                let id = Uuid::new_v4().to_string();
                // Representative title = the earliest occurrence's original title.
                let title = members[0].title.trim();
                let title = if title.is_empty() {
                    "Recurring meeting"
                } else {
                    title
                };
                MeetingSeriesRepository::insert_series(
                    pool, &id, None, title, None, None, None, &now,
                )
                .await?;
                new_series += 1;
                id
            }
        };

        for m in &members {
            MeetingSeriesRepository::upsert_member(
                pool,
                &series_id,
                &m.id,
                Some(m.created_at.as_str()),
                "auto",
                &now,
            )
            .await?;
        }
    }

    Ok(new_series)
}

#[cfg(test)]
mod tests {
    use super::normalize_series_title;

    #[test]
    fn recurring_dates_normalize_equal() {
        assert_eq!(
            normalize_series_title("Weekly 1:1 - Nia (Jul 8)"),
            normalize_series_title("Weekly 1:1 - Nia (Jul 15)")
        );
        assert_eq!(
            normalize_series_title("Weekly 1:1 - Nia (Jul 8)"),
            "weekly 1:1 - nia"
        );
    }

    #[test]
    fn strips_leading_iso_date() {
        assert_eq!(normalize_series_title("2026-07-15 Team Sync"), "team sync");
        assert_eq!(normalize_series_title("Team Sync 2026-07-15"), "team sync");
    }

    #[test]
    fn strips_numeric_and_slash_dates() {
        assert_eq!(normalize_series_title("Team Sync 7/15"), "team sync");
        assert_eq!(normalize_series_title("Team Sync 07/15/2026"), "team sync");
    }

    #[test]
    fn strips_instance_and_week_markers() {
        assert_eq!(normalize_series_title("Standup #12"), "standup");
        assert_eq!(normalize_series_title("Standup (3)"), "standup");
        assert_eq!(normalize_series_title("Design Review week 4"), "design review");
    }

    #[test]
    fn collapses_whitespace_and_lowercases() {
        assert_eq!(
            normalize_series_title("  Design   Review  "),
            "design review"
        );
        assert_eq!(normalize_series_title("PROJECT Kickoff"), "project kickoff");
    }

    #[test]
    fn preserves_plain_titles() {
        // No date/number tokens — only lowercased/trimmed.
        assert_eq!(normalize_series_title("Project Kickoff"), "project kickoff");
        // The "1:1" is not a date and must survive.
        assert!(normalize_series_title("Weekly 1:1 - Nia (Jul 8)").contains("1:1"));
    }

    #[test]
    fn different_titles_stay_distinct() {
        assert_ne!(
            normalize_series_title("Weekly 1:1 - Nia (Jul 8)"),
            normalize_series_title("Weekly 1:1 - Sean (Jul 8)")
        );
    }
}
