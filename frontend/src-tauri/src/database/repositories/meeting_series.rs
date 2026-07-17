// Meeting Series (F9) repository — additive DB access layer for meeting_series /
// meeting_series_members / series_ledger. Follows the sanctioned pattern (mirrors person.rs /
// calendar.rs): unit struct, `pool: &SqlitePool` first, runtime sqlx query/query_as (no
// compile-time macros), `Result<_, sqlx::Error>`.
//
// Manual links are sacred: `link_source = 'manual'` marks a user-authored membership; the
// upsert never silently downgrades it to 'auto' (excluded.link_source carries the new value).

use sqlx::{FromRow, SqlitePool};

#[derive(Debug, Clone, FromRow)]
pub struct MeetingSeriesRow {
    pub id: String,
    pub series_key: Option<String>,
    pub title: String,
    pub detected_type: Option<String>,
    pub cadence: Option<String>,
    pub owner_person_id: Option<String>,
    /// F9 template inheritance: the summary template this series settled on, if any.
    pub template_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

/// A meeting not currently a member of any series — used by heuristic (title-based) series
/// detection. `created_at` is read as a text string (SQLite stores DateTime as TEXT).
#[derive(Debug, Clone, FromRow)]
pub struct UnseriesedMeetingRow {
    pub id: String,
    pub title: String,
    pub created_at: String,
}

#[derive(Debug, Clone, FromRow)]
pub struct MeetingSeriesMemberRow {
    pub series_id: String,
    pub meeting_id: String,
    pub occurrence_time: Option<String>,
    pub link_source: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, FromRow)]
pub struct SeriesLedgerRow {
    pub series_id: String,
    pub ledger_markdown: Option<String>,
    pub structured_json: Option<String>,
    pub updated_from_meeting_id: Option<String>,
    pub version: i64,
    pub created_at: String,
    pub updated_at: String,
}

pub struct MeetingSeriesRepository;

impl MeetingSeriesRepository {
    // ===== meeting_series =====

    pub async fn find_series_by_key(
        pool: &SqlitePool,
        series_key: &str,
    ) -> Result<Option<MeetingSeriesRow>, sqlx::Error> {
        sqlx::query_as::<_, MeetingSeriesRow>("SELECT * FROM meeting_series WHERE series_key = ?")
            .bind(series_key)
            .fetch_optional(pool)
            .await
    }

    pub async fn get_series(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<Option<MeetingSeriesRow>, sqlx::Error> {
        sqlx::query_as::<_, MeetingSeriesRow>("SELECT * FROM meeting_series WHERE id = ?")
            .bind(id)
            .fetch_optional(pool)
            .await
    }

    pub async fn list_series(pool: &SqlitePool) -> Result<Vec<MeetingSeriesRow>, sqlx::Error> {
        sqlx::query_as::<_, MeetingSeriesRow>("SELECT * FROM meeting_series ORDER BY title ASC")
            .fetch_all(pool)
            .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn insert_series(
        pool: &SqlitePool,
        id: &str,
        series_key: Option<&str>,
        title: &str,
        detected_type: Option<&str>,
        cadence: Option<&str>,
        owner_person_id: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            r#"
            INSERT INTO meeting_series (
                id, series_key, title, detected_type, cadence, owner_person_id,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind(id)
        .bind(series_key)
        .bind(title)
        .bind(detected_type)
        .bind(cadence)
        .bind(owner_person_id)
        .bind(now)
        .bind(now)
        .execute(pool)
        .await?;
        Ok(())
    }

    pub async fn update_series_meta(
        pool: &SqlitePool,
        id: &str,
        title: &str,
        detected_type: Option<&str>,
        cadence: Option<&str>,
        owner_person_id: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            r#"
            UPDATE meeting_series SET
                title = ?,
                detected_type = ?,
                cadence = ?,
                owner_person_id = ?,
                updated_at = ?
            WHERE id = ?
            "#,
        )
        .bind(title)
        .bind(detected_type)
        .bind(cadence)
        .bind(owner_person_id)
        .bind(now)
        .bind(id)
        .execute(pool)
        .await?;
        Ok(())
    }

    /// F9 template inheritance: record the summary template a series settled on.
    pub async fn set_template(
        pool: &SqlitePool,
        series_id: &str,
        template_id: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE meeting_series SET template_id = ?, updated_at = ? WHERE id = ?")
            .bind(template_id)
            .bind(now)
            .bind(series_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    // ===== meeting_series_members =====

    /// List meetings that are NOT a member of any series (id, title, created_at), oldest first.
    /// Feeds heuristic (title-based) series detection. Members already in a series are excluded,
    /// which is what makes a rescan idempotent.
    pub async fn list_unseriesed_meetings(
        pool: &SqlitePool,
    ) -> Result<Vec<UnseriesedMeetingRow>, sqlx::Error> {
        sqlx::query_as::<_, UnseriesedMeetingRow>(
            r#"
            SELECT m.id, m.title, m.created_at
            FROM meetings m
            LEFT JOIN meeting_series_members msm ON msm.meeting_id = m.id
            WHERE msm.series_id IS NULL
            ORDER BY m.created_at ASC
            "#,
        )
        .fetch_all(pool)
        .await
    }

    pub async fn upsert_member(
        pool: &SqlitePool,
        series_id: &str,
        meeting_id: &str,
        occurrence_time: Option<&str>,
        link_source: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            r#"
            INSERT INTO meeting_series_members (
                series_id, meeting_id, occurrence_time, link_source, created_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(series_id, meeting_id) DO UPDATE SET
                link_source = excluded.link_source
            "#,
        )
        .bind(series_id)
        .bind(meeting_id)
        .bind(occurrence_time)
        .bind(link_source)
        .bind(now)
        .execute(pool)
        .await?;
        Ok(())
    }

    pub async fn remove_member(
        pool: &SqlitePool,
        series_id: &str,
        meeting_id: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM meeting_series_members WHERE series_id = ? AND meeting_id = ?")
            .bind(series_id)
            .bind(meeting_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    pub async fn list_members(
        pool: &SqlitePool,
        series_id: &str,
    ) -> Result<Vec<MeetingSeriesMemberRow>, sqlx::Error> {
        sqlx::query_as::<_, MeetingSeriesMemberRow>(
            r#"
            SELECT * FROM meeting_series_members
            WHERE series_id = ?
            ORDER BY occurrence_time ASC, created_at ASC
            "#,
        )
        .bind(series_id)
        .fetch_all(pool)
        .await
    }

    pub async fn series_for_meeting(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<Option<MeetingSeriesRow>, sqlx::Error> {
        sqlx::query_as::<_, MeetingSeriesRow>(
            r#"
            SELECT ms.* FROM meeting_series ms
            JOIN meeting_series_members msm ON msm.series_id = ms.id
            WHERE msm.meeting_id = ?
            LIMIT 1
            "#,
        )
        .bind(meeting_id)
        .fetch_optional(pool)
        .await
    }

    // ===== series_ledger =====

    pub async fn get_ledger(
        pool: &SqlitePool,
        series_id: &str,
    ) -> Result<Option<SeriesLedgerRow>, sqlx::Error> {
        sqlx::query_as::<_, SeriesLedgerRow>("SELECT * FROM series_ledger WHERE series_id = ?")
            .bind(series_id)
            .fetch_optional(pool)
            .await
    }

    /// Insert or update the rolling ledger for a series, bumping `version` on every update.
    pub async fn upsert_ledger(
        pool: &SqlitePool,
        series_id: &str,
        ledger_markdown: Option<&str>,
        structured_json: Option<&str>,
        updated_from_meeting_id: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            r#"
            INSERT INTO series_ledger (
                series_id, ledger_markdown, structured_json, updated_from_meeting_id,
                version, created_at, updated_at
            ) VALUES (?, ?, ?, ?, 0, ?, ?)
            ON CONFLICT(series_id) DO UPDATE SET
                ledger_markdown = excluded.ledger_markdown,
                structured_json = excluded.structured_json,
                updated_from_meeting_id = excluded.updated_from_meeting_id,
                version = series_ledger.version + 1,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(series_id)
        .bind(ledger_markdown)
        .bind(structured_json)
        .bind(updated_from_meeting_id)
        .bind(now)
        .bind(now)
        .execute(pool)
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod series_integration_tests {
    use super::MeetingSeriesRepository;
    use crate::database::repositories::calendar::CalendarRepository;
    use crate::meeting_series::detection;
    use sqlx::sqlite::SqlitePoolOptions;
    use sqlx::SqlitePool;

    /// Fresh in-memory pool with all real migrations applied and FK enforcement on.
    /// `max_connections(1)` pins a single in-memory database (each new sqlite::memory:
    /// connection would otherwise be an independent empty DB).
    async fn mem_pool() -> SqlitePool {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::query("PRAGMA foreign_keys = ON;")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        pool
    }

    async fn insert_meeting(pool: &SqlitePool, id: &str, title: &str, created_at: &str) {
        sqlx::query("INSERT INTO meetings (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .bind(id)
            .bind(title)
            .bind(created_at)
            .bind(created_at)
            .execute(pool)
            .await
            .unwrap();
    }

    #[allow(clippy::too_many_arguments)]
    async fn insert_event(
        pool: &SqlitePool,
        id: &str,
        title: &str,
        start_time: &str,
        meeting_id: Option<&str>,
        series_key: Option<&str>,
        has_recurrence: i64,
        occurrence_date: Option<&str>,
    ) {
        sqlx::query(
            r#"
            INSERT INTO calendar_events (
                id, calendar_id, title, start_time, end_time, synced_at,
                meeting_id, series_key, has_recurrence, occurrence_date
            ) VALUES (?, 'cal-1', ?, ?, ?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind(id)
        .bind(title)
        .bind(start_time)
        .bind(start_time) // end_time — value irrelevant for detection
        .bind(start_time) // synced_at
        .bind(meeting_id)
        .bind(series_key)
        .bind(has_recurrence)
        .bind(occurrence_date)
        .execute(pool)
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn migrations_apply_cleanly() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::query("PRAGMA foreign_keys = ON;")
            .execute(&pool)
            .await
            .unwrap();

        // The migrate call succeeding (not erroring) is the core assertion; this also
        // validates the F9 migrations 20260715160000 + 20260715170000.
        let result = sqlx::migrate!("./migrations").run(&pool).await;
        assert!(result.is_ok(), "migrations should apply cleanly: {result:?}");

        // Confirm the F9 tables exist.
        for table in ["meeting_series", "meeting_series_members", "series_ledger"] {
            let found: Option<String> = sqlx::query_scalar(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            )
            .bind(table)
            .fetch_optional(&pool)
            .await
            .unwrap();
            assert_eq!(found.as_deref(), Some(table), "table {table} should exist");
        }

        // Confirm the ALTER-added columns landed.
        let has_series_key: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM pragma_table_info('calendar_events') WHERE name = 'series_key'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(has_series_key, 1, "calendar_events.series_key should exist");

        let has_template_id: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM pragma_table_info('meeting_series') WHERE name = 'template_id'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(has_template_id, 1, "meeting_series.template_id should exist");
    }

    #[tokio::test]
    async fn detection_creates_one_series_and_is_idempotent() {
        let pool = mem_pool().await;

        insert_meeting(&pool, "m1", "Weekly sync", "2026-07-08T09:00:00Z").await;
        insert_meeting(&pool, "m2", "Weekly sync", "2026-07-15T09:00:00Z").await;
        insert_meeting(&pool, "m3", "One-off chat", "2026-07-09T09:00:00Z").await;

        // Two recurring occurrences sharing one series_key, linked to m1 / m2.
        insert_event(
            &pool,
            "ev1",
            "Weekly sync",
            "2026-07-08T09:00:00Z",
            Some("m1"),
            Some("ext-abc"),
            1,
            Some("2026-07-08T09:00:00Z"),
        )
        .await;
        insert_event(
            &pool,
            "ev2",
            "Weekly sync",
            "2026-07-15T09:00:00Z",
            Some("m2"),
            Some("ext-abc"),
            1,
            Some("2026-07-15T09:00:00Z"),
        )
        .await;
        // Negative: non-recurring event (has_recurrence = 0) must NOT create a series.
        insert_event(
            &pool,
            "ev-nonrec",
            "One-off chat",
            "2026-07-09T09:00:00Z",
            Some("m3"),
            Some("ext-nonrec"),
            0,
            Some("2026-07-09T09:00:00Z"),
        )
        .await;
        // Negative: recurring but unlinked (meeting_id NULL) must NOT create a series.
        insert_event(
            &pool,
            "ev-null",
            "Orphan recurring",
            "2026-07-10T09:00:00Z",
            None,
            Some("ext-null"),
            1,
            Some("2026-07-10T09:00:00Z"),
        )
        .await;

        // Run the whole detection loop TWICE to prove idempotency.
        let event_ids = ["ev1", "ev2", "ev-nonrec", "ev-null"];
        for _pass in 0..2 {
            for eid in event_ids {
                let event = CalendarRepository::get_event(&pool, eid)
                    .await
                    .unwrap()
                    .expect("event should exist");
                detection::detect_series_for_event(&pool, &event)
                    .await
                    .unwrap();
            }
        }

        // Exactly one series overall, keyed by 'ext-abc'.
        let all = MeetingSeriesRepository::list_series(&pool).await.unwrap();
        assert_eq!(all.len(), 1, "exactly one series should exist");

        let series = MeetingSeriesRepository::find_series_by_key(&pool, "ext-abc")
            .await
            .unwrap()
            .expect("series 'ext-abc' should exist");

        // Two members, ordered by occurrence time (m1 before m2).
        let members = MeetingSeriesRepository::list_members(&pool, &series.id)
            .await
            .unwrap();
        assert_eq!(members.len(), 2, "series should have exactly two members");
        assert_eq!(members[0].meeting_id, "m1");
        assert_eq!(members[1].meeting_id, "m2");

        // Negative cases produced no series.
        assert!(
            MeetingSeriesRepository::find_series_by_key(&pool, "ext-nonrec")
                .await
                .unwrap()
                .is_none(),
            "non-recurring event must not create a series"
        );
        assert!(
            MeetingSeriesRepository::find_series_by_key(&pool, "ext-null")
                .await
                .unwrap()
                .is_none(),
            "unlinked event must not create a series"
        );
    }

    #[tokio::test]
    async fn membership_ledger_and_template_roundtrip() {
        let pool = mem_pool().await;
        let now = "2026-07-15T12:00:00Z";

        insert_meeting(&pool, "m1", "1:1 Nia", "2026-07-08T09:00:00Z").await;
        insert_meeting(&pool, "m2", "1:1 Nia", "2026-07-15T09:00:00Z").await;

        MeetingSeriesRepository::insert_series(
            &pool,
            "s1",
            Some("k1"),
            "1:1 Nia",
            None,
            None,
            None,
            now,
        )
        .await
        .unwrap();

        MeetingSeriesRepository::upsert_member(
            &pool,
            "s1",
            "m1",
            Some("2026-07-08T09:00:00Z"),
            "auto",
            now,
        )
        .await
        .unwrap();
        MeetingSeriesRepository::upsert_member(
            &pool,
            "s1",
            "m2",
            Some("2026-07-15T09:00:00Z"),
            "manual",
            now,
        )
        .await
        .unwrap();

        let members = MeetingSeriesRepository::list_members(&pool, "s1")
            .await
            .unwrap();
        assert_eq!(members.len(), 2);
        assert_eq!(members[0].meeting_id, "m1");
        assert_eq!(members[1].meeting_id, "m2");

        // Ledger insert → version 0, content round-trips.
        MeetingSeriesRepository::upsert_ledger(
            &pool,
            "s1",
            Some("# Ledger v0\n- initial note"),
            None,
            Some("m1"),
            now,
        )
        .await
        .unwrap();
        let ledger = MeetingSeriesRepository::get_ledger(&pool, "s1")
            .await
            .unwrap()
            .expect("ledger should exist");
        assert_eq!(ledger.version, 0);
        assert_eq!(
            ledger.ledger_markdown.as_deref(),
            Some("# Ledger v0\n- initial note")
        );

        // Ledger update → version incremented, content replaced (ON CONFLICT behavior).
        MeetingSeriesRepository::upsert_ledger(
            &pool,
            "s1",
            Some("# Ledger v1\n- updated note"),
            None,
            Some("m2"),
            "2026-07-15T13:00:00Z",
        )
        .await
        .unwrap();
        let ledger = MeetingSeriesRepository::get_ledger(&pool, "s1")
            .await
            .unwrap()
            .expect("ledger should exist");
        assert_eq!(ledger.version, 1, "version should bump on update");
        assert_eq!(
            ledger.ledger_markdown.as_deref(),
            Some("# Ledger v1\n- updated note")
        );

        // Template inheritance round-trip.
        MeetingSeriesRepository::set_template(&pool, "s1", Some("one_on_one"), now)
            .await
            .unwrap();
        let series = MeetingSeriesRepository::get_series(&pool, "s1")
            .await
            .unwrap()
            .expect("series should exist");
        assert_eq!(series.template_id.as_deref(), Some("one_on_one"));

        // series_for_meeting resolves back to the series.
        let via_meeting = MeetingSeriesRepository::series_for_meeting(&pool, "m1")
            .await
            .unwrap()
            .expect("m1 should map to a series");
        assert_eq!(via_meeting.id, "s1");
    }

    #[tokio::test]
    async fn heuristic_rescan_clusters_by_title_and_is_idempotent() {
        let pool = mem_pool().await;

        // Two occurrences that normalize to the same title, plus a singleton.
        insert_meeting(&pool, "n1", "Weekly 1:1 - Nia (Jul 8)", "2026-07-08T09:00:00Z").await;
        insert_meeting(&pool, "n2", "Weekly 1:1 - Nia (Jul 15)", "2026-07-15T09:00:00Z").await;
        insert_meeting(&pool, "b1", "Board meeting", "2026-07-10T09:00:00Z").await;

        // First rescan: one new series from the two Nia meetings; singleton excluded.
        let created = detection::rescan_heuristic_series(&pool).await.unwrap();
        assert_eq!(created, 1, "one new heuristic series should be created");

        let series = MeetingSeriesRepository::list_series(&pool).await.unwrap();
        assert_eq!(series.len(), 1, "only the Nia cluster forms a series");
        let nia = &series[0];
        assert!(nia.series_key.is_none(), "heuristic series has no series_key");

        let members = MeetingSeriesRepository::list_members(&pool, &nia.id)
            .await
            .unwrap();
        assert_eq!(members.len(), 2, "Nia series should have two members");

        // The singleton is not in any series.
        assert!(
            MeetingSeriesRepository::series_for_meeting(&pool, "b1")
                .await
                .unwrap()
                .is_none(),
            "singleton 'Board meeting' must not join a series"
        );
        let unseriesed = MeetingSeriesRepository::list_unseriesed_meetings(&pool)
            .await
            .unwrap();
        assert_eq!(unseriesed.len(), 1);
        assert_eq!(unseriesed[0].id, "b1");

        // Second rescan: idempotent, no new series, no duplicate members.
        let created_again = detection::rescan_heuristic_series(&pool).await.unwrap();
        assert_eq!(created_again, 0, "rescan should be idempotent");
        assert_eq!(
            MeetingSeriesRepository::list_series(&pool).await.unwrap().len(),
            1
        );
        assert_eq!(
            MeetingSeriesRepository::list_members(&pool, &nia.id)
                .await
                .unwrap()
                .len(),
            2
        );
    }
}
