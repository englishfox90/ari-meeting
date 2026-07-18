use crate::models::{MeetingDetails, MeetingTranscript};
use crate::database::models::{MeetingModel, Transcript};
use chrono::Utc;
use sqlx::{Connection, Error as SqlxError, SqliteConnection, SqlitePool};
use tracing::{error, info};

pub struct MeetingsRepository;

impl MeetingsRepository {
    pub async fn get_meetings(pool: &SqlitePool) -> Result<Vec<MeetingModel>, sqlx::Error> {
        let meetings =
            sqlx::query_as::<_, MeetingModel>("SELECT * FROM meetings ORDER BY created_at DESC")
                .fetch_all(pool)
                .await?;
        Ok(meetings)
    }

    /// Records which LLM provider + model produced the meeting's summary.
    /// Called on summary completion so the UI can show real provenance
    /// (mirrors the transcription provenance columns). Additive-only.
    pub async fn update_summary_provenance(
        pool: &SqlitePool,
        meeting_id: &str,
        summary_provider: &str,
        summary_model: &str,
    ) -> Result<(), SqlxError> {
        sqlx::query(
            "UPDATE meetings SET summary_provider = ?, summary_model = ?, updated_at = ? WHERE id = ?",
        )
        .bind(summary_provider)
        .bind(summary_model)
        .bind(Utc::now())
        .bind(meeting_id)
        .execute(pool)
        .await?;
        Ok(())
    }

    /// Records which summary template produced the meeting's summary so the
    /// Template picker can reflect the template that was actually used
    /// (including F6 auto-suggested ones) instead of the global default.
    /// Called on summary completion. Additive-only.
    pub async fn update_summary_template(
        pool: &SqlitePool,
        meeting_id: &str,
        template_id: &str,
    ) -> Result<(), SqlxError> {
        sqlx::query("UPDATE meetings SET template_id = ?, updated_at = ? WHERE id = ?")
            .bind(template_id)
            .bind(Utc::now())
            .bind(meeting_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    /// Returns the summary template id for a meeting, so the Template picker can
    /// initialise to the template that produced the existing summary.
    ///
    /// Prefers the `meetings.template_id` column (written on summary
    /// completion). For meetings summarized before that column existed it falls
    /// back to the `template_id` embedded in the `summary_processes.result`
    /// cache blob (`english_cache.source.template_id`). Returns `None` when no
    /// summary has been generated yet — callers should default to the standard
    /// template in that case.
    pub async fn get_summary_template(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<Option<String>, SqlxError> {
        if meeting_id.trim().is_empty() {
            return Err(SqlxError::Protocol(
                "meeting_id cannot be empty".to_string(),
            ));
        }

        // Fast path: the dedicated column, written for summaries generated after
        // migration 20260716130000.
        let column: Option<Option<String>> =
            sqlx::query_scalar("SELECT template_id FROM meetings WHERE id = ?")
                .bind(meeting_id)
                .fetch_optional(pool)
                .await?;
        if let Some(Some(template_id)) = column {
            if !template_id.trim().is_empty() {
                return Ok(Some(template_id));
            }
        }

        // Backfill path: recover the template from the summary result blob.
        let result_json: Option<Option<String>> =
            sqlx::query_scalar("SELECT result FROM summary_processes WHERE meeting_id = ?")
                .bind(meeting_id)
                .fetch_optional(pool)
                .await?;
        if let Some(Some(raw)) = result_json {
            if let Some(template_id) = template_id_from_result_blob(&raw) {
                return Ok(Some(template_id));
            }
        }

        Ok(None)
    }

    pub async fn delete_meeting(pool: &SqlitePool, meeting_id: &str) -> Result<bool, SqlxError> {
        if meeting_id.trim().is_empty() {
            return Err(SqlxError::Protocol(
                "meeting_id cannot be empty".to_string(),
            ));
        }

        let mut conn = pool.acquire().await?;
        let mut transaction = conn.begin().await?;

        match delete_meeting_with_transaction(&mut transaction, meeting_id).await {
            Ok(success) => {
                if success {
                    transaction.commit().await?;
                    info!(
                        "Successfully deleted meeting {} and all associated data",
                        meeting_id
                    );
                    Ok(true)
                } else {
                    transaction.rollback().await?;
                    Ok(false)
                }
            }
            Err(e) => {
                let _ = transaction.rollback().await;
                error!("Failed to delete meeting {}: {}", meeting_id, e);
                Err(e)
            }
        }
    }

    pub async fn get_meeting(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<Option<MeetingDetails>, SqlxError> {
        if meeting_id.trim().is_empty() {
            return Err(SqlxError::Protocol(
                "meeting_id cannot be empty".to_string(),
            ));
        }

        let mut conn = pool.acquire().await?;
        let mut transaction = conn.begin().await?;

        // Get meeting details
        let meeting: Option<MeetingModel> =
            sqlx::query_as("SELECT id, title, created_at, updated_at, folder_path, transcription_provider, transcription_model, summary_provider, summary_model FROM meetings WHERE id = ?")
                .bind(meeting_id)
                .fetch_optional(&mut *transaction)
                .await?;

        if meeting.is_none() {
            transaction.rollback().await?;
            return Err(SqlxError::RowNotFound);
        }

        if let Some(meeting) = meeting {
            // Get all transcripts for this meeting
            let transcripts =
                sqlx::query_as::<_, Transcript>("SELECT * FROM transcripts WHERE meeting_id = ?")
                    .bind(meeting_id)
                    .fetch_all(&mut *transaction)
                    .await?;

            transaction.commit().await?;

            // Convert Transcript to MeetingTranscript
            let meeting_transcripts = transcripts
                .into_iter()
                .map(|t| MeetingTranscript {
                    id: t.id,
                    text: t.transcript,
                    timestamp: t.timestamp,
                    audio_start_time: t.audio_start_time,
                    audio_end_time: t.audio_end_time,
                    duration: t.duration,
                    speaker_id: t.speaker_id,
                })
                .collect::<Vec<_>>();

            Ok(Some(MeetingDetails {
                id: meeting.id,
                title: meeting.title,
                created_at: meeting.created_at.0.to_rfc3339(),
                updated_at: meeting.updated_at.0.to_rfc3339(),
                transcripts: meeting_transcripts,
            }))
        } else {
            transaction.rollback().await?;
            Ok(None)
        }
    }

    /// Get meeting metadata without transcripts (for pagination)
    pub async fn get_meeting_metadata(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<Option<MeetingModel>, SqlxError> {
        if meeting_id.trim().is_empty() {
            return Err(SqlxError::Protocol(
                "meeting_id cannot be empty".to_string(),
            ));
        }

        let meeting: Option<MeetingModel> =
            sqlx::query_as("SELECT id, title, created_at, updated_at, folder_path, transcription_provider, transcription_model, summary_provider, summary_model FROM meetings WHERE id = ?")
                .bind(meeting_id)
                .fetch_optional(pool)
                .await?;

        Ok(meeting)
    }

    /// Get meeting transcripts with pagination support
    pub async fn get_meeting_transcripts_paginated(
        pool: &SqlitePool,
        meeting_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<(Vec<Transcript>, i64), SqlxError> {
        if meeting_id.trim().is_empty() {
            return Err(SqlxError::Protocol(
                "meeting_id cannot be empty".to_string(),
            ));
        }

        // Get total count of transcripts for this meeting
        let total: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM transcripts WHERE meeting_id = ?"
        )
        .bind(meeting_id)
        .fetch_one(pool)
        .await?;

        // Get paginated transcripts ordered by audio_start_time
        let transcripts = sqlx::query_as::<_, Transcript>(
            "SELECT * FROM transcripts
             WHERE meeting_id = ?
             ORDER BY audio_start_time ASC
             LIMIT ? OFFSET ?"
        )
        .bind(meeting_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(pool)
        .await?;

        Ok((transcripts, total.0))
    }

    pub async fn update_meeting_title(
        pool: &SqlitePool,
        meeting_id: &str,
        new_title: &str,
    ) -> Result<bool, SqlxError> {
        if meeting_id.trim().is_empty() {
            return Err(SqlxError::Protocol(
                "meeting_id cannot be empty".to_string(),
            ));
        }

        let mut conn = pool.acquire().await?;
        let mut transaction = conn.begin().await?;

        let now = Utc::now().naive_utc();

        let rows_affected =
            sqlx::query("UPDATE meetings SET title = ?, updated_at = ? WHERE id = ?")
                .bind(new_title)
                .bind(now)
                .bind(meeting_id)
                .execute(&mut *transaction)
                .await?;
        if rows_affected.rows_affected() == 0 {
            transaction.rollback().await?;
            return Ok(false);
        }
        transaction.commit().await?;
        Ok(true)
    }

    pub async fn update_meeting_name(
        pool: &SqlitePool,
        meeting_id: &str,
        new_title: &str,
    ) -> Result<bool, SqlxError> {
        let mut transaction = pool.begin().await?;
        let now = Utc::now();

        // Update meetings table
        let meeting_update =
            sqlx::query("UPDATE meetings SET title = ?, updated_at = ? WHERE id = ?")
                .bind(new_title)
                .bind(now)
                .bind(meeting_id)
                .execute(&mut *transaction)
                .await?;

        if meeting_update.rows_affected() == 0 {
            transaction.rollback().await?;
            return Ok(false); // Meeting not found
        }

        // Update transcript_chunks table
        sqlx::query("UPDATE transcript_chunks SET meeting_name = ? WHERE meeting_id = ?")
            .bind(new_title)
            .bind(meeting_id)
            .execute(&mut *transaction)
            .await?;

        transaction.commit().await?;
        Ok(true)
    }
}

/// Extracts the template id from a `summary_processes.result` JSON blob.
///
/// The template id is stored inside the English-cache metadata the summary
/// service writes on completion (`english_cache.source.template_id`). Used to
/// backfill the per-meeting template for summaries generated before the
/// dedicated `meetings.template_id` column existed. Returns `None` if the blob
/// is malformed or predates the cache format.
fn template_id_from_result_blob(raw: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(raw).ok()?;
    let template_id = value
        .get("english_cache")?
        .get("source")?
        .get("template_id")?
        .as_str()?
        .trim();
    if template_id.is_empty() {
        None
    } else {
        Some(template_id.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::template_id_from_result_blob;

    #[test]
    fn extracts_template_id_from_cache_blob() {
        // Mirrors the shape written by summary::service::build_summary_result_json.
        let raw = r##"{
            "markdown": "# Notes",
            "english_cache": {
                "markdown": "# Notes",
                "source": { "template_id": "one_on_one", "template_fingerprint": "abc:5" },
                "output_language": null
            }
        }"##;
        assert_eq!(
            template_id_from_result_blob(raw),
            Some("one_on_one".to_string())
        );
    }

    #[test]
    fn returns_none_for_legacy_blob_without_cache() {
        let raw = r##"{ "markdown": "# Notes" }"##;
        assert_eq!(template_id_from_result_blob(raw), None);
    }

    #[test]
    fn returns_none_for_malformed_or_empty_template_id() {
        assert_eq!(template_id_from_result_blob("not json"), None);
        let blank = r#"{ "english_cache": { "source": { "template_id": "  " } } }"#;
        assert_eq!(template_id_from_result_blob(blank), None);
    }
}

async fn delete_meeting_with_transaction(
    transaction: &mut SqliteConnection,
    meeting_id: &str,
) -> Result<bool, SqlxError> {
    // Check if meeting exists
    let meeting_exists: Option<(i64,)> = sqlx::query_as("SELECT 1 FROM meetings WHERE id = ?")
        .bind(meeting_id)
        .fetch_optional(&mut *transaction)
        .await?;

    if meeting_exists.is_none() {
        error!("Meeting {} not found for deletion", meeting_id);
        return Ok(false);
    }

    // Delete from related tables in proper order
    // 1. Delete from transcript_chunks
    sqlx::query("DELETE FROM transcript_chunks WHERE meeting_id = ?")
        .bind(meeting_id)
        .execute(&mut *transaction)
        .await?;

    // 2. Delete from summary_processes
    sqlx::query("DELETE FROM summary_processes WHERE meeting_id = ?")
        .bind(meeting_id)
        .execute(&mut *transaction)
        .await?;

    // 3. Delete from transcripts
    sqlx::query("DELETE FROM transcripts WHERE meeting_id = ?")
        .bind(meeting_id)
        .execute(&mut *transaction)
        .await?;

    // 4. Finally, delete the meeting
    let result = sqlx::query("DELETE FROM meetings WHERE id = ?")
        .bind(meeting_id)
        .execute(&mut *transaction)
        .await?;

    Ok(result.rows_affected() > 0)
}
