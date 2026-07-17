use sqlx::{QueryBuilder, Sqlite, SqlitePool};

use crate::database::models::{RecallChunk, RecallIndexState};

/// A chunk staged for insertion. `embedding` is packed little-endian f32 bytes.
pub struct RecallChunkInput {
    pub id: String,
    pub chunk_index: i64,
    pub chunk_text: String,
    pub start_time: Option<f64>,
    pub end_time: Option<f64>,
    pub timestamp_label: Option<String>,
    pub embedding: Option<Vec<u8>>,
    pub embedding_model: Option<String>,
    pub dim: Option<i64>,
    pub token_estimate: Option<i64>,
}

pub struct RecallIndexRepository;

impl RecallIndexRepository {
    /// Replace all indexed chunks for a meeting in a single transaction, keeping the
    /// FTS5 mirror and the index-state row in lockstep. Inserts are batched to keep the
    /// write-lock window short (WAL single-writer).
    pub async fn replace_meeting_chunks(
        pool: &SqlitePool,
        meeting_id: &str,
        chunks: &[RecallChunkInput],
        content_hash: &str,
        embedding_model: Option<&str>,
        now_rfc3339: &str,
    ) -> Result<(), sqlx::Error> {
        let mut tx = pool.begin().await?;

        sqlx::query("DELETE FROM recall_chunks WHERE meeting_id = ?")
            .bind(meeting_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM recall_fts WHERE meeting_id = ?")
            .bind(meeting_id)
            .execute(&mut *tx)
            .await?;

        let embedded_count = chunks.iter().filter(|c| c.embedding.is_some()).count() as i64;

        for batch in chunks.chunks(200) {
            let mut chunk_insert = QueryBuilder::<Sqlite>::new(
                "INSERT INTO recall_chunks \
                 (id, meeting_id, chunk_index, chunk_text, start_time, end_time, \
                  timestamp_label, embedding, embedding_model, dim, token_estimate, created_at) ",
            );
            chunk_insert.push_values(batch, |mut row, chunk| {
                row.push_bind(&chunk.id)
                    .push_bind(meeting_id)
                    .push_bind(chunk.chunk_index)
                    .push_bind(&chunk.chunk_text)
                    .push_bind(chunk.start_time)
                    .push_bind(chunk.end_time)
                    .push_bind(&chunk.timestamp_label)
                    .push_bind(&chunk.embedding)
                    .push_bind(&chunk.embedding_model)
                    .push_bind(chunk.dim)
                    .push_bind(chunk.token_estimate)
                    .push_bind(now_rfc3339);
            });
            chunk_insert.build().execute(&mut *tx).await?;

            let mut fts_insert = QueryBuilder::<Sqlite>::new(
                "INSERT INTO recall_fts (chunk_text, chunk_id, meeting_id) ",
            );
            fts_insert.push_values(batch, |mut row, chunk| {
                row.push_bind(&chunk.chunk_text)
                    .push_bind(&chunk.id)
                    .push_bind(meeting_id);
            });
            fts_insert.build().execute(&mut *tx).await?;
        }

        sqlx::query(
            "INSERT INTO recall_index_state \
             (meeting_id, content_hash, chunk_count, embedding_model, embedded_count, indexed_at) \
             VALUES (?, ?, ?, ?, ?, ?) \
             ON CONFLICT(meeting_id) DO UPDATE SET \
                content_hash = excluded.content_hash, \
                chunk_count = excluded.chunk_count, \
                embedding_model = excluded.embedding_model, \
                embedded_count = excluded.embedded_count, \
                indexed_at = excluded.indexed_at",
        )
        .bind(meeting_id)
        .bind(content_hash)
        .bind(chunks.len() as i64)
        .bind(embedding_model)
        .bind(embedded_count)
        .bind(now_rfc3339)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(())
    }

    /// Remove all index rows for a meeting (chunks, FTS mirror, state).
    pub async fn delete_meeting(pool: &SqlitePool, meeting_id: &str) -> Result<(), sqlx::Error> {
        let mut tx = pool.begin().await?;
        sqlx::query("DELETE FROM recall_chunks WHERE meeting_id = ?")
            .bind(meeting_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM recall_fts WHERE meeting_id = ?")
            .bind(meeting_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM recall_index_state WHERE meeting_id = ?")
            .bind(meeting_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn get_index_state(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<Option<RecallIndexState>, sqlx::Error> {
        sqlx::query_as::<_, RecallIndexState>(
            "SELECT meeting_id, content_hash, chunk_count, embedding_model, embedded_count, indexed_at \
             FROM recall_index_state WHERE meeting_id = ?",
        )
        .bind(meeting_id)
        .fetch_optional(pool)
        .await
    }

    pub async fn count_chunks(pool: &SqlitePool) -> Result<i64, sqlx::Error> {
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM recall_chunks")
            .fetch_one(pool)
            .await
    }

    /// (indexed_meetings, chunk_count, embedded_chunk_count) for the status command.
    pub async fn index_summary(pool: &SqlitePool) -> Result<(i64, i64, i64), sqlx::Error> {
        let meetings: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM recall_index_state")
                .fetch_one(pool)
                .await?;
        let chunks: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM recall_chunks")
            .fetch_one(pool)
            .await?;
        let embedded: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM recall_chunks WHERE embedding IS NOT NULL")
                .fetch_one(pool)
                .await?;
        Ok((meetings, chunks, embedded))
    }

    /// BM25 lexical candidates. Returns (chunk_id, meeting_id, bm25) ordered best-first
    /// (SQLite bm25 is ascending — smaller is a better match).
    pub async fn fts_search(
        pool: &SqlitePool,
        match_query: &str,
        limit: i64,
    ) -> Result<Vec<(String, String, f64)>, sqlx::Error> {
        sqlx::query_as::<_, (String, String, f64)>(
            "SELECT chunk_id, meeting_id, bm25(recall_fts) AS score \
             FROM recall_fts WHERE recall_fts MATCH ? \
             ORDER BY score ASC LIMIT ?",
        )
        .bind(match_query)
        .bind(limit)
        .fetch_all(pool)
        .await
    }

    /// All embedded chunks as (chunk_id, meeting_id, embedding_bytes, dim) for brute-force
    /// cosine. Fine at single-user scale (a few MB of vectors); revisit with an ANN index
    /// only if a vault ever grows past tens of thousands of chunks.
    pub async fn all_embeddings(
        pool: &SqlitePool,
    ) -> Result<Vec<(String, String, Vec<u8>, i64)>, sqlx::Error> {
        sqlx::query_as::<_, (String, String, Vec<u8>, i64)>(
            "SELECT id, meeting_id, embedding, COALESCE(dim, 0) \
             FROM recall_chunks WHERE embedding IS NOT NULL",
        )
        .fetch_all(pool)
        .await
    }

    pub async fn get_chunks_by_ids(
        pool: &SqlitePool,
        ids: &[String],
    ) -> Result<Vec<RecallChunk>, sqlx::Error> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let mut builder = QueryBuilder::<Sqlite>::new(
            "SELECT id, meeting_id, chunk_index, chunk_text, start_time, end_time, \
             timestamp_label, embedding, embedding_model, dim, token_estimate, created_at \
             FROM recall_chunks WHERE id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in ids {
            separated.push_bind(id);
        }
        builder.push(")");
        builder
            .build_query_as::<RecallChunk>()
            .fetch_all(pool)
            .await
    }
}
