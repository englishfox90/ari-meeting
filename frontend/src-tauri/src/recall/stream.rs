//! Streaming variant of `api_answer_meetings_locally` (F7). Same retrieval, gating,
//! prompt, and citation-verification invariants as the single-shot path — they are
//! reused from `crate::api` (the security-relevant gates and the anti-hallucination
//! prompt are single-sourced, not copied). The only new behavior is transport: this
//! command returns nothing directly and instead emits the answer incrementally as
//! Tauri events, then a terminal event carrying the citation-reconciled full answer
//! plus the (separately-computed, never model-invented) sources.
//!
//! Events (payloads are camelCase; all carry `streamId` so the UI can match):
//! - `ask-stream-delta` — `{ streamId, delta }` incremental text
//! - `ask-stream-done`  — `{ streamId, answer, sources }` authoritative final result
//!
//! Errors surface through the command's `Result::Err` (the frontend `invoke` rejects);
//! there is no separate error event.

use std::sync::Arc;

use serde::Serialize;

use crate::api::{
    build_global_recall_sources, build_local_recall_context, build_local_recall_history,
    build_meeting_recall_sources, is_loopback_ollama_endpoint, is_unsupported_recall_question,
    recall_system_prompt, LocalRecallSource, LocalRecallTurn,
};
use crate::database::repositories::{
    meeting_series::MeetingSeriesRepository, setting::SettingsRepository,
    transcript::TranscriptsRepository,
};
use crate::engine::events::EventSink;
use crate::engine::Engine;
use crate::summary::llm_client::LLMProvider;
use crate::summary::llm_stream::generate_summary_stream;

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct StreamDelta {
    stream_id: String,
    delta: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct StreamDone {
    stream_id: String,
    answer: String,
    sources: Vec<LocalRecallSource>,
}

/// Streaming counterpart of `api_answer_meetings_locally`. See module docs.
async fn api_answer_meetings_locally_stream_impl(
    engine: &Engine,
    stream_id: String,
    question: String,
    meeting_id: Option<String>,
    series_id: Option<String>,
    history: Option<Vec<LocalRecallTurn>>,
) -> Result<(), String> {
    let question = question.trim();
    if question.is_empty() {
        return Err("Enter a question about your saved meetings.".to_string());
    }
    if question.chars().count() > 1_000 {
        return Err("Questions must be 1,000 characters or fewer.".to_string());
    }
    if is_unsupported_recall_question(question) {
        return Err("Ask Meetings can answer only from saved local Ari Meeting transcripts. It cannot access calendars, email, accounts, internet search, or files outside Ari Meeting.".to_string());
    }
    let history = build_local_recall_history(history.unwrap_or_default())?;

    // Owned sink: `&dyn EventSink` borrowed from `&Engine` can't be threaded through the
    // `emit_delta`/`emit_done` helpers (they're called from inside the `generate_summary_stream`
    // delta callback too), so clone the sink once via `Engine::event_sink` and reuse it.
    let sink = engine.event_sink();

    let db = engine.db().await?;
    let pool = db.pool();
    let config = SettingsRepository::get_model_config(pool)
        .await
        .map_err(|error| format!("Could not read the local model configuration: {error}"))?
        .ok_or_else(|| "Configure Built-in AI or Ollama before asking meetings.".to_string())?;
    let provider = LLMProvider::from_str(&config.provider)
        .map_err(|_| "Configure a summary model in Settings before asking meetings.".to_string())?;
    if provider == LLMProvider::Ollama
        && !is_loopback_ollama_endpoint(config.ollama_endpoint.as_deref())
    {
        return Err("Ask Meetings only permits an Ollama server on this device. Use localhost in Settings to continue.".to_string());
    }
    if config.model.trim().is_empty() {
        return Err("Choose a summary model in Settings before asking meetings.".to_string());
    }
    let api_key = SettingsRepository::get_api_key(pool, &config.provider)
        .await
        .ok()
        .flatten()
        .unwrap_or_default();

    // Agentic path (Claude cloud, global scope only): the multi-turn tool-use loop is
    // not incrementally streamed. Run it to completion, then emit the finished answer
    // as one delta so the UI behaves identically. Fall through to streaming on error.
    if provider == LLMProvider::Claude
        && !api_key.trim().is_empty()
        && meeting_id.is_none()
        && series_id.is_none()
    {
        let app_data_dir = &engine.paths().app_data;
        match crate::recall::agent::answer_agentic(
            pool,
            Some(app_data_dir),
            &config.model,
            &api_key,
            question,
            meeting_id.as_deref(),
            &history,
            config.ollama_endpoint.as_deref(),
        )
        .await
        {
            Ok((answer, sources)) => {
                let answer = crate::recall::citations::verify_source_citations(&answer, sources.len());
                emit_delta(&sink, &stream_id, &answer);
                emit_done(&sink, &stream_id, answer, sources);
                return Ok(());
            }
            Err(e) => log::warn!("recall(stream): agentic path failed, falling back: {e}"),
        }
    }

    let is_meeting_scoped = meeting_id.is_some();
    // Series scope (F9): only when NOT meeting-scoped. Precedence: meeting > series > global.
    let is_series_scoped = !is_meeting_scoped && series_id.is_some();

    let series_ledger_markdown = if is_series_scoped {
        MeetingSeriesRepository::get_ledger(pool, series_id.as_deref().unwrap())
            .await
            .ok()
            .flatten()
            .and_then(|l| l.ledger_markdown)
            .filter(|m| !m.trim().is_empty())
    } else {
        None
    };

    let matches = if let Some(meeting_id) = meeting_id.as_deref() {
        TranscriptsRepository::get_meeting_transcripts_for_recall(pool, meeting_id)
            .await
            .map_err(|error| format!("Could not read local meeting transcripts: {error}"))
    } else if let Some(series_id) = series_id.as_deref() {
        let members = MeetingSeriesRepository::list_members(pool, series_id)
            .await
            .map_err(|error| format!("Could not read this series' meetings: {error}"))?;
        let allowed: std::collections::HashSet<String> =
            members.into_iter().map(|m| m.meeting_id).collect();
        crate::recall::search::global_search_scoped(pool, question, &allowed)
            .await
            .map_err(|error| format!("Could not search this series: {error}"))
    } else {
        crate::recall::search::global_search(pool, question)
            .await
            .map_err(|error| format!("Could not search local meetings: {error}"))
    }?;
    if matches.is_empty() {
        return Err(if is_meeting_scoped {
            "This meeting has no saved transcript or summary yet. Record, import, recover, or retranscribe it before asking the local assistant.".to_string()
        } else if is_series_scoped {
            "No saved local transcript in this series matched that question.".to_string()
        } else {
            "No saved local transcript matched that question.".to_string()
        });
    }

    let mut sources = if is_meeting_scoped {
        build_meeting_recall_sources(matches)
    } else {
        build_global_recall_sources(matches)
    };
    crate::recall::context::attach_people(pool, &mut sources).await;
    let people_block =
        crate::recall::context::people_context_block(pool, &sources, meeting_id.as_deref()).await;

    let context = build_local_recall_context(&sources);
    let system_prompt = recall_system_prompt(is_meeting_scoped);
    let prior_conversation = (!history.is_empty())
        .then(|| format!("Earlier conversation (context only; meeting sources remain authoritative):\n{history}\n\n"))
        .unwrap_or_default();
    let people_section = (!people_block.is_empty())
        .then(|| format!("{people_block}\n\n"))
        .unwrap_or_default();
    let series_section = series_ledger_markdown
        .as_deref()
        .map(|ledger| {
            format!("### Series ledger (running context for this series)\n{ledger}\n\n")
        })
        .unwrap_or_default();
    let user_prompt = format!(
        "{prior_conversation}{people_section}{series_section}Question: {question}\n\nAuthoritative local meeting sources:\n{context}"
    );

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|error| format!("Could not start the local model request: {error}"))?;
    let app_data_dir = &engine.paths().app_data;

    // Stream tokens straight to the webview as they arrive.
    let answer = generate_summary_stream(
        &client,
        &provider,
        &config.model,
        &api_key,
        &system_prompt,
        &user_prompt,
        config.ollama_endpoint.as_deref(),
        None,
        None,
        None,
        None,
        Some(app_data_dir),
        None,
        |delta| emit_delta(&sink, &stream_id, delta),
    )
    .await
    .map_err(|error| format!("The local model could not answer from your saved meetings: {error}"))?;

    // Reconcile citations on the COMPLETE answer (same invariant as single-shot):
    // drop invented [S<n>] and verify/keep @ref timestamps by scope.
    let answer = crate::recall::citations::verify_source_citations(&answer, sources.len());
    let answer = if is_meeting_scoped {
        let max_seconds = sources
            .iter()
            .filter_map(|s| crate::recall::citations::parse_timestamp_label(&s.timestamp))
            .max();
        crate::recall::citations::filter_ref_timestamps(&answer, max_seconds)
    } else {
        crate::recall::citations::filter_ref_timestamps(&answer, None)
    };

    emit_done(&sink, &stream_id, answer, sources);
    Ok(())
}

#[tauri::command]
pub async fn api_answer_meetings_locally_stream(
    engine: tauri::State<'_, Arc<Engine>>,
    stream_id: String,
    question: String,
    meeting_id: Option<String>,
    series_id: Option<String>,
    history: Option<Vec<LocalRecallTurn>>,
) -> Result<(), String> {
    api_answer_meetings_locally_stream_impl(
        &engine, stream_id, question, meeting_id, series_id, history,
    )
    .await
}

fn emit_delta(sink: &Arc<dyn EventSink>, stream_id: &str, delta: &str) {
    if delta.is_empty() {
        return;
    }
    sink.emit(
        "ask-stream-delta",
        StreamDelta {
            stream_id: stream_id.to_string(),
            delta: delta.to_string(),
        },
    );
}

fn emit_done(
    sink: &Arc<dyn EventSink>,
    stream_id: &str,
    answer: String,
    sources: Vec<LocalRecallSource>,
) {
    sink.emit(
        "ask-stream-done",
        StreamDone {
            stream_id: stream_id.to_string(),
            answer,
            sources,
        },
    );
}
