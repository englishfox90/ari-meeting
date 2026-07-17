//! Build and refresh the recall index. Indexing is idempotent (a re-run over unchanged
//! transcript text with the same embedder is a no-op) and best-effort about embeddings:
//! if the local embedder is unavailable, the meeting is indexed lexical-only and will be
//! upgraded to embeddings on a later run once the model is present.

use std::sync::atomic::{AtomicBool, Ordering};

use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::database::repositories::{
    meeting::MeetingsRepository,
    recall_index::{RecallChunkInput, RecallIndexRepository},
};
use crate::recall::{chunker, embedding};

/// Guards against overlapping full backfills (startup + first-query auto-trigger + the
/// explicit reindex command can all race). Per-meeting `index_meeting` is unguarded and
/// cheap.
static REINDEX_RUNNING: AtomicBool = AtomicBool::new(false);

fn fnv1a_hex(text: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in text.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// Index one meeting. Logs its own errors and never panics — safe to `spawn` fire-and-forget.
pub async fn index_meeting(pool: &SqlitePool, meeting_id: &str) {
    if let Err(error) = index_meeting_inner(pool, meeting_id).await {
        log::warn!("recall: failed to index meeting {meeting_id}: {error}");
    }
}

async fn index_meeting_inner(pool: &SqlitePool, meeting_id: &str) -> Result<(), String> {
    let (transcripts, _total) =
        MeetingsRepository::get_meeting_transcripts_paginated(pool, meeting_id, i64::MAX, 0)
            .await
            .map_err(|e| e.to_string())?;

    let joined: String = transcripts
        .iter()
        .map(|t| t.transcript.trim())
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if joined.trim().is_empty() {
        // No transcript text (e.g. summary-only meeting) — clear any stale index.
        let _ = RecallIndexRepository::delete_meeting(pool, meeting_id).await;
        return Ok(());
    }

    let content_hash = fnv1a_hex(&joined);
    let want_model = embedding::current_model_tag(pool).await;

    // Idempotency: skip only when unchanged AND already fully embedded with this model.
    // A prior lexical-only index (embedded_count < chunk_count) is intentionally re-run so
    // embeddings fill in once the model becomes available.
    if let Ok(Some(state)) = RecallIndexRepository::get_index_state(pool, meeting_id).await {
        if state.content_hash == content_hash
            && state.chunk_count > 0
            && state.embedded_count == state.chunk_count
            && state.embedding_model.as_deref() == Some(want_model.as_str())
        {
            return Ok(());
        }
    }

    let drafts = chunker::chunk_transcripts(&transcripts);
    if drafts.is_empty() {
        let _ = RecallIndexRepository::delete_meeting(pool, meeting_id).await;
        return Ok(());
    }

    // Embed all chunks in one batch with the configured backend. Best-effort: any failure
    // (embedder unavailable, or a mismatched count) falls back to lexical-only for the whole
    // meeting — never a partial or fabricated set of vectors.
    let texts: Vec<String> = drafts.iter().map(|d| d.text.clone()).collect();
    let embeddings: Option<Vec<Vec<f32>>> = match embedding::embed_documents(pool, &texts).await {
        Ok(vectors) if vectors.len() == texts.len() => Some(vectors),
        Ok(_) => {
            log::warn!(
                "recall: embedder returned a mismatched count; indexing {meeting_id} lexical-only"
            );
            None
        }
        Err(error) => {
            log::warn!(
                "recall: embedder unavailable ({error}); indexing meeting {meeting_id} lexical-only"
            );
            None
        }
    };

    let mut inputs = Vec::with_capacity(drafts.len());
    for (index, draft) in drafts.iter().enumerate() {
        let (embedding_bytes, dim) = match &embeddings {
            Some(vectors) => (
                Some(embedding::pack_f32(&vectors[index])),
                Some(vectors[index].len() as i64),
            ),
            None => (None, None),
        };
        inputs.push(RecallChunkInput {
            id: Uuid::new_v4().to_string(),
            chunk_index: draft.chunk_index,
            chunk_text: draft.text.clone(),
            start_time: draft.start_time,
            end_time: draft.end_time,
            timestamp_label: draft.timestamp_label.clone(),
            embedding_model: dim.map(|_| want_model.clone()),
            dim,
            embedding: embedding_bytes,
            token_estimate: Some(draft.token_estimate),
        });
    }

    let model_used = embeddings.as_ref().map(|_| want_model.as_str());
    RecallIndexRepository::replace_meeting_chunks(
        pool,
        meeting_id,
        &inputs,
        &content_hash,
        model_used,
        &Utc::now().to_rfc3339(),
    )
    .await
    .map_err(|e| e.to_string())?;

    Ok(())
}

/// True if a backfill was started by this call; false if one is already running.
pub fn try_begin_reindex() -> bool {
    !REINDEX_RUNNING.swap(true, Ordering::SeqCst)
}

pub fn end_reindex() {
    REINDEX_RUNNING.store(false, Ordering::SeqCst);
}

/// Read-only check of whether a backfill is in progress (does not acquire the guard).
pub fn is_reindex_running() -> bool {
    REINDEX_RUNNING.load(Ordering::SeqCst)
}

/// Backfill every meeting that is missing or stale. Self-guarded against overlap: returns
/// `Ok(0)` immediately if a backfill is already running. `force` re-indexes even unchanged
/// meetings (e.g. to embed a vault that was previously indexed lexical-only).
pub async fn reindex_all(pool: &SqlitePool, force: bool) -> Result<usize, String> {
    if !try_begin_reindex() {
        return Ok(0);
    }
    let result = reindex_all_inner(pool, force).await;
    end_reindex();
    result
}

async fn reindex_all_inner(pool: &SqlitePool, force: bool) -> Result<usize, String> {
    let meetings = MeetingsRepository::get_meetings(pool)
        .await
        .map_err(|e| e.to_string())?;
    let mut indexed = 0usize;
    for meeting in meetings {
        if force {
            let _ = RecallIndexRepository::delete_meeting(pool, &meeting.id).await;
        }
        index_meeting(pool, &meeting.id).await;
        indexed += 1;
    }
    Ok(indexed)
}
