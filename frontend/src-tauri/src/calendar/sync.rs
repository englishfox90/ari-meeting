// Calendar (F4/Phase 2) — reusable sync core + background auto-sync task.
//
// `sync_range_core` is the shared fetch+upsert+auto-match body used by both the
// on-demand `calendar_sync_events`/`calendar_sync_range` commands and the periodic
// background sync spawned from `lib.rs`'s `.setup(...)`. Manual links
// (`link_source = 'manual'`) are never touched by any code path here — see
// `database/repositories/calendar.rs` for the guarantee.

use crate::calendar::eventkit;
use crate::database::repositories::calendar::{CalendarRepository, NewCalendarEvent};
use crate::state::AppState;
use chrono::{DateTime, Duration, Utc};
use sqlx::SqlitePool;

/// Auto-match slack window per the contract: a meeting whose `created_at` falls within
/// [event.start - 15min, event.end + 15min] is eligible for auto-linking.
const AUTO_MATCH_SLACK_MINUTES: i64 = 15;

/// Background sync cadence and rolling window.
const BACKGROUND_SYNC_INITIAL_DELAY_SECS: u64 = 5;
const BACKGROUND_SYNC_INTERVAL_SECS: u64 = 15 * 60;
const BACKGROUND_SYNC_PAST_DAYS: i64 = 30;
const BACKGROUND_SYNC_FUTURE_DAYS: i64 = 90;

/// Fetch events for `selected_ids` in `[start, end]` from EventKit, upsert them (preserving
/// any existing manual/auto link), delete any cached event in the range that no longer
/// comes back from EventKit (deleted/cancelled in Apple Calendar), then run the auto-match
/// pass over the same range. Returns the number of events fetched from EventKit.
pub async fn sync_range_core(
    pool: &SqlitePool,
    selected_ids: &[String],
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> Result<usize, String> {
    let native_events = eventkit::fetch_events(selected_ids, start, end)?;

    for event in &native_events {
        let attendees_json = serde_json::to_string(&event.attendees)
            .map_err(|e| format!("Failed to serialize attendees: {}", e))?;

        let new_event = NewCalendarEvent {
            id: event.id.clone(),
            calendar_id: event.calendar_id.clone(),
            calendar_title: event.calendar_title.clone(),
            title: event.title.clone(),
            start_time: event.start_time,
            end_time: event.end_time,
            is_all_day: event.is_all_day,
            location: event.location.clone(),
            notes: event.notes.clone(),
            organizer: event.organizer.clone(),
            attendees_json,
            series_key: event.series_key.clone(),
            has_recurrence: event.has_recurrence,
            occurrence_date: event.occurrence_date.clone(),
            is_detached: event.is_detached,
        };

        CalendarRepository::upsert_event(pool, &new_event)
            .await
            .map_err(|e| format!("Failed to upsert calendar event {}: {}", event.id, e))?;
    }

    let fetched_ids: Vec<String> = native_events.iter().map(|e| e.id.clone()).collect();
    CalendarRepository::delete_stale_events_in_range(pool, start, end, &fetched_ids)
        .await
        .map_err(|e| format!("Failed to delete stale calendar events: {}", e))?;

    run_auto_match(pool, start, end).await?;

    // F9 series detection: now that meeting_id links exist for this range, group recurring
    // linked events into meeting_series. Best-effort — never break sync on a detection error.
    detect_series_in_range(pool, start, end).await;

    // F2 reconcile: for every linked event in range, import its attendees as people and
    // link them as participants. Idempotent (stub upsert + INSERT OR IGNORE), so this both
    // populates newly auto-matched events and self-heals events linked before this bridge
    // existed. Best-effort — a hiccup here must never fail the sync.
    reconcile_participants(pool, start, end).await;

    Ok(native_events.len())
}

/// Run F9 series detection for every linked event in [start, end]. Best-effort; logs and
/// continues on any per-event failure so a detection hiccup never breaks the sync.
async fn detect_series_in_range(pool: &SqlitePool, start: DateTime<Utc>, end: DateTime<Utc>) {
    let events = match CalendarRepository::list_events_in_range(pool, start, end).await {
        Ok(events) => events,
        Err(e) => {
            log::warn!("Series detection: failed to list events: {}", e);
            return;
        }
    };

    for event in events {
        if let Err(e) =
            crate::meeting_series::detection::detect_series_for_event(pool, &event).await
        {
            log::warn!(
                "Series detection: failed for event {}: {}",
                event.id,
                e
            );
        }
    }
}

/// Import attendees→people for all linked events in [start, end]. Best-effort; logs and
/// continues on any per-event failure.
async fn reconcile_participants(pool: &SqlitePool, start: DateTime<Utc>, end: DateTime<Utc>) {
    let events = match CalendarRepository::list_events_in_range(pool, start, end).await {
        Ok(events) => events,
        Err(e) => {
            log::warn!("Participant reconcile: failed to list events: {}", e);
            return;
        }
    };

    for event in events {
        if event.meeting_id.is_none() {
            continue;
        }
        if let Err(e) = crate::persons::import::import_participants_from_event(pool, &event.id).await
        {
            log::warn!(
                "Participant reconcile: import failed for event {}: {}",
                event.id,
                e
            );
        }
    }
}

/// Auto-match rule (per contract): for each event whose link is not manual, find a
/// meeting whose `created_at` falls within [event.start - 15min, event.end + 15min],
/// choosing the one closest to `event.start`. Manual links are never touched.
async fn run_auto_match(
    pool: &SqlitePool,
    range_start: DateTime<Utc>,
    range_end: DateTime<Utc>,
) -> Result<(), String> {
    let candidates = CalendarRepository::list_auto_matchable_events(pool, range_start, range_end)
        .await
        .map_err(|e| format!("Failed to list auto-matchable events: {}", e))?;

    for event in candidates {
        let event_start = match chrono::DateTime::parse_from_rfc3339(&event.start_time) {
            Ok(dt) => dt.with_timezone(&Utc),
            Err(_) => continue,
        };
        let event_end = match chrono::DateTime::parse_from_rfc3339(&event.end_time) {
            Ok(dt) => dt.with_timezone(&Utc),
            Err(_) => continue,
        };

        let window_start = event_start - Duration::minutes(AUTO_MATCH_SLACK_MINUTES);
        let window_end = event_end + Duration::minutes(AUTO_MATCH_SLACK_MINUTES);

        if let Some(meeting_id) = CalendarRepository::find_closest_meeting_in_window(
            pool,
            window_start,
            window_end,
            event_start,
        )
        .await
        .map_err(|e| format!("Auto-match lookup failed for event {}: {}", event.id, e))?
        {
            CalendarRepository::set_auto_link(pool, &event.id, &meeting_id)
                .await
                .map_err(|e| format!("Auto-match link failed for event {}: {}", event.id, e))?;
        }
    }

    Ok(())
}

/// Spawn the periodic background sync loop. Fire-and-forget: never panics, logs and
/// continues on any error. Only runs the actual EventKit fetch on macOS; on other
/// platforms it's a no-op loop that never triggers a sync (keeps `cargo check` clean
/// cross-platform without duplicating the `#[cfg]` gate at every call site).
pub fn spawn_background_sync(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(BACKGROUND_SYNC_INITIAL_DELAY_SECS))
            .await;

        loop {
            run_background_sync_once(&app).await;
            tokio::time::sleep(std::time::Duration::from_secs(BACKGROUND_SYNC_INTERVAL_SECS)).await;
        }
    });
}

#[cfg(target_os = "macos")]
async fn run_background_sync_once(app: &tauri::AppHandle) {
    use tauri::{Emitter, Manager};

    let status = eventkit::permission_status();
    if status != "authorized" && status != "fullAccess" {
        log::info!("📅 Background sync skipped: calendar permission is '{status}'");
        return;
    }

    let state = app.state::<AppState>();
    let pool = state.db_manager.pool();

    let selected_ids = match CalendarRepository::selected_calendar_ids(pool).await {
        Ok(ids) => ids,
        Err(e) => {
            log::error!("📅 Background sync: failed to read selected calendars: {e}");
            return;
        }
    };

    if selected_ids.is_empty() {
        log::info!("📅 Background sync skipped: no calendars selected");
        return;
    }

    let now = Utc::now();
    let start = now - Duration::days(BACKGROUND_SYNC_PAST_DAYS);
    let end = now + Duration::days(BACKGROUND_SYNC_FUTURE_DAYS);

    match sync_range_core(pool, &selected_ids, start, end).await {
        Ok(count) => {
            log::info!("📅 Background sync complete: {count} events synced");
            if let Err(e) = app.emit("calendar-sync-updated", serde_json::json!({ "count": count }))
            {
                log::error!("📅 Failed to emit calendar-sync-updated: {e}");
            }
        }
        Err(e) => {
            log::error!("📅 Background sync failed: {e}");
        }
    }
}

#[cfg(not(target_os = "macos"))]
async fn run_background_sync_once(_app: &tauri::AppHandle) {
    // Calendar/EventKit is macOS-only; nothing to do off-platform.
}
