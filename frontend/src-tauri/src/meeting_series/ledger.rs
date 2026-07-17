//! Series ledger reduce (F9, Phase B2).
//!
//! Each meeting series keeps ONE living "ledger" — a compact running memory that is
//! (a) UPDATED here after each meeting's summary is generated, and (b) INJECTED into the
//! next meeting's summary prompt (see `persons::commands::summary_context_for_meeting`).
//!
//! This module owns the REDUCE step: it folds the just-finished meeting's summary markdown
//! into the rolling `series_ledger` for its series via a single bounded LLM call, then
//! persists the merged result. It is intentionally self-contained and best-effort — the
//! caller logs any error; a failed ledger update must never affect the summary flow.
//!
//! No-Fake-State: if the meeting is not in a series, or has no finished summary, we return
//! `Ok(())` without touching the ledger (we never fabricate content or wipe an existing
//! ledger).

use anyhow::{anyhow, Context, Result};
use sqlx::SqlitePool;
use tracing::{info, warn};

use crate::engine::Engine;

use crate::database::repositories::meeting::MeetingsRepository;
use crate::database::repositories::meeting_series::MeetingSeriesRepository;
use crate::database::repositories::setting::SettingsRepository;
use crate::database::repositories::summary::SummaryProcessesRepository;
use crate::summary::llm_client::{generate_summary, LLMProvider};

/// Soft cap for the reduced ledger. Enforced by *instruction* to the model (it is injected
/// into every future summary prompt, so it must stay terse). We don't hard-truncate the
/// model output — truncating markdown mid-section would corrupt it.
const LEDGER_WORD_CAP: usize = 500;

/// Rebuild the rolling series ledger for the series that `meeting_id` belongs to.
///
/// Steps:
/// 1. Resolve the series (no series → `Ok(())`).
/// 2. Load the just-finished summary markdown (missing/empty → `Ok(())`, don't wipe).
/// 3. Load the current ledger (may be absent → treated as "no prior context").
/// 4. Run a bounded REDUCE prompt through the SAME provider/model the summary service uses.
/// 5. Upsert the merged ledger.
pub async fn rebuild_ledger_for_meeting(
    engine: &Engine,
    pool: &SqlitePool,
    meeting_id: &str,
) -> Result<()> {
    // 1. Which series does this meeting belong to?
    let series = match MeetingSeriesRepository::series_for_meeting(pool, meeting_id)
        .await
        .context("failed to resolve series for meeting")?
    {
        Some(s) => s,
        None => {
            // Not in a series — nothing to fold. This is the common case for one-off meetings.
            return Ok(());
        }
    };

    // 2. Load the finished summary markdown for this meeting.
    let new_summary_markdown = match load_summary_markdown(pool, meeting_id).await? {
        Some(md) if !md.trim().is_empty() => md,
        _ => {
            // No usable summary yet — don't wipe an existing ledger, just skip.
            info!(
                "📒 Series ledger: no finished summary for meeting {}; skipping ledger update.",
                meeting_id
            );
            return Ok(());
        }
    };

    // Meeting-attributed citations (F9): rewrite this meeting's `@ref(<TS>)` tokens into
    // `@mref(m<N>@<TS>)` BEFORE folding, where N is this meeting's 1-based position in the
    // series' chronological member ordering (exactly `list_members` order). `member_count`
    // bounds the valid N range for the post-reduce validation below.
    let members = MeetingSeriesRepository::list_members(pool, &series.id)
        .await
        .context("failed to list series members for citation indexing")?;
    let member_count = members.len();
    let member_index_1based = members
        .iter()
        .position(|m| m.meeting_id == meeting_id)
        .map(|i| i + 1)
        // If this meeting isn't yet a listed member (shouldn't happen — series_for_meeting
        // resolved it), skip attribution rather than emit a wrong index.
        .unwrap_or(0);
    let new_summary_markdown = if member_index_1based >= 1 {
        super::ledger_citations::qualify_refs(&new_summary_markdown, member_index_1based)
    } else {
        new_summary_markdown
    };

    // 3. Current ledger markdown (None → empty "no prior context").
    let current_ledger = MeetingSeriesRepository::get_ledger(pool, &series.id)
        .await
        .context("failed to load current series ledger")?
        .and_then(|l| l.ledger_markdown)
        .unwrap_or_default();

    // Meeting title + date for provenance inside the reduce prompt.
    let (meeting_title, meeting_date) = match MeetingsRepository::get_meeting_metadata(pool, meeting_id)
        .await
        .context("failed to load meeting metadata")?
    {
        Some(m) => (m.title, m.created_at.0.format("%Y-%m-%d").to_string()),
        None => ("Untitled meeting".to_string(), String::new()),
    };

    // 4. Run the reduce through the configured LLM provider.
    let new_markdown = reduce_ledger(
        engine,
        pool,
        &series.title,
        Some(&current_ledger),
        &new_summary_markdown,
        &meeting_title,
        &meeting_date,
    )
    .await?;

    if new_markdown.is_empty() {
        // Model returned nothing usable — keep the prior ledger rather than blanking it.
        warn!(
            "📒 Series ledger: reduce produced empty output for series {}; keeping prior ledger.",
            series.id
        );
        return Ok(());
    }

    // No-Fake-State: drop any `@mref` the reduce mangled/invented to an out-of-range meeting
    // index, degrading it to plain time text so no dead badge ever reaches the series page.
    let new_markdown = super::ledger_citations::validate_qualified_refs(&new_markdown, member_count);

    // 5. Persist the merged ledger (structured_json unused for now).
    let now = chrono::Utc::now().to_rfc3339();
    MeetingSeriesRepository::upsert_ledger(
        pool,
        &series.id,
        Some(&new_markdown),
        None,
        Some(meeting_id),
        &now,
    )
    .await
    .context("failed to upsert series ledger")?;

    info!(
        "📒 Series ledger updated for series '{}' ({}) from meeting {} ({} chars)",
        series.title,
        series.id,
        meeting_id,
        new_markdown.len()
    );
    Ok(())
}

/// Rebuild the ENTIRE ledger for a series from scratch, folding every member meeting's
/// existing finished summary in chronological order.
///
/// This is the on-demand counterpart to the incremental per-meeting reduce: it lets a
/// hand-curated series — whose members were summarized BEFORE they were linked — build a
/// ledger without re-generating any summary. Rebuilding from an EMPTY ledger (rather than
/// patching the current one) guarantees no meeting is double-counted.
///
/// No-Fake-State: if NO member has a usable summary, we return `Ok(None)` and DO NOT touch
/// any existing ledger — we never fabricate or blank one.
///
/// Returns `Ok(Some(markdown))` with the rebuilt ledger, or `Ok(None)` when there was
/// nothing to build from.
pub async fn rebuild_ledger_for_series(
    engine: &Engine,
    pool: &SqlitePool,
    series_id: &str,
) -> Result<Option<String>> {
    let series = MeetingSeriesRepository::get_series(pool, series_id)
        .await
        .context("failed to load series")?
        .ok_or_else(|| anyhow!("series {} not found", series_id))?;

    // Members come back ordered by occurrence_time ASC — i.e. chronological.
    let members = MeetingSeriesRepository::list_members(pool, series_id)
        .await
        .context("failed to list series members")?;

    // Accumulate from an empty ledger, folding each summarized meeting in order.
    let mut accumulated: Option<String> = None;
    let mut last_folded_meeting: Option<String> = None;
    let mut folded_count: usize = 0;

    let member_count = members.len();

    for (idx, member) in members.iter().enumerate() {
        // 1-based position in the chronological member list — this is the `N` that maps to
        // `SeriesDetail.members[N-1]` on the read side. It comes from the FULL member
        // ordering (skipped, summary-less members still consume an index), so a badge always
        // resolves to the correct meeting.
        let member_index_1based = idx + 1;

        let summary_markdown = match load_summary_markdown(pool, &member.meeting_id).await? {
            Some(md) if !md.trim().is_empty() => md,
            // Skip members without a usable summary — don't stall the rebuild.
            _ => continue,
        };

        // Meeting-attributed citations (F9): qualify `@ref(<TS>)` → `@mref(m<N>@<TS>)` before
        // folding this member's summary into the reduce.
        let summary_markdown =
            super::ledger_citations::qualify_refs(&summary_markdown, member_index_1based);

        let (meeting_title, meeting_date) =
            match MeetingsRepository::get_meeting_metadata(pool, &member.meeting_id)
                .await
                .context("failed to load meeting metadata")?
            {
                Some(m) => (m.title, m.created_at.0.format("%Y-%m-%d").to_string()),
                None => ("Untitled meeting".to_string(), String::new()),
            };

        let next = reduce_ledger(
            engine,
            pool,
            &series.title,
            accumulated.as_deref(),
            &summary_markdown,
            &meeting_title,
            &meeting_date,
        )
        .await
        .with_context(|| {
            format!("reduce failed while folding meeting {}", member.meeting_id)
        })?;

        if next.is_empty() {
            // Model produced nothing for this fold — keep what we have and move on rather
            // than blanking the accumulated ledger.
            warn!(
                "📒 Series ledger rebuild: reduce produced empty output for meeting {}; skipping it.",
                member.meeting_id
            );
            continue;
        }

        accumulated = Some(next);
        last_folded_meeting = Some(member.meeting_id.clone());
        folded_count += 1;
    }

    match accumulated {
        Some(final_ledger) if folded_count > 0 => {
            // No-Fake-State: drop any out-of-range `@mref` the reduce invented/mangled.
            let final_ledger =
                super::ledger_citations::validate_qualified_refs(&final_ledger, member_count);
            let now = chrono::Utc::now().to_rfc3339();
            MeetingSeriesRepository::upsert_ledger(
                pool,
                series_id,
                Some(&final_ledger),
                None,
                last_folded_meeting.as_deref(),
                &now,
            )
            .await
            .context("failed to upsert rebuilt series ledger")?;

            info!(
                "📒 Series ledger rebuilt for series '{}' ({}) from {} summarized meeting(s), {} chars",
                series.title,
                series.id,
                folded_count,
                final_ledger.len()
            );
            Ok(Some(final_ledger))
        }
        _ => {
            // No member had a usable summary — leave any existing ledger untouched.
            info!(
                "📒 Series ledger rebuild: no summarized meetings in series '{}' ({}); leaving any existing ledger untouched.",
                series.title, series.id
            );
            Ok(None)
        }
    }
}

/// Fold ONE meeting's summary markdown into the running ledger via a single bounded LLM
/// reduce, returning the merged ledger markdown (trimmed; empty string if the model
/// produced nothing usable). Pure with respect to the DB — it never persists; the caller
/// owns the upsert. `current_ledger` = `None`/empty means "no prior context".
#[allow(clippy::too_many_arguments)]
pub async fn reduce_ledger(
    engine: &Engine,
    pool: &SqlitePool,
    series_title: &str,
    current_ledger: Option<&str>,
    summary_markdown: &str,
    meeting_title: &str,
    meeting_date: &str,
) -> Result<String> {
    let (system_prompt, user_prompt) = build_reduce_prompt(
        series_title,
        current_ledger.unwrap_or(""),
        summary_markdown,
        meeting_title,
        meeting_date,
    );

    let out = run_reduce(engine, pool, &system_prompt, &user_prompt)
        .await
        .context("series ledger reduce LLM call failed")?;

    Ok(out.trim().to_string())
}

/// Pull the display `markdown` out of a completed summary's `result` JSON blob.
/// Mirrors the shape written by `summary::service::build_summary_result_json`.
async fn load_summary_markdown(pool: &SqlitePool, meeting_id: &str) -> Result<Option<String>> {
    let process = SummaryProcessesRepository::get_summary_data(pool, meeting_id)
        .await
        .context("failed to load summary process row")?;

    let raw = match process.and_then(|p| p.result) {
        Some(r) => r,
        None => return Ok(None),
    };

    let value: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            warn!(
                "📒 Series ledger: summary result for meeting {} is not valid JSON ({}); skipping.",
                meeting_id, e
            );
            return Ok(None);
        }
    };

    Ok(value
        .get("markdown")
        .and_then(|m| m.as_str())
        .map(|s| s.to_string()))
}

/// Build the (system, user) prompt pair for the reduce. The instructions pin EXACTLY the
/// four sections the read-side injection expects, enforce merge-not-append semantics, and
/// cap the total length so the ledger stays cheap to inject into future summary prompts.
fn build_reduce_prompt(
    series_title: &str,
    current_ledger: &str,
    new_summary_markdown: &str,
    meeting_title: &str,
    meeting_date: &str,
) -> (String, String) {
    let system_prompt = format!(
        "You maintain a compact, living \"series ledger\" — a running memory shared across all \
meetings in a recurring series. Your job is to MERGE the newest meeting's summary into the \
existing ledger and output an updated ledger.\n\
\n\
Output ONLY valid markdown with EXACTLY these four sections, in this order:\n\
\n\
## Open action items\n\
## Decisions\n\
## Recurring themes\n\
## Per-person threads\n\
\n\
Rules:\n\
- MERGE, do not just append. Reconcile the new meeting against the existing ledger.\n\
- Open action items: carry each forward with its owner and a status marker — (new), \
(still open), (done), or (dropped). REMOVE items that are clearly completed, resolved, or \
superseded by the new meeting; do not let the list grow without bound.\n\
- Decisions: keep durable decisions that hold across the series.\n\
- Recurring themes: topics that keep coming up across meetings.\n\
- Per-person threads: for each NAMED participant, their ongoing goals, commitments, and \
trajectory over time.\n\
- NEVER invent facts. Only use information present in the existing ledger or the new summary.\n\
- Preserve any @mref(...) citation tokens EXACTLY and verbatim — never alter, split, merge, \
or invent them; attach the relevant one to the action item or decision it supports.\n\
- If a section has nothing, write exactly: _None yet._\n\
- Keep the WHOLE ledger under {cap} words. Be terse. Drop stale or low-signal items to stay \
within budget. This ledger is injected into future meeting prompts, so brevity matters.\n\
- Output the markdown ledger only — no preamble, no commentary, no code fences.",
        cap = LEDGER_WORD_CAP
    );

    let ledger_block = if current_ledger.trim().is_empty() {
        "(No prior ledger — this is the first entry for the series. Build it from the new meeting \
summary alone.)"
            .to_string()
    } else {
        current_ledger.trim().to_string()
    };

    let date_suffix = if meeting_date.trim().is_empty() {
        String::new()
    } else {
        format!(" ({})", meeting_date)
    };

    let user_prompt = format!(
        "Series: {series}\n\
\n\
=== EXISTING LEDGER ===\n\
{ledger}\n\
\n\
=== NEW MEETING SUMMARY: {title}{date} ===\n\
{summary}\n\
\n\
Produce the updated series ledger now.",
        series = series_title,
        ledger = ledger_block,
        title = meeting_title,
        date = date_suffix,
        summary = new_summary_markdown.trim(),
    );

    (system_prompt, user_prompt)
}

/// Resolve the same provider/model/key/endpoint the summary service uses (from the single
/// `settings` row) and run one LLM call for the reduce. No cancellation token — the reduce
/// is a short, fire-and-forget background step.
async fn run_reduce(
    engine: &Engine,
    pool: &SqlitePool,
    system_prompt: &str,
    user_prompt: &str,
) -> Result<String> {
    let setting = SettingsRepository::get_model_config(pool)
        .await
        .context("failed to load model config")?
        .ok_or_else(|| anyhow!("no model configuration found; cannot run ledger reduce"))?;

    let provider = LLMProvider::from_str(&setting.provider)
        .map_err(|e| anyhow!("unsupported summary provider '{}': {}", setting.provider, e))?;

    // Provider-specific config, mirroring summary::service::process_transcript_background.
    let mut model_name = setting.model.clone();
    let mut ollama_endpoint: Option<String> = None;
    let mut custom_openai_endpoint: Option<String> = None;
    let mut max_tokens: Option<u32> = None;
    let mut temperature: Option<f32> = None;
    let mut top_p: Option<f32> = None;
    let mut api_key = String::new();

    match provider {
        LLMProvider::Ollama => {
            ollama_endpoint = setting.ollama_endpoint.clone();
        }
        LLMProvider::CustomOpenAI => {
            let cfg = SettingsRepository::get_custom_openai_config(pool)
                .await
                .context("failed to load custom OpenAI config")?
                .ok_or_else(|| anyhow!("custom-openai provider selected but no config found"))?;
            custom_openai_endpoint = Some(cfg.endpoint);
            if model_name.trim().is_empty() {
                model_name = cfg.model;
            }
            api_key = cfg.api_key.unwrap_or_default();
            max_tokens = cfg.max_tokens.map(|t| t as u32);
            temperature = cfg.temperature;
            top_p = cfg.top_p;
        }
        // These providers don't need an API key from the settings columns.
        LLMProvider::BuiltInAI
        | LLMProvider::ClaudeCLI
        | LLMProvider::AppleFoundation => {}
        // Cloud providers need a key from the settings row.
        _ => {
            api_key = SettingsRepository::get_api_key(pool, &setting.provider)
                .await
                .context("failed to load API key")?
                .filter(|k| !k.is_empty())
                .ok_or_else(|| anyhow!("API key not found for provider '{}'", setting.provider))?;
        }
    }

    let app_data_dir = Some(engine.paths().app_data.clone());

    let client = reqwest::Client::new();
    generate_summary(
        &client,
        &provider,
        &model_name,
        &api_key,
        system_prompt,
        user_prompt,
        ollama_endpoint.as_deref(),
        custom_openai_endpoint.as_deref(),
        max_tokens,
        temperature,
        top_p,
        app_data_dir.as_ref(),
        None,
    )
    .await
    .map_err(|e| anyhow!(e))
}
