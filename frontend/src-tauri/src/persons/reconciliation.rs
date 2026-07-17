// Person Profiles (F2) fact-RECONCILIATION engine. Supersedes plain extraction
// (`extraction::extract_facts_for_meeting`) as the trigger fired after a summary completes.
//
// The problem plain extraction had: it only ever INSERTs new pending facts, so a person's
// fact list grows without bound and accumulates near-duplicates ("wants to ship v2 by Q3"
// / "wants to ship v2 by end of Q3" / "is targeting Q3 for v2"...). Reconciliation instead
// shows the model each participant's CURRENT facts (active + pending, with id/kind/
// confidence/age) alongside the newly observed transcript, and asks it to decide, per
// participant, whether new information should be ADDed, an existing fact should be KEPT
// unchanged, SUPERSEDEd with an updated version, or REMOVEd. A per-person active-fact cap
// (`MAX_ACTIVE_FACTS_PER_PERSON`) is enforced afterward as a hard backstop regardless of
// what the model decided.
//
// Same degrade-gracefully contract as `extraction.rs`: unconfigured provider, empty
// transcript, no participants, or a malformed model response all return a `created: 0`-
// shaped no-op (`ReconciliationResult` with all counters 0) — never panic, never hard-error
// the caller. Reuses the SAME LLM provider dispatch as `summary::llm_client` (no new
// client) and the SAME "must have linked participants" gate as extraction.
//
// No-Fake-State: every ADD/SUPERSEDE operation must carry a `source_segment_ref` (the
// evidence quote/timestamp from the transcript). Operations missing required evidence are
// skipped, never guessed.

use std::path::Path;

use anyhow::Result;
use chrono::{DateTime, Utc};
use sqlx::SqlitePool;

use crate::database::repositories::person::{
    PersonRepository, PersonRow, ProfileFactRepository, ProfileFactRow,
    ProfileFactSourceRepository,
};
use crate::database::repositories::setting::SettingsRepository;
use crate::persons::extraction::{resolve_person, strip_code_fences};
use crate::persons::models::ReconciliationResult;
use crate::summary::llm_client::{generate_summary, LLMProvider};

const MAX_TRANSCRIPT_CHARS: usize = 48_000; // mirror extraction.rs / local-recall context bound

/// Hard cap on ACTIVE facts per person. Once a person crosses this, the lowest-confidence /
/// oldest active facts are pruned (status -> 'removed') regardless of what the model's
/// reconciliation ops decided — a backstop so profiles stay small and skimmable rather than
/// accumulating indefinitely.
pub const MAX_ACTIVE_FACTS_PER_PERSON: i64 = 12;

/// Hard cap on PENDING (awaiting confirm-before-enroll) facts per person. Prevents an
/// unbounded backlog when a person is never reviewed on the People page; the lowest-
/// confidence / oldest pending facts are pruned beyond this. Independent of the active cap.
pub const MAX_PENDING_FACTS_PER_PERSON: i64 = 10;

/// A fact is considered stale (needing reconfirmation or removal) once neither its creation
/// nor its last confirmation has happened within this window. 4 weeks.
pub const STALE_AFTER_DAYS: i64 = 28;

#[derive(serde::Deserialize, Debug)]
struct ReconcileOp {
    person_email: Option<String>,
    person_name: Option<String>,
    op: String, // "add" | "supersede" | "keep" | "remove"
    #[serde(default)]
    fact_id: Option<String>,
    #[serde(default)]
    fact_text: Option<String>,
    #[serde(default)]
    fact_kind: Option<String>,
    #[serde(default)]
    confidence: Option<f64>,
    #[serde(default)]
    source_segment_ref: Option<String>,
    #[serde(default)]
    #[allow(dead_code)] // kept for prompt fidelity / future debugging surfacing, not applied
    reason: Option<String>,
}

/// Entry point, fired after a summary completes (same trigger point as
/// `extraction::extract_facts_for_meeting`, which this supersedes). Never returns `Err` for
/// "nothing useful happened" cases — those are honest all-zero results. `Err` is reserved
/// for genuine DB-access failures.
pub async fn reconcile_facts_for_meeting(
    pool: &SqlitePool,
    app_data_dir: Option<&Path>,
    meeting_id: &str,
) -> Result<ReconciliationResult> {
    let empty_result = |message: &str| ReconciliationResult {
        meeting_id: meeting_id.to_string(),
        added: 0,
        superseded: 0,
        kept: 0,
        removed: 0,
        capped: 0,
        message: message.to_string(),
    };

    let participants = PersonRepository::list_participants(pool, meeting_id).await?;
    if participants.is_empty() {
        return Ok(empty_result(
            "No linked participants for this meeting — nothing to reconcile.",
        ));
    }

    let transcript_text =
        match crate::diarization::labeling::build_labeled_transcript_text(pool, meeting_id).await? {
            Some(labeled) => labeled,
            None => crate::persons::extraction::load_transcript_text(pool, meeting_id).await?,
        };
    if transcript_text.trim().is_empty() {
        return Ok(empty_result("No transcript text found for this meeting."));
    }

    let Some(config) = SettingsRepository::get_model_config(pool).await? else {
        return Ok(empty_result(
            "No summarization provider configured — skipping fact reconciliation.",
        ));
    };

    let provider = match LLMProvider::from_str(&config.provider) {
        Ok(p) => p,
        Err(e) => return Ok(empty_result(&format!("Unsupported provider: {}", e))),
    };

    let api_key = if matches!(
        provider,
        LLMProvider::Ollama | LLMProvider::BuiltInAI | LLMProvider::CustomOpenAI
    ) {
        String::new()
    } else {
        match SettingsRepository::get_api_key(pool, &config.provider).await? {
            Some(key) if !key.is_empty() => key,
            _ => {
                return Ok(empty_result(&format!(
                    "No API key configured for {} — skipping fact reconciliation.",
                    config.provider
                )))
            }
        }
    };

    let ollama_endpoint = if provider == LLMProvider::Ollama {
        config.ollama_endpoint.clone()
    } else {
        None
    };

    let (custom_openai_endpoint, custom_openai_api_key) = if provider == LLMProvider::CustomOpenAI
    {
        match SettingsRepository::get_custom_openai_config(pool).await? {
            Some(cfg) => (Some(cfg.endpoint), cfg.api_key),
            None => {
                return Ok(empty_result(
                    "Custom OpenAI provider selected but not configured — skipping fact reconciliation.",
                ))
            }
        }
    } else {
        (None, None)
    };

    let final_api_key = if provider == LLMProvider::CustomOpenAI {
        custom_openai_api_key.unwrap_or_default()
    } else {
        api_key
    };

    // Load each participant's CURRENT facts (active + pending) so the model reconciles
    // against them instead of blindly appending.
    let mut existing_facts_by_person: Vec<(&PersonRow, Vec<ProfileFactRow>)> = Vec::new();
    for participant in &participants {
        let facts =
            ProfileFactRepository::list_active_and_pending_for_person(pool, &participant.id)
                .await?;
        existing_facts_by_person.push((participant, facts));
    }

    let now = Utc::now();
    let participant_block = existing_facts_by_person
        .iter()
        .map(|(person, facts)| format_person_block(person, facts, now))
        .collect::<Vec<_>>()
        .join("\n\n");

    let bounded_transcript: String = transcript_text.chars().take(MAX_TRANSCRIPT_CHARS).collect();

    let system_prompt = "You maintain a SMALL, managed set of facts about each meeting \
        participant — you do not let it grow without bound. You are shown each participant's \
        CURRENT facts (with their id, kind, confidence, and age) plus a new meeting \
        transcript. For every piece of concrete new information, and for every existing fact \
        that the transcript touches on, decide one operation. Output STRICT JSON only — a \
        JSON array, no prose, no markdown code fences. If nothing in the transcript is \
        concrete or relevant, output an empty array `[]`. Never invent facts or ids that \
        were not given to you.";

    let user_prompt = format!(
        "Participants and their CURRENT facts:\n{}\n\nNew transcript:\n{}\n\n\
        For each fact-worthy observation, output one JSON object. Valid operations:\n\
        - \"add\": a genuinely NEW fact not already covered by an existing one. Requires \
          fact_text, fact_kind, confidence, source_segment_ref. fact_id must be null.\n\
        - \"supersede\": an EXISTING fact (by fact_id) is now outdated/incomplete and should \
          be replaced with an updated fact_text. Requires fact_id, fact_text, fact_kind, \
          confidence, source_segment_ref.\n\
        - \"keep\": an EXISTING fact (by fact_id) is reaffirmed by this transcript and stays \
          exactly as-is. Requires only fact_id.\n\
        - \"remove\": an EXISTING fact (by fact_id) is contradicted, no longer true, or is a \
          near-duplicate of a better fact and should be dropped. Requires only fact_id.\n\
        Do NOT add a fact that duplicates or lightly rephrases one already listed — use \
        \"supersede\" on the existing fact_id instead. Only emit ops for facts you have real \
        evidence for; when unsure, omit rather than guess.\n\n\
        Output a JSON array where each item is:\n\
        {{\"person_email\": string|null, \"person_name\": string, \"op\": \"add\"|\"supersede\"|\"keep\"|\"remove\", \
        \"fact_id\": string|null, \"fact_text\": string|null, \
        \"fact_kind\": \"goal\"|\"interest\"|\"project\"|\"role_signal\"|\"other\"|null, \
        \"confidence\": number|null, \"source_segment_ref\": string|null, \"reason\": string|null}}",
        participant_block, bounded_transcript
    );

    let client = reqwest::Client::new();
    let raw_response = match generate_summary(
        &client,
        &provider,
        &config.model,
        &final_api_key,
        system_prompt,
        &user_prompt,
        ollama_endpoint.as_deref(),
        custom_openai_endpoint.as_deref(),
        None,
        None,
        None,
        app_data_dir.map(|p| p.to_path_buf()).as_ref(),
        None,
    )
    .await
    {
        Ok(text) => text,
        Err(e) => return Ok(empty_result(&format!("LLM call failed: {}", e))),
    };

    let ops = match parse_ops(&raw_response) {
        Ok(ops) => ops,
        Err(e) => {
            return Ok(empty_result(&format!(
                "Could not parse model response as JSON: {}",
                e
            )))
        }
    };

    if ops.is_empty() {
        return Ok(empty_result("No fact changes needed for this meeting."));
    }

    let mut added = 0i64;
    let mut superseded = 0i64;
    let mut kept = 0i64;
    let mut removed = 0i64;

    for op in ops {
        let Some(person) =
            resolve_person(&participants, op.person_email.as_deref(), op.person_name.as_deref())
        else {
            continue; // can't attribute this op to a known participant — skip, never guess
        };

        // Only allow fact_id references that actually belong to THIS person's existing
        // fact set — never let the model touch another participant's facts.
        let existing_for_person = existing_facts_by_person
            .iter()
            .find(|(p, _)| p.id == person.id)
            .map(|(_, facts)| facts.as_slice())
            .unwrap_or(&[]);

        match op.op.as_str() {
            "add" => {
                let (Some(fact_text), Some(evidence)) =
                    (op.fact_text.as_deref(), op.source_segment_ref.as_deref())
                else {
                    continue; // No-Fake-State: an added fact must carry evidence
                };
                if fact_text.trim().is_empty() || evidence.trim().is_empty() {
                    continue;
                }
                let fact_kind = op.fact_kind.as_deref().unwrap_or("other");
                let confidence = op.confidence.unwrap_or(0.0).clamp(0.0, 1.0);

                let new_row = ProfileFactRepository::insert(
                    pool,
                    &person.id,
                    fact_text,
                    fact_kind,
                    Some(meeting_id),
                    Some(evidence),
                    "attributed",
                    confidence,
                    "pending",
                )
                .await?;
                // Record this meeting as the fact's origin source (F2 multi-source facts).
                ProfileFactSourceRepository::add_source(
                    pool,
                    &new_row.id,
                    Some(meeting_id),
                    Some(evidence),
                    "attributed",
                    "origin",
                    confidence,
                )
                .await?;
                added += 1;
            }
            "supersede" => {
                let Some(fact_id) = op.fact_id.as_deref() else {
                    continue;
                };
                if !existing_for_person.iter().any(|f| f.id == fact_id) {
                    continue; // fact_id not owned by this person — refuse to guess
                }
                let (Some(fact_text), Some(evidence)) =
                    (op.fact_text.as_deref(), op.source_segment_ref.as_deref())
                else {
                    continue;
                };
                if fact_text.trim().is_empty() || evidence.trim().is_empty() {
                    continue;
                }
                let fact_kind = op.fact_kind.as_deref().unwrap_or("other");
                let confidence = op.confidence.unwrap_or(0.0).clamp(0.0, 1.0);

                let new_row = ProfileFactRepository::insert(
                    pool,
                    &person.id,
                    fact_text,
                    fact_kind,
                    Some(meeting_id),
                    Some(evidence),
                    "attributed",
                    confidence,
                    "pending",
                )
                .await?;
                // Record this meeting as the replacement's origin source. The OLD fact's
                // sources are carried forward onto this row only when the user confirms the
                // replacement (see `profile_fact_confirm`) — that's where the two sets are
                // brought together, so nothing is merged prematurely for a proposal that may
                // be rejected.
                ProfileFactSourceRepository::add_source(
                    pool,
                    &new_row.id,
                    Some(meeting_id),
                    Some(evidence),
                    "attributed",
                    "origin",
                    confidence,
                )
                .await?;
                // Deferred supersession: record the replacement's intent but DO NOT retire
                // the old fact yet. The old fact stays active (and in summaries) until the
                // user confirms this pending replacement, at which point `profile_fact_confirm`
                // retires it. Rejecting the replacement leaves the old fact untouched.
                ProfileFactRepository::mark_supersedes(pool, &new_row.id, fact_id).await?;
                superseded += 1;
            }
            "keep" => {
                let Some(fact_id) = op.fact_id.as_deref() else {
                    continue;
                };
                if !existing_for_person.iter().any(|f| f.id == fact_id) {
                    continue;
                }
                // Reaffirmed by fresh evidence — reset the staleness clock, same effect as
                // an explicit user confirmation.
                ProfileFactRepository::touch_confirmed(pool, fact_id).await?;
                // Record THIS meeting as a corroborating source (deduped so re-running
                // reconciliation for the same meeting can't double-count it). Confidence
                // falls back to the fact's current value when the model didn't provide one.
                let existing_confidence = existing_for_person
                    .iter()
                    .find(|f| f.id == fact_id)
                    .map(|f| f.confidence)
                    .unwrap_or(0.0);
                let source_confidence = op.confidence.unwrap_or(existing_confidence).clamp(0.0, 1.0);
                ProfileFactSourceRepository::add_source_dedup(
                    pool,
                    fact_id,
                    Some(meeting_id),
                    op.source_segment_ref.as_deref(),
                    "attributed",
                    "reaffirmed",
                    source_confidence,
                )
                .await?;
                kept += 1;
            }
            "remove" => {
                let Some(fact_id) = op.fact_id.as_deref() else {
                    continue;
                };
                if !existing_for_person.iter().any(|f| f.id == fact_id) {
                    continue;
                }
                ProfileFactRepository::mark_removed(pool, fact_id).await?;
                removed += 1;
            }
            _ => continue, // unknown op — skip, never guess
        }
    }

    // Backstop: regardless of what the model decided, keep each participant's ACTIVE and
    // PENDING fact counts under their respective caps by pruning the lowest-confidence /
    // oldest facts in each bucket.
    let mut capped = 0i64;
    for participant in &participants {
        capped += ProfileFactRepository::trim_active_to_cap(
            pool,
            &participant.id,
            MAX_ACTIVE_FACTS_PER_PERSON,
        )
        .await?;
        capped += ProfileFactRepository::trim_pending_to_cap(
            pool,
            &participant.id,
            MAX_PENDING_FACTS_PER_PERSON,
        )
        .await?;
    }

    let message = format!(
        "Reconciled facts: {} added, {} superseded (pending confirm), {} kept, {} removed{}.",
        added,
        superseded,
        kept,
        removed,
        if capped > 0 {
            format!(", {} pruned for exceeding a per-person cap", capped)
        } else {
            String::new()
        }
    );

    Ok(ReconciliationResult {
        meeting_id: meeting_id.to_string(),
        added,
        superseded,
        kept,
        removed,
        capped,
        message,
    })
}

/// Facts for `person_id` that haven't been (re)confirmed in `STALE_AFTER_DAYS` — surfaced
/// for a future UI affordance (not built in this task) that would let the user bulk-confirm
/// or bulk-dismiss stale facts. Natural mount point: a "Needs review" section on the
/// person detail page (`src/app/people/[id]/page.tsx`-equivalent), next to the existing
/// pending-facts confirm/reject UI.
pub async fn facts_needing_review(
    pool: &SqlitePool,
    person_id: &str,
) -> Result<Vec<ProfileFactRow>> {
    Ok(ProfileFactRepository::facts_needing_review(pool, person_id, STALE_AFTER_DAYS).await?)
}

fn format_person_block(person: &PersonRow, facts: &[ProfileFactRow], now: DateTime<Utc>) -> String {
    let header = format!(
        "- {} <{}>",
        person.display_name,
        person.email.as_deref().unwrap_or("no email")
    );
    if facts.is_empty() {
        return format!("{}\n  (no existing facts)", header);
    }
    let fact_lines = facts
        .iter()
        .map(|f| {
            let age_days = DateTime::parse_from_rfc3339(&f.created_at)
                .map(|created| (now - created.with_timezone(&Utc)).num_days().max(0))
                .unwrap_or(0);
            format!(
                "  - id={} kind={} confidence={:.2} status={} age_days={} text=\"{}\"",
                f.id, f.fact_kind, f.confidence, f.status, age_days, f.fact_text
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!("{}\n{}", header, fact_lines)
}

fn parse_ops(raw: &str) -> Result<Vec<ReconcileOp>, serde_json::Error> {
    let cleaned = strip_code_fences(raw);
    serde_json::from_str(&cleaned)
}
