//! Agentic "Ask Meetings" path (Claude cloud only).
//!
//! Today `api_answer_meetings_locally` does a single retrieval pass then one LLM call. When
//! the configured provider is Claude (cloud, with an API key), this module instead runs an
//! Anthropic tool-use loop: the model can call TOOLS to search meetings, read a meeting,
//! look up a person, list recent meetings, and check the calendar across several turns before
//! answering. This makes "any question about my meetings" answerable.
//!
//! Additive-only: this is a NEW module, wired in behind a single gated branch in the existing
//! command. On ANY error the caller falls through to the unchanged single-shot path.
//!
//! Bounds (hard): ≤ 8 tool-call iterations; accumulated sources capped at 24; transcript
//! excerpts ≤ 8000 chars; each tool result JSON bounded. After the iteration cap, one final
//! no-tools call forces an answer.
//!
//! Every source the tools surface is assigned a stable 1-based index; the model is told to
//! cite inline as `[S<n>]` (matching the frontend citation chips + `citations::
//! verify_source_citations`). Sources are deduped by `meeting_id + timestamp`.

use std::path::PathBuf;

use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::api::LocalRecallSource;
use crate::database::repositories::{
    calendar::CalendarRepository, meeting::MeetingsRepository, person, person::PersonRepository,
    summary::SummaryProcessesRepository,
};

const MAX_ITERATIONS: usize = 8;
const MAX_SOURCES: usize = 24;
const MAX_TRANSCRIPT_CHARS: usize = 8_000;
const MAX_TOOL_RESULT_CHARS: usize = 16_000;
const MAX_TOKENS: u32 = 4_096;
const ANTHROPIC_URL: &str = "https://api.anthropic.com/v1/messages";

const SYSTEM_PROMPT: &str = "You are Ari's meeting assistant. You answer ONLY from the user's \
saved local meetings (transcripts, summaries, the people in them, and their linked calendar \
events). You have tools to look things up — use them before answering:\n\
- search_meetings: find meetings relevant to the question (semantic + keyword).\n\
- get_meeting: read one meeting's transcript, summary, and who was present.\n\
- list_recent_meetings: list the most recent meetings (already newest-first).\n\
- lookup_person: look up a known person's role/org and recorded facts.\n\
- get_calendar_events: check calendar events in a recent/upcoming window.\n\n\
Guidance: gather evidence with the tools before answering. Prefer recent meetings when the \
question is time-sensitive. Cite every claim inline using the bracketed source index the tools \
return — e.g. [S1][S2], each individually and never as a range like [S1-S4] — matching the `s` \
field on each result; never cite a number a tool did not return. Cite only the few sources that \
most directly support a point, not every result. If the tools do not surface an answer, say so plainly. Never invent facts, \
meetings, people, or citations. When you have enough to answer, stop calling tools and reply.";

/// Run the Anthropic tool-use loop and return `(answer, sources)`. On any failure returns
/// `Err`, so the caller can fall through to the existing single-shot path.
///
/// `app_data_dir` is accepted for call-shape parity with the single-shot path; the Claude
/// cloud path has no use for it. `endpoint` is the (loopback) Ollama endpoint forwarded to
/// the embedding-backed `search_meetings` tool — NOT the Anthropic endpoint.
pub async fn answer_agentic(
    pool: &SqlitePool,
    _app_data_dir: Option<&PathBuf>,
    model: &str,
    api_key: &str,
    question: &str,
    _meeting_id: Option<&str>,
    history: &str,
    // Embedding endpoint is resolved from settings inside the recall search now; kept for
    // call-shape parity with the single-shot path.
    _endpoint: Option<&str>,
) -> Result<(String, Vec<LocalRecallSource>), String> {
    if api_key.trim().is_empty() {
        return Err("no Claude API key configured".to_string());
    }

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(300))
        .build()
        .map_err(|e| format!("could not build HTTP client: {e}"))?;

    let mut sources: Vec<LocalRecallSource> = Vec::new();

    // Seed the conversation with the (optional) prior-conversation string + the question.
    let first_user = if history.trim().is_empty() {
        format!("Question: {question}")
    } else {
        format!(
            "Earlier conversation (context only; the meeting tools remain authoritative):\n{history}\n\nQuestion: {question}"
        )
    };
    let mut messages: Vec<Value> = vec![json!({ "role": "user", "content": first_user })];

    let tools = tool_definitions();

    for _ in 0..MAX_ITERATIONS {
        let request = build_request(model, &messages, Some(&tools));
        let response = call_anthropic(&client, api_key, &request).await?;

        let content = response
            .get("content")
            .cloned()
            .unwrap_or_else(|| json!([]));
        let stop_reason = response
            .get("stop_reason")
            .and_then(|v| v.as_str())
            .unwrap_or("end_turn")
            .to_string();

        // Echo the assistant turn back verbatim (tool_use blocks must be preserved).
        messages.push(json!({ "role": "assistant", "content": content }));

        let tool_uses = collect_tool_uses(&content);
        if stop_reason != "tool_use" || tool_uses.is_empty() {
            let answer = extract_text(&content);
            if answer.trim().is_empty() {
                return Err("Claude returned an empty answer".to_string());
            }
            return Ok((answer, sources));
        }

        // Execute each requested tool; return all results in a single user message.
        let mut tool_results: Vec<Value> = Vec::with_capacity(tool_uses.len());
        for (id, name, input) in tool_uses {
            let result = execute_tool(pool, &name, &input, &mut sources).await;
            tool_results.push(json!({
                "type": "tool_result",
                "tool_use_id": id,
                "content": truncate_chars(&result, MAX_TOOL_RESULT_CHARS),
            }));
        }
        messages.push(json!({ "role": "user", "content": tool_results }));
    }

    // Iteration cap reached while still calling tools — force a final answer with no tools.
    let request = build_request(model, &messages, None);
    let response = call_anthropic(&client, api_key, &request).await?;
    let content = response
        .get("content")
        .cloned()
        .unwrap_or_else(|| json!([]));
    let answer = extract_text(&content);
    if answer.trim().is_empty() {
        return Err("Claude returned an empty final answer".to_string());
    }
    Ok((answer, sources))
}

// ===== Anthropic request/response plumbing =====

fn build_request(model: &str, messages: &[Value], tools: Option<&[Value]>) -> Value {
    let mut body = json!({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "system": SYSTEM_PROMPT,
        "messages": messages,
    });
    if let Some(tools) = tools {
        body["tools"] = json!(tools);
    }
    body
}

async fn call_anthropic(
    client: &reqwest::Client,
    api_key: &str,
    request: &Value,
) -> Result<Value, String> {
    let response = client
        .post(ANTHROPIC_URL)
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(request)
        .send()
        .await
        .map_err(|e| format!("Claude request failed: {e}"))?;

    if !response.status().is_success() {
        let body = response
            .text()
            .await
            .unwrap_or_else(|_| "unknown error".to_string());
        return Err(format!("Claude API error: {body}"));
    }

    response
        .json::<Value>()
        .await
        .map_err(|e| format!("could not parse Claude response: {e}"))
}

/// Extract `(id, name, input)` for every `tool_use` block in a response content array.
fn collect_tool_uses(content: &Value) -> Vec<(String, String, Value)> {
    let Some(blocks) = content.as_array() else {
        return Vec::new();
    };
    blocks
        .iter()
        .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("tool_use"))
        .filter_map(|b| {
            let id = b.get("id").and_then(|v| v.as_str())?.to_string();
            let name = b.get("name").and_then(|v| v.as_str())?.to_string();
            let input = b.get("input").cloned().unwrap_or_else(|| json!({}));
            Some((id, name, input))
        })
        .collect()
}

/// Concatenate the text of every `text` block in a response content array.
fn extract_text(content: &Value) -> String {
    content
        .as_array()
        .map(|blocks| {
            blocks
                .iter()
                .filter(|b| b.get("type").and_then(|t| t.as_str()) == Some("text"))
                .filter_map(|b| b.get("text").and_then(|t| t.as_str()))
                .collect::<Vec<_>>()
                .join("")
        })
        .unwrap_or_default()
}

// ===== Tool definitions =====

fn tool_definitions() -> Vec<Value> {
    vec![
        json!({
            "name": "search_meetings",
            "description": "Search the user's saved meetings for content relevant to a query (semantic + keyword). Returns matching meetings with an excerpt and a source index `s` you can cite as [S<s>].",
            "input_schema": {
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "What to search for" },
                    "limit": { "type": "integer", "description": "Max meetings to return (default 8)" }
                },
                "required": ["query"]
            }
        }),
        json!({
            "name": "get_meeting",
            "description": "Read one saved meeting by id: title, date, who was present, its summary, and a transcript excerpt. Registers a citable source index `s`.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "meeting_id": { "type": "string", "description": "The meeting id" }
                },
                "required": ["meeting_id"]
            }
        }),
        json!({
            "name": "list_recent_meetings",
            "description": "List the user's most recent saved meetings (newest first) with id, title, and date. Use to orient before searching or reading.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "limit": { "type": "integer", "description": "Max meetings to list (default 20)" }
                }
            }
        }),
        json!({
            "name": "lookup_person",
            "description": "Look up a known person by (partial) name: role, organization, and recorded facts. Best-effort; returns nothing if the person is unknown. Never fabricate.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "Full or partial display name" }
                },
                "required": ["name"]
            }
        }),
        json!({
            "name": "get_calendar_events",
            "description": "List the user's calendar events within a window around now, with title, start time, attendees, and notes.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "days_past": { "type": "integer", "description": "How many days back from now (default 7)" },
                    "days_future": { "type": "integer", "description": "How many days forward from now (default 7)" }
                }
            }
        }),
    ]
}

// ===== Tool execution =====

async fn execute_tool(
    pool: &SqlitePool,
    name: &str,
    input: &Value,
    sources: &mut Vec<LocalRecallSource>,
) -> String {
    let result = match name {
        "search_meetings" => tool_search_meetings(pool, input, sources).await,
        "get_meeting" => tool_get_meeting(pool, input, sources).await,
        "list_recent_meetings" => tool_list_recent_meetings(pool, input).await,
        "lookup_person" => tool_lookup_person(pool, input).await,
        "get_calendar_events" => tool_get_calendar_events(pool, input).await,
        other => Err(format!("unknown tool: {other}")),
    };
    match result {
        Ok(value) => value.to_string(),
        Err(error) => json!({ "error": error }).to_string(),
    }
}

async fn tool_search_meetings(
    pool: &SqlitePool,
    input: &Value,
    sources: &mut Vec<LocalRecallSource>,
) -> Result<Value, String> {
    let query = str_arg(input, "query").ok_or_else(|| "query is required".to_string())?;
    let limit = int_arg(input, "limit", 8).clamp(1, 20) as usize;

    let hits = crate::recall::search::global_search(pool, &query).await?;
    let mut out = Vec::new();
    for hit in hits.into_iter().take(limit) {
        let source = LocalRecallSource {
            meeting_id: hit.id.clone(),
            title: hit.title.clone(),
            match_context: hit.match_context.clone(),
            timestamp: hit.timestamp.clone(),
            meeting_date: hit.meeting_date.clone(),
            summary: hit.summary.clone(),
            speakers: Vec::new(),
        };
        if let Some(index) = register_source(sources, source) {
            out.push(json!({
                "s": index,
                "meeting_id": hit.id,
                "title": hit.title,
                "date": hit.meeting_date,
                "excerpt": truncate_chars(&hit.match_context, 1_200),
            }));
        }
    }
    if out.is_empty() {
        return Ok(json!({ "results": [], "note": "no saved meetings matched" }));
    }
    Ok(json!({ "results": out }))
}

async fn tool_get_meeting(
    pool: &SqlitePool,
    input: &Value,
    sources: &mut Vec<LocalRecallSource>,
) -> Result<Value, String> {
    let meeting_id = str_arg(input, "meeting_id")
        .ok_or_else(|| "meeting_id is required".to_string())?;

    // Title + date from the meetings list.
    let meetings = MeetingsRepository::get_meetings(pool)
        .await
        .map_err(|e| e.to_string())?;
    let meeting = meetings
        .into_iter()
        .find(|m| m.id == meeting_id)
        .ok_or_else(|| format!("no meeting with id {meeting_id}"))?;
    let date = meeting.created_at.0.to_rfc3339();

    // Transcript (bounded).
    let (transcripts, _total) =
        MeetingsRepository::get_meeting_transcripts_paginated(pool, &meeting_id, 100_000, 0)
            .await
            .map_err(|e| e.to_string())?;
    let full_text: String = transcripts
        .iter()
        .map(|t| t.transcript.trim())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    let excerpt = truncate_chars(&full_text, MAX_TRANSCRIPT_CHARS);

    // Summary (raw JSON string, bounded).
    let summary = SummaryProcessesRepository::get_summary_data(pool, &meeting_id)
        .await
        .ok()
        .flatten()
        .and_then(|s| s.result);

    // People present (deduped names), best-effort.
    let people: Vec<String> = match crate::diarization::labeling::resolve_meeting_speaker_labels(
        pool, &meeting_id,
    )
    .await
    {
        Ok(pairs) => {
            let mut names: Vec<String> = Vec::new();
            for (_tid, name) in pairs {
                if !names.contains(&name) {
                    names.push(name);
                }
            }
            names
        }
        Err(_) => Vec::new(),
    };

    // Register the meeting itself as a citable source.
    let source = LocalRecallSource {
        meeting_id: meeting.id.clone(),
        title: meeting.title.clone(),
        match_context: excerpt.clone(),
        timestamp: "full meeting".to_string(),
        meeting_date: Some(date.clone()),
        summary: summary.clone(),
        speakers: people.clone(),
    };
    let index = register_source(sources, source);

    Ok(json!({
        "s": index,
        "meeting_id": meeting.id,
        "title": meeting.title,
        "date": date,
        "people": people,
        "summary": summary.as_deref().map(|s| truncate_chars(s, 4_000)),
        "transcript_excerpt": excerpt,
    }))
}

async fn tool_list_recent_meetings(pool: &SqlitePool, input: &Value) -> Result<Value, String> {
    let limit = int_arg(input, "limit", 20).clamp(1, 100) as usize;
    let meetings = MeetingsRepository::get_meetings(pool)
        .await
        .map_err(|e| e.to_string())?;
    let out: Vec<Value> = meetings
        .into_iter()
        .take(limit)
        .map(|m| {
            json!({
                "meeting_id": m.id,
                "title": m.title,
                "date": m.created_at.0.to_rfc3339(),
            })
        })
        .collect();
    Ok(json!({ "meetings": out }))
}

async fn tool_lookup_person(pool: &SqlitePool, input: &Value) -> Result<Value, String> {
    let name = str_arg(input, "name").ok_or_else(|| "name is required".to_string())?;
    let needle = name.to_lowercase();

    let owner = PersonRepository::get_owner(pool).await.ok().flatten();
    let all = PersonRepository::list(pool)
        .await
        .map_err(|e| e.to_string())?;

    // Prefer the owner when the query matches them; otherwise a case-insensitive substring
    // match on display_name.
    let matched = all.into_iter().find(|p| {
        p.display_name.to_lowercase().contains(&needle)
            || owner
                .as_ref()
                .is_some_and(|o| o.id == p.id && o.display_name.to_lowercase().contains(&needle))
    });

    let Some(found) = matched else {
        return Ok(json!({ "found": false, "note": "no known person matched that name" }));
    };

    let facts: Vec<String> = person::top_active_facts(pool, &found.id, 5)
        .await
        .map(|rows| rows.into_iter().map(|f| f.fact_text).collect())
        .unwrap_or_default();

    Ok(json!({
        "found": true,
        "name": found.display_name,
        "role": found.role,
        "organization": found.organization,
        "is_owner": found.is_owner != 0,
        "facts": facts,
    }))
}

async fn tool_get_calendar_events(pool: &SqlitePool, input: &Value) -> Result<Value, String> {
    let days_past = int_arg(input, "days_past", 7).clamp(0, 365);
    let days_future = int_arg(input, "days_future", 7).clamp(0, 365);

    let now = chrono::Utc::now();
    let start = now - chrono::Duration::days(days_past);
    let end = now + chrono::Duration::days(days_future);

    let events = CalendarRepository::list_events_in_range(pool, start, end)
        .await
        .map_err(|e| e.to_string())?;

    let out: Vec<Value> = events
        .into_iter()
        .take(50)
        .map(|e| {
            let attendees: Vec<String> = e
                .attendees
                .as_deref()
                .and_then(|s| {
                    serde_json::from_str::<Vec<crate::calendar::models::Attendee>>(s).ok()
                })
                .unwrap_or_default()
                .into_iter()
                .filter_map(|a| a.name.or(a.email))
                .collect();
            json!({
                "title": e.title,
                "start_time": e.start_time,
                "attendees": attendees,
                "notes": e.notes.as_deref().map(|n| truncate_chars(n, 500)),
            })
        })
        .collect();

    Ok(json!({ "events": out }))
}

// ===== Helpers =====

/// Add a source, deduping by `meeting_id + timestamp`. Returns the 1-based index to cite,
/// or `None` if the accumulator is at the hard cap and the source is new.
fn register_source(sources: &mut Vec<LocalRecallSource>, source: LocalRecallSource) -> Option<usize> {
    if let Some(pos) = sources
        .iter()
        .position(|s| s.meeting_id == source.meeting_id && s.timestamp == source.timestamp)
    {
        return Some(pos + 1);
    }
    if sources.len() >= MAX_SOURCES {
        return None;
    }
    sources.push(source);
    Some(sources.len())
}

fn str_arg(input: &Value, key: &str) -> Option<String> {
    input
        .get(key)
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn int_arg(input: &Value, key: &str, default: i64) -> i64 {
    input.get(key).and_then(|v| v.as_i64()).unwrap_or(default)
}

/// Truncate to at most `max` chars (char-safe), appending an ellipsis marker when cut.
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_string_and_int_args_with_defaults() {
        let input = json!({ "query": "  budget review  ", "limit": 3 });
        assert_eq!(str_arg(&input, "query").as_deref(), Some("budget review"));
        assert_eq!(int_arg(&input, "limit", 8), 3);
        // Missing / blank → default / None.
        assert_eq!(int_arg(&input, "missing", 8), 8);
        assert_eq!(str_arg(&json!({ "query": "   " }), "query"), None);
    }

    #[test]
    fn register_source_dedups_and_caps() {
        let mut sources: Vec<LocalRecallSource> = Vec::new();
        let mk = |mid: &str, ts: &str| LocalRecallSource {
            meeting_id: mid.to_string(),
            title: "t".to_string(),
            match_context: "c".to_string(),
            timestamp: ts.to_string(),
            meeting_date: None,
            summary: None,
            speakers: Vec::new(),
        };
        assert_eq!(register_source(&mut sources, mk("m1", "0:00")), Some(1));
        assert_eq!(register_source(&mut sources, mk("m2", "0:00")), Some(2));
        // Same meeting_id + timestamp → reuse index 1, no growth.
        assert_eq!(register_source(&mut sources, mk("m1", "0:00")), Some(1));
        assert_eq!(sources.len(), 2);

        // Fill to the cap, then a new one is rejected.
        for i in 0..MAX_SOURCES {
            let _ = register_source(&mut sources, mk("bulk", &format!("t{i}")));
        }
        assert_eq!(sources.len(), MAX_SOURCES);
        assert_eq!(register_source(&mut sources, mk("new", "z")), None);
    }

    #[test]
    fn collect_tool_uses_and_extract_text() {
        let content = json!([
            { "type": "text", "text": "Let me check." },
            { "type": "tool_use", "id": "tu_1", "name": "search_meetings", "input": { "query": "x" } },
            { "type": "text", "text": " Done." }
        ]);
        assert_eq!(extract_text(&content), "Let me check. Done.");
        let uses = collect_tool_uses(&content);
        assert_eq!(uses.len(), 1);
        assert_eq!(uses[0].0, "tu_1");
        assert_eq!(uses[0].1, "search_meetings");
    }

    #[test]
    fn truncate_is_char_safe() {
        assert_eq!(truncate_chars("hello", 10), "hello");
        assert_eq!(truncate_chars("hello", 3), "he…");
    }
}
