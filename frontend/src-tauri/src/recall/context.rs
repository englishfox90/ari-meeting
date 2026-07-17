//! Phase 2 context enrichment for Ask Meetings. Two jobs, both pool-only (runtime-agnostic,
//! no AppHandle needed):
//!   1. `attach_people` — stamp each source with the people present in its meeting (for
//!      person tags in the UI and so the model knows who is who).
//!   2. `people_context_block` — a terse owner/attendee/calendar reference block appended to
//!      the prompt so questions about who-owns-what / when-scheduled can be answered.
//! Everything stays additive and bounded to avoid prompt bloat.

use std::collections::{HashMap, HashSet};

use sqlx::SqlitePool;

use crate::api::LocalRecallSource;
use crate::database::repositories::{
    calendar::CalendarRepository,
    person::{top_active_facts, PersonRepository},
};

const MAX_PEOPLE_PER_MEETING: usize = 8;
const MAX_FACT_CHARS: usize = 160;
const MAX_NOTE_CHARS: usize = 300;

fn truncate_chars(text: &str, max: usize) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= max {
        return trimmed.to_string();
    }
    let head: String = trimmed.chars().take(max).collect();
    format!("{head}…")
}

fn short_date(rfc3339: &str) -> String {
    rfc3339.chars().take(10).collect()
}

/// Distinct people associated with a meeting: identified speakers first (diarization →
/// person names), then any additional linked participants. Never fabricates names.
async fn meeting_people(pool: &SqlitePool, meeting_id: &str) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    let mut push_unique = |name: String, names: &mut Vec<String>| {
        let name = name.trim().to_string();
        if !name.is_empty() && !names.iter().any(|n| n.eq_ignore_ascii_case(&name)) {
            names.push(name);
        }
    };

    if let Ok(pairs) =
        crate::diarization::labeling::resolve_meeting_speaker_labels(pool, meeting_id).await
    {
        for (_transcript_id, name) in pairs {
            push_unique(name, &mut names);
        }
    }
    // Fall back to the linked calendar/participant roster ONLY when nobody was identified as
    // having spoken. Otherwise a 2-person 1:1 would be stamped with the whole 12-person invite
    // (including email-only attendees) on every source — pure noise in the person tags.
    if names.is_empty() {
        if let Ok(participants) = PersonRepository::list_participants(pool, meeting_id).await {
            for person in participants {
                push_unique(person.display_name, &mut names);
            }
        }
    }

    names.truncate(MAX_PEOPLE_PER_MEETING);
    names
}

/// Populate `speakers` on every source (cached per meeting).
pub async fn attach_people(pool: &SqlitePool, sources: &mut [LocalRecallSource]) {
    let mut cache: HashMap<String, Vec<String>> = HashMap::new();
    for source in sources.iter_mut() {
        if !cache.contains_key(&source.meeting_id) {
            let people = meeting_people(pool, &source.meeting_id).await;
            cache.insert(source.meeting_id.clone(), people);
        }
        source.speakers = cache.get(&source.meeting_id).cloned().unwrap_or_default();
    }
}

/// Build the terse owner + attendee/calendar reference block for the prompt. Returns "" when
/// there is nothing to add. `scoped_meeting_id` = Some for a meeting-scoped ask (richer, one
/// meeting), None for global (per-meeting people lines from the sources).
pub async fn people_context_block(
    pool: &SqlitePool,
    sources: &[LocalRecallSource],
    scoped_meeting_id: Option<&str>,
) -> String {
    let mut lines: Vec<String> = Vec::new();

    if let Ok(Some(owner)) = PersonRepository::get_owner(pool).await {
        let mut who = owner.display_name.clone();
        if let Some(role) = owner.role.as_deref().map(str::trim).filter(|r| !r.is_empty()) {
            who.push_str(&format!(", {role}"));
        }
        if let Some(org) = owner
            .organization
            .as_deref()
            .map(str::trim)
            .filter(|o| !o.is_empty())
        {
            who.push_str(&format!(" at {org}"));
        }
        lines.push(format!("Owner (you): {who}."));
    }

    match scoped_meeting_id {
        Some(meeting_id) => {
            if let Ok(Some(event)) =
                CalendarRepository::get_event_by_meeting_id(pool, meeting_id).await
            {
                let attendees: Vec<String> = event
                    .attendees
                    .iter()
                    .filter_map(|a| {
                        a.name
                            .as_deref()
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                            .map(str::to_string)
                            .or_else(|| a.email.clone())
                    })
                    .collect();
                if !attendees.is_empty() {
                    lines.push(format!(
                        "Calendar event \"{}\": attendees — {}.",
                        event.title,
                        attendees.join(", ")
                    ));
                }
                if let Some(notes) =
                    event.notes.as_deref().map(str::trim).filter(|n| !n.is_empty())
                {
                    lines.push(format!("Event notes: {}", truncate_chars(notes, MAX_NOTE_CHARS)));
                }
            }
            if let Ok(participants) = PersonRepository::list_participants(pool, meeting_id).await {
                for person in participants.into_iter().take(6) {
                    if let Ok(facts) = top_active_facts(pool, &person.id, 1).await {
                        if let Some(fact) = facts.first() {
                            lines.push(format!(
                                "- {}: {}",
                                person.display_name,
                                truncate_chars(&fact.fact_text, MAX_FACT_CHARS)
                            ));
                        }
                    }
                }
            }
        }
        None => {
            let mut seen: HashSet<&str> = HashSet::new();
            for source in sources {
                if !seen.insert(source.meeting_id.as_str()) || source.speakers.is_empty() {
                    continue;
                }
                let date = source
                    .meeting_date
                    .as_deref()
                    .map(short_date)
                    .filter(|d| !d.is_empty())
                    .map(|d| format!(" ({d})"))
                    .unwrap_or_default();
                lines.push(format!(
                    "- \"{}\"{} — people: {}.",
                    source.title,
                    date,
                    source.speakers.join(", ")
                ));
            }
        }
    }

    if lines.is_empty() {
        return String::new();
    }
    format!(
        "### People & meeting context (reference only; transcript sources remain authoritative)\n{}",
        lines.join("\n")
    )
}
