// Calendar (F4) repository — additive DB access layer for calendar_events /
// calendar_sync_settings. Follows the sanctioned pattern: unit struct, `pool: &SqlitePool`
// first, runtime sqlx query/query_as (no compile-time macros), `Result<_, sqlx::Error>`.
//
// Manual links are sacred: any upsert or auto-match pass must never clobber a row whose
// `link_source = 'manual'`.

use chrono::{DateTime, Utc};
use sqlx::{FromRow, Row, SqlitePool};

#[derive(Debug, Clone, FromRow)]
pub struct CalendarEventRow {
    pub id: String,
    pub calendar_id: String,
    pub calendar_title: Option<String>,
    pub title: String,
    pub start_time: String,
    pub end_time: String,
    pub is_all_day: i64,
    pub location: Option<String>,
    pub notes: Option<String>,
    pub organizer: Option<String>,
    pub attendees: Option<String>,
    pub synced_at: String,
    pub meeting_id: Option<String>,
    pub link_source: Option<String>,
    // ---- Recurrence signals (F9 Meeting Series) ----
    pub series_key: Option<String>,
    pub has_recurrence: i64,
    pub occurrence_date: Option<String>,
    pub is_detached: i64,
}

#[derive(Debug, Clone, FromRow)]
pub struct CalendarSyncSettingRow {
    pub calendar_id: String,
    pub calendar_title: Option<String>,
    pub color: Option<String>,
    pub selected: i64,
}

/// Minimal shape needed to upsert a synced event; native (EventKit) values in, DB row out.
#[derive(Debug, Clone)]
pub struct NewCalendarEvent {
    pub id: String,
    pub calendar_id: String,
    pub calendar_title: Option<String>,
    pub title: String,
    pub start_time: DateTime<Utc>,
    pub end_time: DateTime<Utc>,
    pub is_all_day: bool,
    pub location: Option<String>,
    pub notes: Option<String>,
    pub organizer: Option<String>,
    /// Pre-serialized JSON array of {"name":..,"email":..}.
    pub attendees_json: String,
    // ---- Recurrence signals (F9 Meeting Series) ----
    pub series_key: Option<String>,
    pub has_recurrence: bool,
    pub occurrence_date: Option<String>,
    pub is_detached: bool,
}

pub struct CalendarRepository;

impl CalendarRepository {
    // ===== calendar_sync_settings =====

    /// Upsert a calendar's identity (title/color) while preserving any existing `selected`
    /// choice the user already made. Returns the row as currently stored.
    pub async fn upsert_calendar_identity(
        pool: &SqlitePool,
        calendar_id: &str,
        calendar_title: Option<&str>,
        color: Option<&str>,
    ) -> Result<CalendarSyncSettingRow, sqlx::Error> {
        sqlx::query(
            r#"
            INSERT INTO calendar_sync_settings (calendar_id, calendar_title, color, selected)
            VALUES (?, ?, ?, 0)
            ON CONFLICT(calendar_id) DO UPDATE SET
                calendar_title = excluded.calendar_title,
                color = excluded.color
            "#,
        )
        .bind(calendar_id)
        .bind(calendar_title)
        .bind(color)
        .execute(pool)
        .await?;

        let row = sqlx::query_as::<_, CalendarSyncSettingRow>(
            "SELECT * FROM calendar_sync_settings WHERE calendar_id = ?",
        )
        .bind(calendar_id)
        .fetch_one(pool)
        .await?;

        Ok(row)
    }

    pub async fn list_sync_settings(
        pool: &SqlitePool,
    ) -> Result<Vec<CalendarSyncSettingRow>, sqlx::Error> {
        sqlx::query_as::<_, CalendarSyncSettingRow>(
            "SELECT * FROM calendar_sync_settings ORDER BY calendar_title ASC",
        )
        .fetch_all(pool)
        .await
    }

    pub async fn set_selected_calendars(
        pool: &SqlitePool,
        calendar_ids: &[String],
    ) -> Result<(), sqlx::Error> {
        let mut tx = pool.begin().await?;

        sqlx::query("UPDATE calendar_sync_settings SET selected = 0")
            .execute(&mut *tx)
            .await?;

        for id in calendar_ids {
            sqlx::query("UPDATE calendar_sync_settings SET selected = 1 WHERE calendar_id = ?")
                .bind(id)
                .execute(&mut *tx)
                .await?;
        }

        tx.commit().await?;
        Ok(())
    }

    pub async fn selected_calendar_ids(pool: &SqlitePool) -> Result<Vec<String>, sqlx::Error> {
        let rows = sqlx::query("SELECT calendar_id FROM calendar_sync_settings WHERE selected = 1")
            .fetch_all(pool)
            .await?;
        Ok(rows.into_iter().map(|r| r.get("calendar_id")).collect())
    }

    // ===== calendar_events =====

    /// Upsert a synced event. Preserves an existing `meeting_id`/`link_source` when the
    /// existing row is manually linked — auto-sync must never clobber a manual link.
    pub async fn upsert_event(pool: &SqlitePool, event: &NewCalendarEvent) -> Result<(), sqlx::Error> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            INSERT INTO calendar_events (
                id, calendar_id, calendar_title, title, start_time, end_time,
                is_all_day, location, notes, organizer, attendees, synced_at,
                meeting_id, link_source,
                series_key, has_recurrence, occurrence_date, is_detached
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                calendar_id = excluded.calendar_id,
                calendar_title = excluded.calendar_title,
                title = excluded.title,
                start_time = excluded.start_time,
                end_time = excluded.end_time,
                is_all_day = excluded.is_all_day,
                location = excluded.location,
                notes = excluded.notes,
                organizer = excluded.organizer,
                attendees = excluded.attendees,
                synced_at = excluded.synced_at,
                -- Recurrence signals (F9) DO refresh on re-sync (they describe the event
                -- itself, not a user link). Link columns stay untouched below.
                series_key = excluded.series_key,
                has_recurrence = excluded.has_recurrence,
                occurrence_date = excluded.occurrence_date,
                is_detached = excluded.is_detached
                -- meeting_id / link_source deliberately NOT touched here: re-syncing an
                -- event must never clobber an existing manual OR auto link. Auto-match
                -- (set_auto_link) and manual linking (set_manual_link/unlink_meeting) are
                -- the only paths allowed to change them.
            "#,
        )
        .bind(&event.id)
        .bind(&event.calendar_id)
        .bind(&event.calendar_title)
        .bind(&event.title)
        .bind(event.start_time.to_rfc3339())
        .bind(event.end_time.to_rfc3339())
        .bind(event.is_all_day as i64)
        .bind(&event.location)
        .bind(&event.notes)
        .bind(&event.organizer)
        .bind(&event.attendees_json)
        .bind(&now)
        .bind(&event.series_key)
        .bind(event.has_recurrence as i64)
        .bind(&event.occurrence_date)
        .bind(event.is_detached as i64)
        .execute(pool)
        .await?;

        Ok(())
    }

    /// Delete cached events starting in [range_start, range_end] whose id is not in
    /// `keep_ids` — i.e. events that no longer exist in EventKit (deleted/cancelled in
    /// Apple Calendar since the last sync). Scoped strictly to the synced range so events
    /// outside it are never touched. `calendar_events.meeting_id` has `ON DELETE SET NULL`
    /// on the `meetings` FK side is irrelevant here (this deletes the calendar_events row,
    /// not the meeting) — any linked recording is preserved regardless of link_source.
    pub async fn delete_stale_events_in_range(
        pool: &SqlitePool,
        range_start: DateTime<Utc>,
        range_end: DateTime<Utc>,
        keep_ids: &[String],
    ) -> Result<u64, sqlx::Error> {
        if keep_ids.is_empty() {
            let result = sqlx::query(
                "DELETE FROM calendar_events WHERE start_time >= ? AND start_time <= ?",
            )
            .bind(range_start.to_rfc3339())
            .bind(range_end.to_rfc3339())
            .execute(pool)
            .await?;
            return Ok(result.rows_affected());
        }

        let placeholders = keep_ids.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
        let sql = format!(
            "DELETE FROM calendar_events WHERE start_time >= ? AND start_time <= ? AND id NOT IN ({})",
            placeholders
        );
        let mut query = sqlx::query(&sql)
            .bind(range_start.to_rfc3339())
            .bind(range_end.to_rfc3339());
        for id in keep_ids {
            query = query.bind(id);
        }
        let result = query.execute(pool).await?;
        Ok(result.rows_affected())
    }

    pub async fn list_events_in_range(
        pool: &SqlitePool,
        range_start: DateTime<Utc>,
        range_end: DateTime<Utc>,
    ) -> Result<Vec<CalendarEventRow>, sqlx::Error> {
        sqlx::query_as::<_, CalendarEventRow>(
            "SELECT * FROM calendar_events WHERE start_time >= ? AND start_time <= ? ORDER BY start_time ASC",
        )
        .bind(range_start.to_rfc3339())
        .bind(range_end.to_rfc3339())
        .fetch_all(pool)
        .await
    }

    /// Events whose link is not manual — the candidate set for auto-matching.
    pub async fn list_auto_matchable_events(
        pool: &SqlitePool,
        range_start: DateTime<Utc>,
        range_end: DateTime<Utc>,
    ) -> Result<Vec<CalendarEventRow>, sqlx::Error> {
        sqlx::query_as::<_, CalendarEventRow>(
            r#"
            SELECT * FROM calendar_events
            WHERE start_time >= ? AND start_time <= ?
              AND (link_source IS NULL OR link_source != 'manual')
            ORDER BY start_time ASC
            "#,
        )
        .bind(range_start.to_rfc3339())
        .bind(range_end.to_rfc3339())
        .fetch_all(pool)
        .await
    }

    pub async fn get_event(
        pool: &SqlitePool,
        event_id: &str,
    ) -> Result<Option<CalendarEventRow>, sqlx::Error> {
        sqlx::query_as::<_, CalendarEventRow>("SELECT * FROM calendar_events WHERE id = ?")
            .bind(event_id)
            .fetch_optional(pool)
            .await
    }

    /// The (at most one) calendar event linked to `meeting_id`, with attendees parsed —
    /// used to inject the authoritative event title/notes/attendee roster into the F3
    /// summary context so the summarizer doesn't misattribute speakers. Uses the
    /// `idx_calendar_events_meeting` index. A meeting should only ever be linked to one
    /// event (`find_closest_meeting_in_window` now enforces exclusivity going forward),
    /// but as a defensive backstop against stale double-links from before that fix, break
    /// ties deterministically by picking the event whose start_time is closest to the
    /// meeting's `created_at` rather than an arbitrary row.
    pub async fn get_event_by_meeting_id(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<Option<crate::calendar::models::CalendarEvent>, sqlx::Error> {
        let row = sqlx::query_as::<_, CalendarEventRow>(
            r#"
            SELECT ce.* FROM calendar_events ce
            JOIN meetings m ON m.id = ce.meeting_id
            WHERE ce.meeting_id = ?
            ORDER BY ABS(CAST((julianday(ce.start_time) - julianday(m.created_at)) * 86400.0 AS INTEGER)) ASC
            LIMIT 1
            "#,
        )
        .bind(meeting_id)
        .fetch_optional(pool)
        .await?;

        Ok(row.map(|r| {
            let attendees = r
                .attendees
                .as_deref()
                .and_then(|s| serde_json::from_str::<Vec<crate::calendar::models::Attendee>>(s).ok())
                .unwrap_or_default();
            crate::calendar::models::CalendarEvent {
                id: r.id,
                calendar_id: r.calendar_id,
                calendar_title: r.calendar_title,
                title: r.title,
                start_time: r.start_time,
                end_time: r.end_time,
                is_all_day: r.is_all_day != 0,
                location: r.location,
                notes: r.notes,
                organizer: r.organizer,
                attendees,
                meeting_id: r.meeting_id,
                link_source: r.link_source,
            }
        }))
    }

    /// Set an auto-match link. Never overwrites an existing manual link.
    pub async fn set_auto_link(
        pool: &SqlitePool,
        event_id: &str,
        meeting_id: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            r#"
            UPDATE calendar_events
            SET meeting_id = ?, link_source = 'auto'
            WHERE id = ? AND (link_source IS NULL OR link_source != 'manual')
            "#,
        )
        .bind(meeting_id)
        .bind(event_id)
        .execute(pool)
        .await?;
        Ok(())
    }

    /// Links `event_id` to `meeting_id` as a manual (user-chosen) link. A meeting may only
    /// ever be linked to one event, so any other event currently holding this meeting_id is
    /// released first — otherwise this insert would violate `idx_calendar_events_meeting_unique`.
    pub async fn set_manual_link(
        pool: &SqlitePool,
        event_id: &str,
        meeting_id: &str,
    ) -> Result<(), sqlx::Error> {
        let mut tx = pool.begin().await?;
        sqlx::query(
            "UPDATE calendar_events SET meeting_id = NULL, link_source = NULL WHERE meeting_id = ? AND id != ?",
        )
        .bind(meeting_id)
        .bind(event_id)
        .execute(&mut *tx)
        .await?;
        sqlx::query("UPDATE calendar_events SET meeting_id = ?, link_source = 'manual' WHERE id = ?")
            .bind(meeting_id)
            .bind(event_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn unlink_meeting(pool: &SqlitePool, event_id: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE calendar_events SET meeting_id = NULL, link_source = NULL WHERE id = ?")
            .bind(event_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    /// Candidate recordings for manual linking to `event`: meetings whose `created_at`
    /// falls within ±`slack` of the event's [start_time, end_time] window, closest first.
    pub async fn suggest_meeting_candidates(
        pool: &SqlitePool,
        window_start: DateTime<Utc>,
        window_end: DateTime<Utc>,
        anchor: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<(String, String, DateTime<Utc>)>, sqlx::Error> {
        let rows = sqlx::query(
            r#"
            SELECT id, title, created_at
            FROM meetings
            WHERE created_at >= ? AND created_at <= ?
            ORDER BY ABS(CAST((julianday(created_at) - julianday(?)) * 86400.0 AS INTEGER)) ASC
            LIMIT ?
            "#,
        )
        .bind(window_start.to_rfc3339())
        .bind(window_end.to_rfc3339())
        .bind(anchor.to_rfc3339())
        .bind(limit)
        .fetch_all(pool)
        .await?;

        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let id: String = row.get("id");
            let title: String = row.get("title");
            let created_at: crate::database::models::DateTimeUtc = row.get("created_at");
            out.push((id, title, created_at.0));
        }
        Ok(out)
    }

    /// Closest meeting whose `created_at` falls within [window_start, window_end], for
    /// auto-matching. Excludes meetings already claimed by another calendar event so two
    /// overlapping events (e.g. back-to-back meetings whose ±15min slack windows both cover
    /// the same recording) can't both auto-link to the same meeting. Returns `None` if none
    /// found.
    pub async fn find_closest_meeting_in_window(
        pool: &SqlitePool,
        window_start: DateTime<Utc>,
        window_end: DateTime<Utc>,
        anchor: DateTime<Utc>,
    ) -> Result<Option<String>, sqlx::Error> {
        let row = sqlx::query(
            r#"
            SELECT id
            FROM meetings
            WHERE created_at >= ? AND created_at <= ?
              AND id NOT IN (SELECT meeting_id FROM calendar_events WHERE meeting_id IS NOT NULL)
            ORDER BY ABS(CAST((julianday(created_at) - julianday(?)) * 86400.0 AS INTEGER)) ASC
            LIMIT 1
            "#,
        )
        .bind(window_start.to_rfc3339())
        .bind(window_end.to_rfc3339())
        .bind(anchor.to_rfc3339())
        .fetch_optional(pool)
        .await?;

        Ok(row.map(|r| r.get("id")))
    }

    /// Realign an imported meeting's `created_at` to its true meeting time.
    ///
    /// Imported meetings are inserted with `created_at = import time` (see
    /// `audio/import.rs`), which places them outside the calendar window of the event
    /// they belong to, so neither manual suggestion nor auto-match can find them. This
    /// rewrites `created_at` to the real meeting time (derived from the source audio
    /// file), which is the field both matching paths key on. Returns rows affected (0 if
    /// the meeting id no longer exists). Binds the `DateTime<Utc>` directly so the stored
    /// format is identical to every other meeting row.
    pub async fn realign_meeting_created_at(
        pool: &SqlitePool,
        meeting_id: &str,
        created_at: DateTime<Utc>,
    ) -> Result<u64, sqlx::Error> {
        let result = sqlx::query("UPDATE meetings SET created_at = ? WHERE id = ?")
            .bind(created_at)
            .bind(meeting_id)
            .execute(pool)
            .await?;
        Ok(result.rows_affected())
    }
}
