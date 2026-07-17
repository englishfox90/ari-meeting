//! Hybrid retrieval: FTS5 BM25 (lexical) ⊕ vector cosine (semantic), fused with reciprocal
//! rank fusion and weighted by meeting recency. Returns `TranscriptSearchResult` — the exact
//! shape the legacy keyword search returned — so it drops straight into `api_answer_meetings_locally`
//! with the entire bounding/prompt/source-safety shell untouched.
//!
//! This is the fix for the "results miss the mark" failure: relevance is scored across ALL
//! indexed chunks (semantic + lexical) BEFORE any cap, and recency is a smooth weight rather
//! than the old hard `LIMIT 64 ORDER BY created_at DESC` that evicted older-but-relevant
//! meetings before they were ever scored.

use std::collections::{HashMap, HashSet};

use chrono::Utc;
use sqlx::SqlitePool;

use crate::api::TranscriptSearchResult;
use crate::database::models::RecallChunk;
use crate::database::repositories::{
    meeting::MeetingsRepository, recall_index::RecallIndexRepository,
    summary::SummaryProcessesRepository, transcript::TranscriptsRepository,
};
use crate::recall::embedding;

const FTS_CANDIDATES: i64 = 48;
const VECTOR_CANDIDATES: usize = 48;
/// Reciprocal-rank-fusion constant. Larger => flatter contribution across ranks.
const RRF_K: f64 = 60.0;
/// Chunks handed downstream (multiple per meeting enrich a meeting's excerpt; the api layer
/// then dedups per meeting and caps meeting count).
const MAX_HITS: usize = 60;
/// Recency half-life: a chunk's fused score is halved every ~45 days of meeting age.
const RECENCY_HALF_LIFE_DAYS: f64 = 45.0;
/// Never suppress an old meeting below this fraction — relevance still wins for stale info.
const RECENCY_FLOOR: f64 = 0.35;

const STOP_WORDS: &[&str] = &[
    "about", "from", "have", "meetings", "meeting", "that", "this", "what", "when", "where",
    "which", "with", "would", "were", "did", "does", "our", "was", "and", "how", "who", "the",
    "for", "are", "you", "your",
];

fn fts_terms(query: &str) -> Vec<String> {
    let mut terms: Vec<String> = query
        .split(|c: char| !c.is_alphanumeric())
        .map(|t| t.to_lowercase())
        .filter(|t| t.chars().count() >= 3 && !STOP_WORDS.contains(&t.as_str()))
        .collect();
    terms.sort();
    terms.dedup();
    terms.truncate(16);
    terms
}

/// OR the terms, each double-quoted so FTS5 MATCH treats them as literals (no operator
/// injection from user text).
fn build_match_query(terms: &[String]) -> Option<String> {
    if terms.is_empty() {
        return None;
    }
    let quoted: Vec<String> = terms
        .iter()
        .map(|t| format!("\"{}\"", t.replace('"', "")))
        .collect();
    Some(quoted.join(" OR "))
}

fn add_rrf(ranks: &mut HashMap<String, f64>, chunk_id: &str, rank: usize) {
    *ranks.entry(chunk_id.to_string()).or_insert(0.0) += 1.0 / (RRF_K + rank as f64 + 1.0);
}

/// Global (cross-meeting) retrieval for Ask Meetings. Falls back to the legacy keyword
/// search when nothing is indexed yet (first-run backfill) or when both arms return empty,
/// so Ask never regresses to worse-than-before behavior.
pub async fn global_search(
    pool: &SqlitePool,
    question: &str,
) -> Result<Vec<TranscriptSearchResult>, String> {
    global_search_inner(pool, question, None).await
}

/// Series-scoped (F9) retrieval for Ask Meetings. Identical hybrid ranking to
/// `global_search`, but every arm's hits are filtered to chunks whose `meeting_id` is in
/// `allowed_meeting_ids` (the series' member meetings) BEFORE fusion, so relevance is scored
/// only within the series. Returns the same `TranscriptSearchResult` shape, so the api layer's
/// bounding / prompt / source-safety shell is untouched.
pub async fn global_search_scoped(
    pool: &SqlitePool,
    question: &str,
    allowed_meeting_ids: &HashSet<String>,
) -> Result<Vec<TranscriptSearchResult>, String> {
    global_search_inner(pool, question, Some(allowed_meeting_ids)).await
}

/// Shared implementation for `global_search` (no filter) and `global_search_scoped`
/// (member-meeting filter). When `allowed` is `Some`, a chunk is admitted to fusion only if
/// its meeting is in the set — applied at each arm's `add_rrf` site.
async fn global_search_inner(
    pool: &SqlitePool,
    question: &str,
    allowed: Option<&HashSet<String>>,
) -> Result<Vec<TranscriptSearchResult>, String> {
    // Scoped search cannot fall back to the keyword LIKE search (which is cross-meeting and
    // cannot honor the member filter). An empty allowed set means the series has no members,
    // so there is nothing to retrieve.
    if let Some(allowed) = allowed {
        if allowed.is_empty() {
            return Ok(Vec::new());
        }
    }
    let is_allowed = |meeting_id: &str| allowed.map(|set| set.contains(meeting_id)).unwrap_or(true);

    let indexed = RecallIndexRepository::count_chunks(pool)
        .await
        .map_err(|e| e.to_string())?;
    if indexed == 0 {
        // Only the unscoped (global) path may fall back to the legacy keyword search; the
        // scoped path returns empty rather than leak chunks outside the series.
        if allowed.is_some() {
            return Ok(Vec::new());
        }
        return TranscriptsRepository::search_transcripts(pool, question)
            .await
            .map_err(|e| e.to_string());
    }

    let mut ranks: HashMap<String, f64> = HashMap::new();
    let mut chunk_meeting: HashMap<String, String> = HashMap::new();

    // --- Lexical arm (FTS5 BM25) ---
    let terms = fts_terms(question);
    if let Some(match_query) = build_match_query(&terms) {
        match RecallIndexRepository::fts_search(pool, &match_query, FTS_CANDIDATES).await {
            Ok(hits) => {
                for (rank, (chunk_id, meeting_id, _bm25)) in hits.into_iter().enumerate() {
                    if !is_allowed(&meeting_id) {
                        continue;
                    }
                    add_rrf(&mut ranks, &chunk_id, rank);
                    chunk_meeting.insert(chunk_id, meeting_id);
                }
            }
            Err(error) => log::warn!("recall: FTS search failed: {error}"),
        }
    }

    // --- Semantic arm (vector cosine), best-effort ---
    if let Ok(query_vector) = embedding::embed_query(pool, question).await {
        match RecallIndexRepository::all_embeddings(pool).await {
            Ok(rows) => {
                let mut scored: Vec<(String, String, f32)> = rows
                    .into_iter()
                    .filter_map(|(chunk_id, meeting_id, bytes, _dim)| {
                        if !is_allowed(&meeting_id) {
                            return None;
                        }
                        let vector = embedding::unpack_f32(&bytes);
                        if vector.len() != query_vector.len() {
                            return None;
                        }
                        Some((chunk_id, meeting_id, embedding::cosine(&query_vector, &vector)))
                    })
                    .collect();
                scored.sort_by(|a, b| {
                    b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal)
                });
                for (rank, (chunk_id, meeting_id, _sim)) in
                    scored.into_iter().take(VECTOR_CANDIDATES).enumerate()
                {
                    add_rrf(&mut ranks, &chunk_id, rank);
                    chunk_meeting.entry(chunk_id).or_insert(meeting_id);
                }
            }
            Err(error) => log::warn!("recall: could not load embeddings: {error}"),
        }
    }

    if ranks.is_empty() {
        // Scoped: no member chunk matched; return empty (no cross-meeting keyword fallback).
        if allowed.is_some() {
            return Ok(Vec::new());
        }
        return TranscriptsRepository::search_transcripts(pool, question)
            .await
            .map_err(|e| e.to_string());
    }

    // --- Recency weighting (per meeting) ---
    let meetings = MeetingsRepository::get_meetings(pool)
        .await
        .map_err(|e| e.to_string())?;
    let now = Utc::now();
    // meeting_id -> (title, date_rfc3339, recency_weight)
    let mut meeting_meta: HashMap<String, (String, String, f64)> = HashMap::new();
    for meeting in &meetings {
        let age_days =
            (now - meeting.created_at.0).num_seconds().max(0) as f64 / 86_400.0;
        let weight = RECENCY_FLOOR.max(0.5f64.powf(age_days / RECENCY_HALF_LIFE_DAYS));
        meeting_meta.insert(
            meeting.id.clone(),
            (meeting.title.clone(), meeting.created_at.0.to_rfc3339(), weight),
        );
    }

    let mut scored_chunks: Vec<(String, f64)> = ranks
        .into_iter()
        .map(|(chunk_id, score)| {
            let weight = chunk_meeting
                .get(&chunk_id)
                .and_then(|mid| meeting_meta.get(mid))
                .map(|meta| meta.2)
                .unwrap_or(1.0);
            (chunk_id, score * weight)
        })
        .collect();
    scored_chunks.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    scored_chunks.truncate(MAX_HITS);

    // Fetch the chunk rows we kept.
    let ids: Vec<String> = scored_chunks.iter().map(|(id, _)| id.clone()).collect();
    let chunk_rows = RecallIndexRepository::get_chunks_by_ids(pool, &ids)
        .await
        .map_err(|e| e.to_string())?;
    let chunk_by_id: HashMap<String, RecallChunk> =
        chunk_rows.into_iter().map(|c| (c.id.clone(), c)).collect();

    // Fetch summaries once per distinct meeting in the (bounded) result set.
    let mut summary_by_meeting: HashMap<String, Option<String>> = HashMap::new();
    for (chunk_id, _) in &scored_chunks {
        if let Some(chunk) = chunk_by_id.get(chunk_id) {
            if !summary_by_meeting.contains_key(&chunk.meeting_id) {
                let summary = SummaryProcessesRepository::get_summary_data(pool, &chunk.meeting_id)
                    .await
                    .ok()
                    .flatten()
                    .and_then(|s| s.result);
                summary_by_meeting.insert(chunk.meeting_id.clone(), summary);
            }
        }
    }

    // Map to TranscriptSearchResult in score order. `id` = meeting_id (repeated across a
    // meeting's chunks); the api layer's build_global_recall_sources dedups + caps meetings.
    let mut results = Vec::new();
    for (chunk_id, _) in scored_chunks {
        let Some(chunk) = chunk_by_id.get(&chunk_id) else {
            continue;
        };
        let (title, date) = meeting_meta
            .get(&chunk.meeting_id)
            .map(|meta| (meta.0.clone(), meta.1.clone()))
            .unwrap_or_else(|| ("Untitled meeting".to_string(), String::new()));
        results.push(TranscriptSearchResult {
            id: chunk.meeting_id.clone(),
            title,
            match_context: chunk.chunk_text.clone(),
            timestamp: chunk
                .timestamp_label
                .clone()
                .unwrap_or_else(|| "not available".to_string()),
            meeting_date: (!date.is_empty()).then_some(date),
            summary: summary_by_meeting
                .get(&chunk.meeting_id)
                .cloned()
                .flatten(),
        });
    }
    Ok(results)
}
