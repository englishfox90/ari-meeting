// Person Profiles (F2) + Owner Context (F3) — Tauri command surface. Registered as
// `persons::commands::*` in `lib.rs`'s `generate_handler!` list under the
// `// Person Profiles (F2/F3)` block. See the frozen F2 implementation contract
// (scratchpad `F2-contract.md`) for exact argument/return shapes.

use crate::database::repositories::calendar::CalendarRepository;
use crate::database::repositories::meeting_series::MeetingSeriesRepository;
use crate::database::repositories::person::{
    top_active_facts, PersonRepository, PersonRow, ProfileFactRepository, ProfileFactRow,
    ProfileFactSourceRepository, ProfileFactSourceRow,
};
use crate::database::repositories::speaker::SpeakerRepository;
use crate::persons::extraction;
use crate::persons::models::{
    ExtractionResult, NewPerson, Person, PersonDetail, PersonSummary, ProfileFact,
    ProfileFactSource, ProfileFactWithPerson, ReconciliationResult,
};
use crate::persons::reconciliation;
use crate::state::AppState;

fn row_to_person(row: PersonRow) -> Person {
    Person {
        id: row.id,
        email: row.email,
        display_name: row.display_name,
        role: row.role,
        organization: row.organization,
        domain: row.domain,
        notes: row.notes,
        is_owner: row.is_owner != 0,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

fn row_to_fact(row: ProfileFactRow) -> ProfileFact {
    ProfileFact {
        id: row.id,
        person_id: row.person_id,
        fact_text: row.fact_text,
        fact_kind: row.fact_kind,
        source_meeting_id: row.source_meeting_id,
        source_meeting_title: row.source_meeting_title,
        source_segment_ref: row.source_segment_ref,
        source_kind: row.source_kind,
        confidence: row.confidence,
        source_count: row.source_count,
        status: row.status,
        superseded_by: row.superseded_by,
        created_at: row.created_at,
    }
}

fn row_to_source(row: ProfileFactSourceRow) -> ProfileFactSource {
    ProfileFactSource {
        id: row.id,
        fact_id: row.fact_id,
        meeting_id: row.meeting_id,
        meeting_title: row.meeting_title,
        segment_ref: row.segment_ref,
        source_kind: row.source_kind,
        relation: row.relation,
        confidence: row.confidence,
        observed_at: row.observed_at,
    }
}

async fn build_person_summary(
    pool: &sqlx::SqlitePool,
    row: PersonRow,
) -> Result<PersonSummary, sqlx::Error> {
    let active_fact_count = PersonRepository::active_fact_count(pool, &row.id).await?;
    let pending_fact_count = PersonRepository::pending_fact_count(pool, &row.id).await?;
    Ok(PersonSummary {
        id: row.id,
        email: row.email,
        display_name: row.display_name,
        role: row.role,
        organization: row.organization,
        is_owner: row.is_owner != 0,
        active_fact_count,
        pending_fact_count,
    })
}

#[tauri::command]
pub async fn person_list(state: tauri::State<'_, AppState>) -> Result<Vec<PersonSummary>, String> {
    let pool = state.db_manager.pool();
    let rows = PersonRepository::list(pool)
        .await
        .map_err(|e| format!("Failed to list persons: {}", e))?;

    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        out.push(
            build_person_summary(pool, row)
                .await
                .map_err(|e| format!("Failed to summarize person: {}", e))?,
        );
    }
    Ok(out)
}

#[tauri::command]
pub async fn person_get(
    person_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<PersonDetail, String> {
    let pool = state.db_manager.pool();
    let row = PersonRepository::get(pool, &person_id)
        .await
        .map_err(|e| format!("Failed to load person {}: {}", person_id, e))?
        .ok_or_else(|| format!("Person {} not found", person_id))?;

    let fact_rows = ProfileFactRepository::list_for_person(pool, &person_id, true)
        .await
        .map_err(|e| format!("Failed to load facts for person {}: {}", person_id, e))?;

    let meeting_count = PersonRepository::meeting_count_for_person(pool, &person_id)
        .await
        .map_err(|e| format!("Failed to count meetings for person {}: {}", person_id, e))?;

    Ok(PersonDetail {
        person: row_to_person(row),
        facts: fact_rows.into_iter().map(row_to_fact).collect(),
        meeting_count,
    })
}

#[tauri::command]
pub async fn person_upsert(
    person: NewPerson,
    state: tauri::State<'_, AppState>,
) -> Result<Person, String> {
    let row = PersonRepository::upsert_authored(state.db_manager.pool(), &person)
        .await
        .map_err(|e| format!("Failed to save person: {}", e))?;
    Ok(row_to_person(row))
}

#[tauri::command]
pub async fn person_delete(
    person_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    PersonRepository::delete(state.db_manager.pool(), &person_id)
        .await
        .map_err(|e| format!("Failed to delete person {}: {}", person_id, e))
}

#[tauri::command]
pub async fn owner_get(state: tauri::State<'_, AppState>) -> Result<Option<Person>, String> {
    let row = PersonRepository::get_owner(state.db_manager.pool())
        .await
        .map_err(|e| format!("Failed to load owner: {}", e))?;
    Ok(row.map(row_to_person))
}

#[tauri::command]
pub async fn owner_set(
    person: NewPerson,
    state: tauri::State<'_, AppState>,
) -> Result<Person, String> {
    let row = PersonRepository::set_owner(state.db_manager.pool(), &person)
        .await
        .map_err(|e| format!("Failed to set owner: {}", e))?;
    Ok(row_to_person(row))
}

#[tauri::command]
pub async fn person_import_from_event(
    event_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<Person>, String> {
    let pool = state.db_manager.pool();
    let rows = crate::persons::import::import_participants_from_event(pool, &event_id)
        .await
        .map_err(|e| format!("Failed to import attendees for event {}: {}", event_id, e))?;

    Ok(rows.into_iter().map(row_to_person).collect())
}

#[tauri::command]
pub async fn meeting_participants(
    meeting_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<PersonSummary>, String> {
    let pool = state.db_manager.pool();
    let rows = PersonRepository::list_participants(pool, &meeting_id)
        .await
        .map_err(|e| format!("Failed to list participants for meeting {}: {}", meeting_id, e))?;

    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        out.push(
            build_person_summary(pool, row)
                .await
                .map_err(|e| format!("Failed to summarize participant: {}", e))?,
        );
    }
    Ok(out)
}

#[tauri::command]
pub async fn profile_facts_for_person(
    person_id: String,
    include_superseded: bool,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<ProfileFact>, String> {
    let rows = ProfileFactRepository::list_for_person(
        state.db_manager.pool(),
        &person_id,
        include_superseded,
    )
    .await
    .map_err(|e| format!("Failed to load facts for person {}: {}", person_id, e))?;

    Ok(rows.into_iter().map(row_to_fact).collect())
}

#[tauri::command]
pub async fn profile_facts_pending(
    state: tauri::State<'_, AppState>,
) -> Result<Vec<ProfileFactWithPerson>, String> {
    let pool = state.db_manager.pool();
    let rows = ProfileFactRepository::list_pending(pool)
        .await
        .map_err(|e| format!("Failed to load pending facts: {}", e))?;

    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let person_id = row.person_id.clone();
        let person = PersonRepository::get(pool, &person_id)
            .await
            .map_err(|e| format!("Failed to load person {}: {}", person_id, e))?;
        let person_display_name = person
            .map(|p| p.display_name)
            .unwrap_or_else(|| "Unknown".to_string());

        out.push(ProfileFactWithPerson {
            fact: row_to_fact(row),
            person_id,
            person_display_name,
        });
    }
    Ok(out)
}

#[tauri::command]
pub async fn profile_fact_confirm(
    fact_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    let pool = state.db_manager.pool();
    ProfileFactRepository::set_status(pool, &fact_id, "active")
        .await
        .map_err(|e| format!("Failed to confirm fact {}: {}", fact_id, e))?;
    // Confirming resets the staleness clock (see `facts_needing_review`).
    ProfileFactRepository::touch_confirmed(pool, &fact_id)
        .await
        .map_err(|e| format!("Failed to update confirmation time for fact {}: {}", fact_id, e))?;

    // Deferred supersession: if this fact was a pending replacement for an existing one,
    // retire the old fact NOW that the replacement is enrolled. Until this moment the old
    // fact stayed active and in use. Rejecting the replacement (the other path) never gets
    // here, so the old fact is correctly left untouched.
    if let Some(old_fact_id) = ProfileFactRepository::supersedes_target(pool, &fact_id)
        .await
        .map_err(|e| format!("Failed to look up supersede target for fact {}: {}", fact_id, e))?
    {
        // Bring the old fact's sources FORWARD onto the replacement before retiring it, so no
        // provenance (or detail from the older observation) is lost — a superseding fact is
        // corroborated by every meeting the fact it replaced was, not just the latest one.
        ProfileFactSourceRepository::carry_sources(pool, &old_fact_id, &fact_id)
            .await
            .map_err(|e| format!("Failed to carry sources onto fact {}: {}", fact_id, e))?;
        // Never let a confirmed supersede silently downgrade confidence below what the
        // superseded (corroborated) fact had earned.
        if let Ok(Some(old)) = ProfileFactRepository::get_public(pool, &old_fact_id).await {
            ProfileFactSourceRepository::raise_confidence(pool, &fact_id, old.confidence)
                .await
                .map_err(|e| format!("Failed to raise confidence on fact {}: {}", fact_id, e))?;
        }
        ProfileFactRepository::supersede(pool, &old_fact_id, &fact_id)
            .await
            .map_err(|e| format!("Failed to retire superseded fact {}: {}", old_fact_id, e))?;
    }
    Ok(())
}

/// All recorded sources backing a fact (origin + reaffirmations + carried-forward lineage),
/// newest observation first. Empty for manually-added facts. Read-only; drives the person
/// detail page's "Seen in N meetings" expansion.
#[tauri::command]
pub async fn profile_fact_sources(
    fact_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<ProfileFactSource>, String> {
    let rows = ProfileFactSourceRepository::list_for_fact(state.db_manager.pool(), &fact_id)
        .await
        .map_err(|e| format!("Failed to load sources for fact {}: {}", fact_id, e))?;
    Ok(rows.into_iter().map(row_to_source).collect())
}

#[tauri::command]
pub async fn profile_fact_reject(
    fact_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    ProfileFactRepository::set_status(state.db_manager.pool(), &fact_id, "rejected")
        .await
        .map_err(|e| format!("Failed to reject fact {}: {}", fact_id, e))
}

#[tauri::command]
pub async fn profile_fact_add_manual(
    person_id: String,
    fact_text: String,
    fact_kind: String,
    state: tauri::State<'_, AppState>,
) -> Result<ProfileFact, String> {
    let row = ProfileFactRepository::insert(
        state.db_manager.pool(),
        &person_id,
        &fact_text,
        &fact_kind,
        None,
        None,
        "attributed",
        1.0,
        "active",
    )
    .await
    .map_err(|e| format!("Failed to add manual fact for person {}: {}", person_id, e))?;

    Ok(row_to_fact(row))
}

#[tauri::command]
pub async fn person_extract_facts_for_meeting(
    meeting_id: String,
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
) -> Result<ExtractionResult, String> {
    use tauri::Manager;
    let app_data_dir = app.path().app_data_dir().ok();
    extraction::extract_facts_for_meeting(
        state.db_manager.pool(),
        app_data_dir.as_deref(),
        &meeting_id,
    )
    .await
    .map_err(|e| format!("Fact extraction failed for meeting {}: {}", meeting_id, e))
}

/// Reconciles a meeting's facts against each participant's CURRENT active+pending facts
/// (add/keep/supersede/remove) instead of blindly appending new ones, then enforces the
/// per-person active-fact cap (`reconciliation::MAX_ACTIVE_FACTS_PER_PERSON`). This is the
/// command the frontend's fire-and-forget post-summary trigger calls — it supersedes plain
/// `person_extract_facts_for_meeting` for that trigger (the plain-extraction command stays
/// registered for any other caller/manual use, but is no longer wired to the summary
/// lifecycle hook).
#[tauri::command]
pub async fn person_reconcile_facts_for_meeting(
    meeting_id: String,
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
) -> Result<ReconciliationResult, String> {
    use tauri::Manager;
    let app_data_dir = app.path().app_data_dir().ok();
    reconciliation::reconcile_facts_for_meeting(
        state.db_manager.pool(),
        app_data_dir.as_deref(),
        &meeting_id,
    )
    .await
    .map_err(|e| format!("Fact reconciliation failed for meeting {}: {}", meeting_id, e))
}

/// Active/pending facts for a person that haven't been (re)confirmed in over
/// `reconciliation::STALE_AFTER_DAYS` — a read-only surface for a future "needs review" UI
/// affordance (not built in this task; see `reconciliation::facts_needing_review` doc comment
/// for the intended mount point).
#[tauri::command]
pub async fn person_facts_needing_review(
    person_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<ProfileFact>, String> {
    let rows = reconciliation::facts_needing_review(state.db_manager.pool(), &person_id)
        .await
        .map_err(|e| format!("Failed to load stale facts for person {}: {}", person_id, e))?;
    Ok(rows.into_iter().map(row_to_fact).collect())
}

/// Max profile facts injected per person (owner and participants alike), ranked by
/// confidence. Kept small so the context block stays terse (PRD F3).
const MAX_PERSON_FACTS: i64 = 4;
/// Max characters of a person's free-form notes to inject before truncating with an
/// ellipsis. Mirrors the calendar-description cap; keeps one profile from dominating.
const MAX_PERSON_NOTES_CHARS: usize = 200;

/// Trim + length-bound a person's notes for injection. Returns `None` for empty/blank
/// notes so callers can skip the segment entirely.
fn injectable_notes(notes: &str) -> Option<String> {
    let trimmed = notes.trim();
    if trimmed.is_empty() {
        return None;
    }
    let truncated: String = trimmed.chars().take(MAX_PERSON_NOTES_CHARS).collect();
    let suffix = if trimmed.chars().count() > MAX_PERSON_NOTES_CHARS {
        "…"
    } else {
        ""
    };
    Some(format!("{}{}", truncated, suffix))
}

/// Comma-join a person's top active facts into a single clause, or `None` if they have
/// no active facts.
async fn person_facts_clause(
    pool: &sqlx::SqlitePool,
    person_id: &str,
) -> Result<Option<String>, String> {
    let facts = top_active_facts(pool, person_id, MAX_PERSON_FACTS)
        .await
        .map_err(|e| format!("Failed to load facts for person {}: {}", person_id, e))?;
    if facts.is_empty() {
        return Ok(None);
    }
    Ok(Some(
        facts
            .iter()
            .map(|f| f.fact_text.as_str())
            .collect::<Vec<_>>()
            .join(", "),
    ))
}

#[tauri::command]
pub async fn summary_context_for_meeting(
    meeting_id: String,
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
) -> Result<String, String> {
    let pool = state.db_manager.pool();

    let owner = PersonRepository::get_owner(pool)
        .await
        .map_err(|e| format!("Failed to load owner: {}", e))?;

    let participants = PersonRepository::list_participants(pool, &meeting_id)
        .await
        .map_err(|e| format!("Failed to load participants for meeting {}: {}", meeting_id, e))?;

    if owner.is_none() && participants.is_empty() {
        return Ok(String::new());
    }

    // Organization is company-wide (a global config, not a per-person field). State it once.
    let organization = crate::app_config::load(&app)
        .map(|c| c.organization)
        .unwrap_or_default();

    let mut block = String::new();
    block.push_str("### Meeting context (for the summarizer)\n");
    if !organization.trim().is_empty() {
        block.push_str(&format!(
            "Organization: {} (everyone below works at {} unless noted).\n",
            organization, organization
        ));
    }

    if let Some(owner) = &owner {
        let mut line = format!("Owner: {}", owner.display_name);
        if let Some(role) = &owner.role {
            line.push_str(&format!(", {}", role));
        }
        if let Some(domain) = &owner.domain {
            line.push_str(&format!(" — {}", domain));
        }
        // Owner facts (F2) — previously omitted; the owner is a person too and their
        // confirmed facts sharpen the summary's framing.
        if let Some(clause) = person_facts_clause(pool, &owner.id).await? {
            line.push_str(&format!(": {}", clause));
        }
        if let Some(notes) = owner.notes.as_deref().and_then(injectable_notes) {
            line.push_str(&format!(". {}", notes));
        }
        block.push_str(&line);
        block.push('\n');
    }

    if !participants.is_empty() {
        block.push_str("Participants:\n");
        for participant in &participants {
            let mut line = format!("- {}", participant.display_name);
            if let Some(role) = &participant.role {
                line.push_str(&format!(" ({})", role));
            }
            // Domain (e.g. an external company) — previously dropped for participants.
            if let Some(domain) = &participant.domain {
                line.push_str(&format!(" — {}", domain));
            }

            if let Some(clause) = person_facts_clause(pool, &participant.id).await? {
                line.push_str(&format!(": {}", clause));
            }
            // Authored notes — previously dropped for participants entirely.
            if let Some(notes) = participant.notes.as_deref().and_then(injectable_notes) {
                line.push_str(&format!(". {}", notes));
            }
            block.push_str(&line);
            block.push('\n');
        }
    }

    // ---- Linked calendar event (F4 → F3) ----
    // The linked event's title/notes/attendee roster is the authoritative record of who
    // was actually invited to this meeting/room — surfacing it curbs speaker
    // misattribution (a 1:1 linked to a "Nia" event getting summarized as "Sean"). A
    // missing link or DB error must never break context assembly — absorb it into "no
    // calendar block" and keep going.
    match CalendarRepository::get_event_by_meeting_id(pool, &meeting_id).await {
        Ok(Some(event)) => {
            block.push_str("### Calendar event (authoritative attendee roster)\n");
            block.push_str(&format!("Title: {}\n", event.title));

            if let Some(notes) = event.notes.as_ref() {
                let trimmed = notes.trim();
                if !trimmed.is_empty() {
                    let truncated: String = trimmed.chars().take(400).collect();
                    let suffix = if trimmed.chars().count() > 400 { "…" } else { "" };
                    block.push_str(&format!("Description: {}{}\n", truncated, suffix));
                }
            }

            let attendee_strs: Vec<String> = event
                .attendees
                .iter()
                .filter_map(|a| {
                    let name = a.name.as_deref().map(str::trim).filter(|s| !s.is_empty());
                    let email = a.email.as_deref().map(str::trim).filter(|s| !s.is_empty());
                    match (name, email) {
                        (Some(n), Some(e)) => Some(format!("{} <{}>", n, e)),
                        (Some(n), None) => Some(n.to_string()),
                        (None, Some(e)) => Some(e.to_string()),
                        (None, None) => None,
                    }
                })
                .collect();
            if !attendee_strs.is_empty() {
                block.push_str(&format!("Attendees: {}\n", attendee_strs.join(", ")));
            }
        }
        Ok(None) => {}
        Err(e) => {
            log::debug!(
                "📅 Calendar lookup failed for meeting {} (continuing without calendar context): {}",
                meeting_id, e
            );
        }
    }

    // ---- Speakers present (F1 → F3) ----
    // Who diarization actually heard in this meeting. Complements the per-line speaker
    // prefixes: robust when many transcript lines are unlabeled. Identified speakers are
    // named; provisional/unidentified voices are COUNTED honestly, never given a fake name.
    let speakers = SpeakerRepository::list_for_meeting(pool, &meeting_id)
        .await
        .map_err(|e| format!("Failed to load speakers for meeting {}: {}", meeting_id, e))?;
    if !speakers.is_empty() {
        let mut identified_names: Vec<String> = Vec::new();
        let mut unidentified = 0usize;
        for speaker in &speakers {
            // Identified == links to a resolvable person. Otherwise it's a provisional voice.
            let name = match &speaker.person_id {
                Some(pid) => PersonRepository::get(pool, pid)
                    .await
                    .map_err(|e| format!("Failed to resolve person {}: {}", pid, e))?
                    .map(|p| p.display_name),
                None => None,
            };
            match name {
                Some(n) => identified_names.push(n),
                None => unidentified += 1,
            }
        }

        let mut parts: Vec<String> = Vec::new();
        parts.extend(identified_names);
        if unidentified == 1 {
            parts.push("1 unidentified speaker".to_string());
        } else if unidentified > 1 {
            parts.push(format!("{} unidentified speakers", unidentified));
        }

        if !parts.is_empty() {
            block.push_str("Speakers present: ");
            block.push_str(&parts.join(", "));
            block.push('\n');
        }
    }

    // ---- Series ledger (F9 → F3) ----
    // If this meeting belongs to a recurring series with a non-empty running ledger, inject
    // it so the summarizer has continuity from prior meetings (open action items, decisions,
    // recurring themes, per-person threads). No-Fake-State: append nothing when there is no
    // series or the ledger is empty. A DB error must never break context assembly.
    if let Ok(Some(series)) =
        MeetingSeriesRepository::series_for_meeting(pool, &meeting_id).await
    {
        if let Ok(Some(ledger)) = MeetingSeriesRepository::get_ledger(pool, &series.id).await {
            if let Some(ledger_md) = ledger.ledger_markdown.as_deref() {
                let trimmed = ledger_md.trim();
                if !trimmed.is_empty() {
                    block.push_str(
                        "### Series ledger (running context from prior meetings in this series)\n",
                    );
                    block.push_str(trimmed);
                    block.push('\n');
                }
            }
        }
    }

    Ok(block.trim_end().to_string())
}
