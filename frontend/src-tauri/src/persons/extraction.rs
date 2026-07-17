// Person Profiles (F2) fact-extraction engine. Runs off the STT hot path — triggered by the
// frontend after a summary completes (see the frozen F2 contract §5/§2 "Trigger is
// FRONTEND-orchestrated"). Reuses the SAME LLM provider dispatch as `summary::llm_client`
// (no new client). Must degrade gracefully: unconfigured provider, empty transcript, no
// participants, or a malformed model response all return `ExtractionResult{created:0,..}`
// with an honest message — never panic, never hard-error the caller.
//
// Deviation from the literal §5 signature: the contract's `extract_facts_for_meeting(pool,
// meeting_id)` omits an app handle, but the BuiltInAI provider (see
// `summary/llm_client.rs::generate_summary`) requires `app_data_dir` to locate its sidecar
// model. We thread an `Option<&Path>` for that one purpose, computed by the command from
// the injected `AppHandle` — the command's own argument list to the frontend is unchanged
// (`meeting_id` only; `AppHandle` is a Tauri-injected extractor, not a wire arg).

use std::path::Path;

use anyhow::Result;
use sqlx::SqlitePool;

use crate::database::repositories::person::{
    PersonRepository, PersonRow, ProfileFactRepository, ProfileFactSourceRepository,
};
use crate::database::repositories::setting::SettingsRepository;
use crate::database::repositories::transcript::TranscriptsRepository;
use crate::persons::models::ExtractionResult;
use crate::summary::llm_client::{generate_summary, LLMProvider};

const MAX_TRANSCRIPT_CHARS: usize = 48_000; // mirror the local-recall context bound

#[derive(serde::Deserialize, Debug)]
struct ExtractedFact {
    person_email: Option<String>,
    person_name: Option<String>,
    #[serde(default = "default_fact_kind")]
    fact_kind: String,
    #[serde(default = "default_source_kind")]
    source_kind: String,
    #[serde(default)]
    confidence: f64,
    fact_text: String,
    #[serde(default)]
    evidence: Option<String>,
}

fn default_fact_kind() -> String {
    "other".to_string()
}

fn default_source_kind() -> String {
    "attributed".to_string()
}

/// Entry point. Never returns `Err` for "nothing useful happened" cases (missing
/// participants/transcript/provider/parse failure) — those are honest `created: 0` results.
/// `Err` is reserved for genuine DB-access failures.
pub async fn extract_facts_for_meeting(
    pool: &SqlitePool,
    app_data_dir: Option<&Path>,
    meeting_id: &str,
) -> Result<ExtractionResult> {
    let empty_result = |message: &str| ExtractionResult {
        created: 0,
        meeting_id: meeting_id.to_string(),
        message: message.to_string(),
    };

    let participants = PersonRepository::list_participants(pool, meeting_id).await?;
    if participants.is_empty() {
        return Ok(empty_result(
            "No linked participants for this meeting — nothing to extract facts about.",
        ));
    }

    // Prefer a speaker-labeled transcript ("Sarah: …") so the LLM's person_name/person_email
    // tags are grounded in the REAL names present, making `resolve_person` match accurately.
    // Degrades to the prior unlabeled behavior when no speaker resolves to a name.
    let transcript_text =
        match crate::diarization::labeling::build_labeled_transcript_text(pool, meeting_id).await? {
            Some(labeled) => labeled,
            None => load_transcript_text(pool, meeting_id).await?,
        };
    if transcript_text.trim().is_empty() {
        return Ok(empty_result("No transcript text found for this meeting."));
    }

    let Some(config) = SettingsRepository::get_model_config(pool).await? else {
        return Ok(empty_result(
            "No summarization provider configured — skipping fact extraction.",
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
                    "No API key configured for {} — skipping fact extraction.",
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
                    "Custom OpenAI provider selected but not configured — skipping fact extraction.",
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

    let participant_list = participants
        .iter()
        .map(|p| format!("- {} <{}>", p.display_name, p.email.as_deref().unwrap_or("no email")))
        .collect::<Vec<_>>()
        .join("\n");

    let bounded_transcript: String = transcript_text.chars().take(MAX_TRANSCRIPT_CHARS).collect();

    let system_prompt = "You extract concrete facts people state about themselves or that \
        others attribute to them in a meeting transcript. Output STRICT JSON only — a JSON \
        array, no prose, no markdown code fences. Only include facts about the listed \
        participants. Never speculate; if nothing concrete is present, output an empty array \
        `[]`.";

    let user_prompt = format!(
        "Known participants:\n{}\n\nTranscript:\n{}\n\nOutput a JSON array where each item is:\n\
        {{\"person_email\": string|null, \"person_name\": string, \"fact_kind\": \"goal\"|\"interest\"|\"project\"|\"role_signal\"|\"other\", \
        \"source_kind\": \"self_reported\"|\"attributed\", \"confidence\": number (0.0-1.0), \"fact_text\": string, \"evidence\": string}}",
        participant_list, bounded_transcript
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

    let items = match parse_extracted_facts(&raw_response) {
        Ok(items) => items,
        Err(e) => {
            return Ok(empty_result(&format!(
                "Could not parse model response as JSON: {}",
                e
            )))
        }
    };

    if items.is_empty() {
        return Ok(empty_result("No concrete facts found in this meeting."));
    }

    let mut created = 0i64;
    for item in items {
        let Some(person) = resolve_person(&participants, item.person_email.as_deref(), item.person_name.as_deref())
        else {
            continue;
        };

        let confidence = item.confidence.clamp(0.0, 1.0);
        let new_row = ProfileFactRepository::insert(
            pool,
            &person.id,
            &item.fact_text,
            &item.fact_kind,
            Some(meeting_id),
            item.evidence.as_deref(),
            &item.source_kind,
            confidence,
            "pending",
        )
        .await?;
        // Record this meeting as the fact's origin source (F2 multi-source facts).
        ProfileFactSourceRepository::add_source(
            pool,
            &new_row.id,
            Some(meeting_id),
            item.evidence.as_deref(),
            &item.source_kind,
            "origin",
            confidence,
        )
        .await?;
        created += 1;
    }

    let message = if created > 0 {
        format!("Extracted {} pending fact(s) for review.", created)
    } else {
        "No facts could be matched to a known participant.".to_string()
    };

    Ok(ExtractionResult {
        created,
        meeting_id: meeting_id.to_string(),
        message,
    })
}

/// `pub(crate)`: also used by `persons::reconciliation` to resolve the same
/// person_email/person_name tags the reconciliation prompt asks for.
pub(crate) fn resolve_person<'a>(
    participants: &'a [PersonRow],
    email: Option<&str>,
    name: Option<&str>,
) -> Option<&'a PersonRow> {
    if let Some(email) = email {
        if let Some(found) = participants
            .iter()
            .find(|p| p.email.as_deref().map(|e| e.eq_ignore_ascii_case(email)).unwrap_or(false))
        {
            return Some(found);
        }
    }
    if let Some(name) = name {
        return participants
            .iter()
            .find(|p| p.display_name.eq_ignore_ascii_case(name));
    }
    None
}

fn parse_extracted_facts(raw: &str) -> Result<Vec<ExtractedFact>, serde_json::Error> {
    let cleaned = strip_code_fences(raw);
    serde_json::from_str(&cleaned)
}

/// Strip Markdown code fences (```json ... ``` or ``` ... ```) some providers wrap JSON in.
/// `pub(crate)`: also used by `persons::reconciliation`.
pub(crate) fn strip_code_fences(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Some(rest) = trimmed.strip_prefix("```") {
        let rest = rest.strip_prefix("json").unwrap_or(rest);
        let rest = rest.trim_start_matches('\n');
        if let Some(end) = rest.rfind("```") {
            return rest[..end].trim().to_string();
        }
        return rest.trim().to_string();
    }
    trimmed.to_string()
}

/// Reuses `TranscriptsRepository` (no inline sqlx here) to load and concatenate a
/// meeting's transcript segments in chronological order.
/// `pub(crate)`: also used by `persons::reconciliation` as the unlabeled-transcript fallback.
pub(crate) async fn load_transcript_text(pool: &SqlitePool, meeting_id: &str) -> Result<String> {
    let rows = TranscriptsRepository::get_meeting_transcripts_for_recall(pool, meeting_id).await?;
    let mut seen_summary_only = true;
    let mut text = String::new();
    for row in rows {
        if !row.match_context.trim().is_empty() {
            seen_summary_only = false;
            if !text.is_empty() {
                text.push(' ');
            }
            text.push_str(&row.match_context);
        }
    }
    if seen_summary_only {
        return Ok(String::new());
    }
    Ok(text)
}
