// Speaker Diarization (F1) repository — additive DB access layer for speakers /
// speaker_segments. Follows the sanctioned pattern (mirrors person.rs): unit struct,
// `pool: &SqlitePool` first, runtime sqlx query/query_as (no compile-time macros),
// `Result<_, sqlx::Error>`.
//
// This layer persists opaque BLOBs only. The centroid/embedding f32 math (averaging,
// similarity) is owned by the pure matcher module in a separate workstream; here a
// centroid is just bytes.

use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::database::models::{Speaker, SpeakerSegment};

pub struct SpeakerRepository;

impl SpeakerRepository {
    /// Insert a provisional speaker plus its first diarized segment for a meeting, inside a
    /// transaction. Returns the new speaker id. `centroid` is opaque bytes (matcher-owned).
    #[allow(clippy::too_many_arguments)]
    pub async fn insert_provisional(
        pool: &SqlitePool,
        meeting_id: &str,
        cluster_key: &str,
        source: &str,
        centroid: &[u8],
        embedding_model: &str,
        dim: i64,
        start_time: f64,
        end_time: f64,
        total_speech_secs: f64,
    ) -> Result<String, sqlx::Error> {
        let speaker_id = Uuid::new_v4().to_string();
        let segment_id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();

        let mut tx = pool.begin().await?;

        sqlx::query(
            r#"
            INSERT INTO speakers (
                id, person_id, label, centroid, embedding_model, dim, samples,
                enrollment_state, total_speech_secs, created_at, updated_at
            ) VALUES (?, NULL, NULL, ?, ?, ?, 1, 'provisional', ?, ?, ?)
            "#,
        )
        .bind(&speaker_id)
        .bind(centroid)
        .bind(embedding_model)
        .bind(dim)
        .bind(total_speech_secs)
        .bind(&now)
        .bind(&now)
        .execute(&mut *tx)
        .await?;

        sqlx::query(
            r#"
            INSERT INTO speaker_segments (
                id, meeting_id, speaker_id, cluster_key, start_time, end_time, source,
                embedding, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind(&segment_id)
        .bind(meeting_id)
        .bind(&speaker_id)
        .bind(cluster_key)
        .bind(start_time)
        .bind(end_time)
        .bind(source)
        .bind(centroid)
        .bind(&now)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(speaker_id)
    }

    pub async fn get(pool: &SqlitePool, speaker_id: &str) -> Result<Option<Speaker>, sqlx::Error> {
        sqlx::query_as::<_, Speaker>("SELECT * FROM speakers WHERE id = ?")
            .bind(speaker_id)
            .fetch_optional(pool)
            .await
    }

    /// Speakers that have spoken in a meeting (via speaker_segments). Distinct speakers only.
    pub async fn list_for_meeting(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<Vec<Speaker>, sqlx::Error> {
        sqlx::query_as::<_, Speaker>(
            r#"
            SELECT DISTINCT s.* FROM speakers s
            JOIN speaker_segments seg ON seg.speaker_id = s.id
            WHERE seg.meeting_id = ?
            ORDER BY s.created_at ASC
            "#,
        )
        .bind(meeting_id)
        .fetch_all(pool)
        .await
    }

    pub async fn list_segments_for_meeting(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<Vec<SpeakerSegment>, sqlx::Error> {
        sqlx::query_as::<_, SpeakerSegment>(
            r#"
            SELECT * FROM speaker_segments
            WHERE meeting_id = ?
            ORDER BY start_time ASC
            "#,
        )
        .bind(meeting_id)
        .fetch_all(pool)
        .await
    }

    /// Link a speaker to a person and mark it confirmed (confirm-before-enroll gate).
    pub async fn assign_to_person(
        pool: &SqlitePool,
        speaker_id: &str,
        person_id: &str,
    ) -> Result<(), sqlx::Error> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            UPDATE speakers
            SET person_id = ?, enrollment_state = 'confirmed', updated_at = ?
            WHERE id = ?
            "#,
        )
        .bind(person_id)
        .bind(&now)
        .bind(speaker_id)
        .execute(pool)
        .await?;
        Ok(())
    }

    /// Distinct meetings a speaker has segments in. Used when confirming an assignment so
    /// the person gets linked as a participant of every meeting the voice appeared in.
    pub async fn list_meeting_ids_for_speaker(
        pool: &SqlitePool,
        speaker_id: &str,
    ) -> Result<Vec<String>, sqlx::Error> {
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT DISTINCT meeting_id FROM speaker_segments WHERE speaker_id = ?",
        )
        .bind(speaker_id)
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(|(m,)| m).collect())
    }

    /// Persist an updated centroid + sample count + accumulated speech seconds. The
    /// duration-weighted averaging math is done by the pure matcher
    /// ([`crate::diarization::matching::fold_centroid_weighted`]); this only writes the
    /// result bytes, bumps `samples`, and stores the new (UNcapped) `total_speech_secs`.
    pub async fn fold_centroid(
        pool: &SqlitePool,
        speaker_id: &str,
        new_centroid: &[u8],
        new_samples: i64,
        new_total_speech_secs: f64,
    ) -> Result<(), sqlx::Error> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            UPDATE speakers
            SET centroid = ?, samples = ?, total_speech_secs = ?, updated_at = ?
            WHERE id = ?
            "#,
        )
        .bind(new_centroid)
        .bind(new_samples)
        .bind(new_total_speech_secs)
        .bind(&now)
        .bind(speaker_id)
        .execute(pool)
        .await?;
        Ok(())
    }

    /// Enrolled voiceprints to match a new embedding against (person_id NOT NULL).
    pub async fn list_all_enrolled(pool: &SqlitePool) -> Result<Vec<Speaker>, sqlx::Error> {
        sqlx::query_as::<_, Speaker>(
            "SELECT * FROM speakers WHERE person_id IS NOT NULL ORDER BY updated_at DESC",
        )
        .fetch_all(pool)
        .await
    }

    /// Insert ONE `speaker_segment` referencing an already-existing speaker. Used by the
    /// diarization orchestrator to record (a) the extra segments of a freshly-created
    /// provisional cluster, and (b) every segment of a cluster matched to an enrolled
    /// speaker. Mirrors the segment INSERT in [`Self::insert_provisional`]; `embedding` is
    /// optional (typically `Some` on the first segment of a cluster, `None` on the rest).
    /// `centroid` is opaque bytes (matcher-owned). Returns the new segment id.
    #[allow(clippy::too_many_arguments)]
    pub async fn insert_segment(
        pool: &SqlitePool,
        meeting_id: &str,
        speaker_id: &str,
        cluster_key: &str,
        source: &str,
        start_time: f64,
        end_time: f64,
        embedding: Option<&[u8]>,
    ) -> Result<String, sqlx::Error> {
        let segment_id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            INSERT INTO speaker_segments (
                id, meeting_id, speaker_id, cluster_key, start_time, end_time, source,
                embedding, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind(&segment_id)
        .bind(meeting_id)
        .bind(speaker_id)
        .bind(cluster_key)
        .bind(start_time)
        .bind(end_time)
        .bind(source)
        .bind(embedding)
        .bind(&now)
        .execute(pool)
        .await?;
        Ok(segment_id)
    }

    /// Stamp a transcript row with its resolved speaker (F1). Writes the new `speaker_id`
    /// column added by migration `20260714140000` — NOT the dead mic/system `speaker`
    /// column from `20251110000001`.
    pub async fn set_transcript_speaker(
        pool: &SqlitePool,
        transcript_id: &str,
        speaker_id: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE transcripts SET speaker_id = ? WHERE id = ?")
            .bind(speaker_id)
            .bind(transcript_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    /// Manually reassign a single transcript row's resolved speaker (user-driven
    /// correction from the transcript UI — "this line is actually X" / "this line
    /// has no clear speaker"). Unlike [`Self::set_transcript_speaker`] (internal,
    /// always assigns a known id during automatic stamping), `speaker_id` may be
    /// `None` here to clear a line back to unattributed. Scoped by `meeting_id` so
    /// a stale/wrong `transcript_id` can never touch another meeting's row.
    /// Returns `true` if a row was actually updated.
    pub async fn reassign_transcript_speaker(
        pool: &SqlitePool,
        meeting_id: &str,
        transcript_id: &str,
        speaker_id: Option<&str>,
    ) -> Result<bool, sqlx::Error> {
        let rows_affected =
            sqlx::query("UPDATE transcripts SET speaker_id = ? WHERE id = ? AND meeting_id = ?")
                .bind(speaker_id)
                .bind(transcript_id)
                .bind(meeting_id)
                .execute(pool)
                .await?
                .rows_affected();
        Ok(rows_affected > 0)
    }

    /// Idempotency guard (P0): clear a meeting's prior diarization so a re-run
    /// starts clean instead of double-folding centroids and appending duplicate
    /// segments. Runs three steps in one transaction:
    ///   1. `transcripts.speaker_id = NULL` for the meeting (un-stamp).
    ///   2. delete the meeting's `speaker_segments`.
    ///   3. delete now-orphaned provisional speakers (`person_id IS NULL`,
    ///      `enrollment_state = 'provisional'`, no remaining segments anywhere).
    ///
    /// Owner/confirmed voiceprints are never deleted (their folded centroids can't
    /// be un-folded and are the cross-meeting match pool). Returns
    /// `(transcripts_cleared, segments_deleted, orphan_speakers_deleted)`.
    pub async fn clear_meeting_diarization(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<(u64, u64, u64), sqlx::Error> {
        let mut tx = pool.begin().await?;

        let transcripts_cleared =
            sqlx::query("UPDATE transcripts SET speaker_id = NULL WHERE meeting_id = ?")
                .bind(meeting_id)
                .execute(&mut *tx)
                .await?
                .rows_affected();

        let segments_deleted =
            sqlx::query("DELETE FROM speaker_segments WHERE meeting_id = ?")
                .bind(meeting_id)
                .execute(&mut *tx)
                .await?
                .rows_affected();

        // Provisional speakers with no remaining segments anywhere are orphans.
        let orphans_deleted = sqlx::query(
            r#"
            DELETE FROM speakers
            WHERE person_id IS NULL
              AND enrollment_state = 'provisional'
              AND id NOT IN (
                  SELECT DISTINCT speaker_id FROM speaker_segments
                  WHERE speaker_id IS NOT NULL
              )
            "#,
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();

        tx.commit().await?;
        Ok((transcripts_cleared, segments_deleted, orphans_deleted))
    }

    /// Find-or-create the owner's enrolled voiceprint speaker (the clean mic-track
    /// enrollment). Returns `(speaker_id, existed_before)`.
    ///
    /// When `existed_before` is `true` the row is returned UNCHANGED — the caller is
    /// responsible for folding the fresh embedding into the returned speaker's centroid
    /// (the f32 averaging math lives in the pure matcher, never in this layer) and
    /// persisting the result via [`Self::fold_centroid`]. When `false`, a new speaker was
    /// inserted with `enrollment_state = 'owner'`, `samples = 1`, and the given centroid.
    pub async fn upsert_owner_speaker(
        pool: &SqlitePool,
        person_id: &str,
        centroid: &[u8],
        embedding_model: &str,
        dim: i64,
        total_speech_secs: f64,
    ) -> Result<(String, bool), sqlx::Error> {
        if let Some(existing) = sqlx::query_as::<_, Speaker>(
            "SELECT * FROM speakers WHERE person_id = ? AND enrollment_state = 'owner' LIMIT 1",
        )
        .bind(person_id)
        .fetch_optional(pool)
        .await?
        {
            return Ok((existing.id, true));
        }

        let speaker_id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            INSERT INTO speakers (
                id, person_id, label, centroid, embedding_model, dim, samples,
                enrollment_state, total_speech_secs, created_at, updated_at
            ) VALUES (?, ?, NULL, ?, ?, ?, 1, 'owner', ?, ?, ?)
            "#,
        )
        .bind(&speaker_id)
        .bind(person_id)
        .bind(centroid)
        .bind(embedding_model)
        .bind(dim)
        .bind(total_speech_secs)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await?;
        Ok((speaker_id, false))
    }

    /// Fetch the owner's persistent voiceprint row (`enrollment_state = 'owner'`) for a
    /// person WITHOUT creating one, so callers can read the PRIOR centroid before any
    /// fold. Used by mic diarization to decide which mic cluster is the owner. `None`
    /// when the owner has no voiceprint yet (bootstrap case).
    pub async fn get_owner_speaker(
        pool: &SqlitePool,
        person_id: &str,
    ) -> Result<Option<Speaker>, sqlx::Error> {
        sqlx::query_as::<_, Speaker>(
            "SELECT * FROM speakers WHERE person_id = ? AND enrollment_state = 'owner' LIMIT 1",
        )
        .bind(person_id)
        .fetch_optional(pool)
        .await
    }

    /// Reset (delete) the owner's persistent voiceprint so the next diarization rebuilds
    /// it clean — the recovery path when an in-person meeting folded another person's
    /// voice into the owner centroid. In one transaction: un-stamp transcripts pointing
    /// at the owner speaker row(s), delete their `speaker_segments`, then delete the
    /// owner `speakers` row(s) for this person. Other speakers/persons are untouched.
    /// Returns `(transcripts_unstamped, segments_deleted, speakers_deleted)`.
    pub async fn reset_owner_voiceprint(
        pool: &SqlitePool,
        person_id: &str,
    ) -> Result<(u64, u64, u64), sqlx::Error> {
        let mut tx = pool.begin().await?;

        // Owner voiceprint row ids for this person (usually one).
        let owner_ids: Vec<String> = sqlx::query_scalar(
            "SELECT id FROM speakers WHERE person_id = ? AND enrollment_state = 'owner'",
        )
        .bind(person_id)
        .fetch_all(&mut *tx)
        .await?;

        if owner_ids.is_empty() {
            tx.commit().await?;
            return Ok((0, 0, 0));
        }

        let mut transcripts_unstamped = 0u64;
        let mut segments_deleted = 0u64;
        let mut speakers_deleted = 0u64;
        for id in &owner_ids {
            transcripts_unstamped += sqlx::query(
                "UPDATE transcripts SET speaker_id = NULL WHERE speaker_id = ?",
            )
            .bind(id)
            .execute(&mut *tx)
            .await?
            .rows_affected();

            segments_deleted +=
                sqlx::query("DELETE FROM speaker_segments WHERE speaker_id = ?")
                    .bind(id)
                    .execute(&mut *tx)
                    .await?
                    .rows_affected();

            speakers_deleted += sqlx::query("DELETE FROM speakers WHERE id = ?")
                .bind(id)
                .execute(&mut *tx)
                .await?
                .rows_affected();
        }

        tx.commit().await?;
        Ok((transcripts_unstamped, segments_deleted, speakers_deleted))
    }

    /// Find the CANONICAL enrolled speaker row for a person under a given embedding
    /// model (P1 merge-to-canonical). Canonical = an enrolled row (`person_id` set)
    /// for this person in the same vector space. `exclude_speaker_id` skips the row
    /// currently being assigned so it never matches itself. Prefers the `owner` row,
    /// then the one with the most accumulated speech (the strongest voiceprint).
    /// Returns `None` when the person has no other enrolled voiceprint yet (the
    /// caller then makes the assigned row the canonical).
    pub async fn find_canonical_for_person(
        pool: &SqlitePool,
        person_id: &str,
        embedding_model: &str,
        exclude_speaker_id: &str,
    ) -> Result<Option<Speaker>, sqlx::Error> {
        sqlx::query_as::<_, Speaker>(
            r#"
            SELECT * FROM speakers
            WHERE person_id = ?
              AND embedding_model = ?
              AND id != ?
            ORDER BY (enrollment_state = 'owner') DESC, total_speech_secs DESC, samples DESC
            LIMIT 1
            "#,
        )
        .bind(person_id)
        .bind(embedding_model)
        .bind(exclude_speaker_id)
        .fetch_optional(pool)
        .await
    }

    /// Merge one speaker row into another (P1 merge-to-canonical / retro-relabel):
    /// repoint every `speaker_segments.speaker_id` and `transcripts.speaker_id` from
    /// `from_id` to `to_id`, then delete the now-empty `from_id` row — all in one
    /// transaction. The centroid fold itself is done separately by the caller (the
    /// matcher owns the f32 math); this only moves the references and reaps the row.
    /// Returns `(segments_repointed, transcripts_repointed)`.
    pub async fn repoint_and_delete_speaker(
        pool: &SqlitePool,
        from_id: &str,
        to_id: &str,
    ) -> Result<(u64, u64), sqlx::Error> {
        let mut tx = pool.begin().await?;

        let segs = sqlx::query("UPDATE speaker_segments SET speaker_id = ? WHERE speaker_id = ?")
            .bind(to_id)
            .bind(from_id)
            .execute(&mut *tx)
            .await?
            .rows_affected();

        let trs = sqlx::query("UPDATE transcripts SET speaker_id = ? WHERE speaker_id = ?")
            .bind(to_id)
            .bind(from_id)
            .execute(&mut *tx)
            .await?
            .rows_affected();

        sqlx::query("DELETE FROM speakers WHERE id = ?")
            .bind(from_id)
            .execute(&mut *tx)
            .await?;

        tx.commit().await?;
        Ok((segs, trs))
    }

    /// Provisional speakers eligible for retroactive relabel against a freshly-
    /// established canonical (P1). Returns rows that are unassigned
    /// (`person_id IS NULL`, `enrollment_state = 'provisional'`) in the SAME vector
    /// space (`embedding_model`), excluding the canonical itself and — critically —
    /// **any provisional that shares a meeting with the canonical**. That exclusion
    /// prevents merging two distinct co-present voices from one meeting into the same
    /// person. Bounded by `limit` (runaway guard). Newest first.
    pub async fn list_provisional_for_relabel(
        pool: &SqlitePool,
        embedding_model: &str,
        canonical_speaker_id: &str,
        limit: i64,
    ) -> Result<Vec<Speaker>, sqlx::Error> {
        sqlx::query_as::<_, Speaker>(
            r#"
            SELECT * FROM speakers s
            WHERE s.person_id IS NULL
              AND s.enrollment_state = 'provisional'
              AND s.embedding_model = ?
              AND s.id != ?
              AND s.id NOT IN (
                  SELECT DISTINCT seg.speaker_id FROM speaker_segments seg
                  WHERE seg.speaker_id IS NOT NULL
                    AND seg.meeting_id IN (
                        SELECT DISTINCT meeting_id FROM speaker_segments
                        WHERE speaker_id = ?
                    )
              )
            ORDER BY s.updated_at DESC
            LIMIT ?
            "#,
        )
        .bind(embedding_model)
        .bind(canonical_speaker_id)
        .bind(canonical_speaker_id)
        .bind(limit)
        .fetch_all(pool)
        .await
    }

    /// The CANONICAL enrolled voiceprint for a person: an assigned row
    /// (`person_id` matches) whose `enrollment_state` is `owner` or `confirmed`.
    /// Prefers the `owner` row, then the strongest voiceprint (most accumulated
    /// speech, then most folds). Read-only; used by the voiceprint-signature
    /// command to draw a person's "voice ring". Returns `None` when the person
    /// has no enrolled voiceprint yet (→ the frontend shows nothing, never a
    /// fabricated glyph).
    pub async fn canonical_enrolled_for_person(
        pool: &SqlitePool,
        person_id: &str,
    ) -> Result<Option<Speaker>, sqlx::Error> {
        sqlx::query_as::<_, Speaker>(
            r#"
            SELECT * FROM speakers
            WHERE person_id = ?
              AND enrollment_state IN ('owner', 'confirmed')
            ORDER BY (enrollment_state = 'owner') DESC, total_speech_secs DESC, samples DESC
            LIMIT 1
            "#,
        )
        .bind(person_id)
        .fetch_optional(pool)
        .await
    }

    /// Every person's CANONICAL enrolled voiceprint, one row per person (P-batch).
    /// All `owner`/`confirmed` rows ordered so the canonical for each person sorts
    /// first within its `person_id` group; the caller keeps the first per person.
    /// Read-only; backs the batch voiceprint-signature command for list rows.
    pub async fn list_canonical_enrolled(
        pool: &SqlitePool,
    ) -> Result<Vec<Speaker>, sqlx::Error> {
        sqlx::query_as::<_, Speaker>(
            r#"
            SELECT * FROM speakers
            WHERE person_id IS NOT NULL
              AND enrollment_state IN ('owner', 'confirmed')
            ORDER BY person_id ASC, (enrollment_state = 'owner') DESC, total_speech_secs DESC, samples DESC
            "#,
        )
        .fetch_all(pool)
        .await
    }

    /// Sum of a speaker's segment durations across all meetings (P1). Used as the
    /// fold weight `w` when merging a provisional into a canonical voiceprint, and to
    /// seed `total_speech_secs` retroactively when precise per-cluster speech isn't
    /// otherwise in hand.
    pub async fn total_segment_secs(
        pool: &SqlitePool,
        speaker_id: &str,
    ) -> Result<f64, sqlx::Error> {
        let secs: Option<f64> = sqlx::query_scalar(
            "SELECT COALESCE(SUM(end_time - start_time), 0.0) FROM speaker_segments WHERE speaker_id = ?",
        )
        .bind(speaker_id)
        .fetch_one(pool)
        .await?;
        Ok(secs.unwrap_or(0.0))
    }
}
