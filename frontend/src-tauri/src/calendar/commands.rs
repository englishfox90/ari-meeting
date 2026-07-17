// Calendar feature (F4) — Tauri command surface. Registered as `calendar::commands::*` in
// `lib.rs`'s `generate_handler!` list. See the shared IPC contract (scratchpad
// `calendar-contract.md`) for exact argument/return shapes.

use crate::calendar::eventkit;
use crate::calendar::models::{
    Attendee, CalendarEvent, CalendarEventDetail, CalendarInfo, LinkedMeeting, MeetingCandidate,
};
use crate::calendar::sync::sync_range_core;
use crate::database::repositories::calendar::CalendarRepository;
use crate::database::repositories::summary::SummaryProcessesRepository;
use crate::state::AppState;
use chrono::{Duration, Utc};
use tauri::AppHandle;

/// Manual-link suggestion window: candidate recordings within ±24h of the event's
/// [start, end] window. Manual linking is an explicit user action, so the window is
/// deliberately generous (a recording uploaded hours after a meeting still surfaces).
/// The tighter ±minutes window in `sync.rs` governs *automatic* matching, where false
/// positives matter.
const SUGGEST_SLACK_HOURS: i64 = 24;
const SUGGEST_MAX_CANDIDATES: i64 = 10;

#[tauri::command]
pub async fn calendar_permission_status() -> Result<String, String> {
    Ok(eventkit::permission_status())
}

#[tauri::command]
pub async fn calendar_request_access(app: AppHandle) -> Result<String, String> {
    #[cfg(target_os = "macos")]
    {
        log::info!("📅 calendar_request_access: requesting EventKit full access");
        let (sender, receiver) = tokio::sync::oneshot::channel();
        app.run_on_main_thread(move || {
            eventkit::request_full_access_on_main(sender);
        })
        .map_err(|error| format!("Failed to schedule calendar permission request: {error}"))?;
        let result = tokio::time::timeout(std::time::Duration::from_secs(60), receiver)
            .await
            .map_err(|_| "Timed out waiting for calendar authorization.".to_string())?
            .map_err(|_| "Calendar permission request was cancelled.".to_string())?;
        log::info!("📅 calendar_request_access resolved: {result:?}");
        return result;
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        let (sender, receiver) = tokio::sync::oneshot::channel();
        eventkit::request_full_access_on_main(sender);
        receiver
            .await
            .map_err(|_| "Calendar permission request was cancelled.".to_string())?
    }
}

#[tauri::command]
pub async fn calendar_list_calendars(
    state: tauri::State<'_, AppState>,
) -> Result<Vec<CalendarInfo>, String> {
    let native = eventkit::list_calendars()?;
    let pool = state.db_manager.pool();

    let mut out = Vec::with_capacity(native.len());
    for cal in native {
        let row = CalendarRepository::upsert_calendar_identity(
            pool,
            &cal.id,
            Some(cal.title.as_str()),
            cal.color.as_deref(),
        )
        .await
        .map_err(|e| format!("Failed to upsert calendar {}: {}", cal.id, e))?;

        out.push(CalendarInfo {
            id: row.calendar_id,
            title: row.calendar_title.unwrap_or(cal.title),
            color: row.color,
            selected: row.selected != 0,
        });
    }

    Ok(out)
}

#[tauri::command]
pub async fn calendar_set_selected(
    calendar_ids: Vec<String>,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    CalendarRepository::set_selected_calendars(state.db_manager.pool(), &calendar_ids)
        .await
        .map_err(|e| {
            log::error!("📅 set_selected_calendars failed ({} ids): {e}", calendar_ids.len());
            format!("Failed to set selected calendars: {}", e)
        })
}

#[tauri::command]
pub async fn calendar_sync_events(
    days_past: i64,
    days_future: i64,
    state: tauri::State<'_, AppState>,
) -> Result<usize, String> {
    let pool = state.db_manager.pool();

    let selected_ids = CalendarRepository::selected_calendar_ids(pool)
        .await
        .map_err(|e| format!("Failed to read selected calendars: {}", e))?;

    let now = Utc::now();
    let range_start = now - Duration::days(days_past.max(0));
    let range_end = now + Duration::days(days_future.max(0));

    sync_range_core(pool, &selected_ids, range_start, range_end).await
}

/// Range-based sync (Phase 2): parse RFC3339 bounds directly instead of day offsets from
/// "now" — used by the week-view calendar page to sync exactly the visible week.
#[tauri::command]
pub async fn calendar_sync_range(
    start_iso: String,
    end_iso: String,
    state: tauri::State<'_, AppState>,
) -> Result<usize, String> {
    let pool = state.db_manager.pool();

    let start = chrono::DateTime::parse_from_rfc3339(&start_iso)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| format!("Invalid start_iso: {}", e))?;
    let end = chrono::DateTime::parse_from_rfc3339(&end_iso)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| format!("Invalid end_iso: {}", e))?;

    let selected_ids = CalendarRepository::selected_calendar_ids(pool)
        .await
        .map_err(|e| format!("Failed to read selected calendars: {}", e))?;

    sync_range_core(pool, &selected_ids, start, end).await
}

/// Range-based read (Phase 2): DB-only lookup of events already synced into
/// `calendar_events`, ordered by start time — used to render the week view instantly
/// from local state while a `calendar_sync_range` refresh runs in the background.
#[tauri::command]
pub async fn calendar_get_events_range(
    start_iso: String,
    end_iso: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<CalendarEvent>, String> {
    let start = chrono::DateTime::parse_from_rfc3339(&start_iso)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| format!("Invalid start_iso: {}", e))?;
    let end = chrono::DateTime::parse_from_rfc3339(&end_iso)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| format!("Invalid end_iso: {}", e))?;

    let rows = CalendarRepository::list_events_in_range(state.db_manager.pool(), start, end)
        .await
        .map_err(|e| format!("Failed to load calendar events: {}", e))?;

    Ok(rows.into_iter().map(row_to_calendar_event).collect())
}

fn parse_attendees(json: Option<&str>) -> Vec<Attendee> {
    json.and_then(|s| serde_json::from_str::<Vec<Attendee>>(s).ok())
        .unwrap_or_default()
}

fn row_to_calendar_event(row: crate::database::repositories::calendar::CalendarEventRow) -> CalendarEvent {
    CalendarEvent {
        id: row.id,
        calendar_id: row.calendar_id,
        calendar_title: row.calendar_title,
        title: row.title,
        start_time: row.start_time,
        end_time: row.end_time,
        is_all_day: row.is_all_day != 0,
        location: row.location,
        notes: row.notes,
        organizer: row.organizer,
        attendees: parse_attendees(row.attendees.as_deref()),
        meeting_id: row.meeting_id,
        link_source: row.link_source,
    }
}

#[tauri::command]
pub async fn calendar_get_events(
    days_past: i64,
    days_future: i64,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<CalendarEvent>, String> {
    let now = Utc::now();
    let range_start = now - Duration::days(days_past.max(0));
    let range_end = now + Duration::days(days_future.max(0));

    let rows = CalendarRepository::list_events_in_range(state.db_manager.pool(), range_start, range_end)
        .await
        .map_err(|e| format!("Failed to load calendar events: {}", e))?;

    Ok(rows.into_iter().map(row_to_calendar_event).collect())
}

/// Read-only summary lookup for a linked meeting: does it have a summary, and if so the
/// first ~200 chars of its rendered text (best-effort across summary result shapes).
async fn linked_meeting_summary_snippet(
    pool: &sqlx::SqlitePool,
    meeting_id: &str,
) -> Result<(bool, Option<String>), String> {
    let process = SummaryProcessesRepository::get_summary_data(pool, meeting_id)
        .await
        .map_err(|e| format!("Failed to load summary for meeting {}: {}", meeting_id, e))?;

    let Some(process) = process else {
        return Ok((false, None));
    };
    let Some(result_json) = process.result else {
        return Ok((false, None));
    };

    // The stored result is JSON; extract the most useful human-readable text we can find
    // without assuming a rigid schema (summary templates vary section-by-section).
    let snippet = extract_text_snippet(&result_json, 200);
    Ok((snippet.is_some(), snippet))
}

fn extract_text_snippet(result_json: &str, max_len: usize) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(result_json).ok()?;
    let text = collect_text(&value);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.chars().take(max_len).collect())
}

fn collect_text(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Array(items) => items
            .iter()
            .map(collect_text)
            .collect::<Vec<_>>()
            .join(" "),
        serde_json::Value::Object(map) => map
            .values()
            .map(collect_text)
            .collect::<Vec<_>>()
            .join(" "),
        _ => String::new(),
    }
}

#[tauri::command]
pub async fn calendar_get_event(
    event_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<Option<CalendarEventDetail>, String> {
    let pool = state.db_manager.pool();
    let row = CalendarRepository::get_event(pool, &event_id)
        .await
        .map_err(|e| format!("Failed to load calendar event {}: {}", event_id, e))?;

    let Some(row) = row else {
        return Ok(None);
    };

    let linked_meeting = if let Some(meeting_id) = &row.meeting_id {
        let meeting = crate::database::repositories::meeting::MeetingsRepository::get_meeting_metadata(
            pool,
            meeting_id,
        )
        .await
        .map_err(|e| format!("Failed to load linked meeting {}: {}", meeting_id, e))?;

        match meeting {
            Some(meeting) => {
                let (has_summary, summary_snippet) =
                    linked_meeting_summary_snippet(pool, meeting_id).await?;
                Some(LinkedMeeting {
                    id: meeting.id,
                    title: meeting.title,
                    created_at: meeting.created_at.0.to_rfc3339(),
                    has_summary,
                    summary_snippet,
                })
            }
            None => None,
        }
    } else {
        None
    };

    let attendees = parse_attendees(row.attendees.as_deref());

    Ok(Some(CalendarEventDetail {
        id: row.id,
        calendar_id: row.calendar_id,
        calendar_title: row.calendar_title,
        title: row.title,
        start_time: row.start_time,
        end_time: row.end_time,
        is_all_day: row.is_all_day != 0,
        location: row.location,
        notes: row.notes,
        organizer: row.organizer,
        attendees,
        meeting_id: row.meeting_id,
        link_source: row.link_source,
        linked_meeting,
    }))
}

#[tauri::command]
pub async fn calendar_link_meeting(
    event_id: String,
    meeting_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    let pool = state.db_manager.pool();
    CalendarRepository::set_manual_link(pool, &event_id, &meeting_id)
        .await
        .map_err(|e| format!("Failed to link meeting: {}", e))?;

    // F2 bridge: populate people from this event's attendees now that it has a meeting.
    // Best-effort — a link must still succeed even if attendee import hiccups.
    if let Err(e) = crate::persons::import::import_participants_from_event(pool, &event_id).await {
        log::warn!("Attendee import after linking event {} failed: {}", event_id, e);
    }

    Ok(())
}

#[tauri::command]
pub async fn calendar_unlink_meeting(
    event_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    CalendarRepository::unlink_meeting(state.db_manager.pool(), &event_id)
        .await
        .map_err(|e| format!("Failed to unlink meeting: {}", e))
}

#[tauri::command]
pub async fn calendar_suggest_meetings(
    event_id: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<MeetingCandidate>, String> {
    let pool = state.db_manager.pool();
    let row = CalendarRepository::get_event(pool, &event_id)
        .await
        .map_err(|e| format!("Failed to load calendar event {}: {}", event_id, e))?;

    let Some(row) = row else {
        return Ok(Vec::new());
    };

    let event_start = chrono::DateTime::parse_from_rfc3339(&row.start_time)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| format!("Invalid start_time on event {}: {}", event_id, e))?;
    let event_end = chrono::DateTime::parse_from_rfc3339(&row.end_time)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| format!("Invalid end_time on event {}: {}", event_id, e))?;

    let window_start = event_start - Duration::hours(SUGGEST_SLACK_HOURS);
    let window_end = event_end + Duration::hours(SUGGEST_SLACK_HOURS);

    let candidates = CalendarRepository::suggest_meeting_candidates(
        pool,
        window_start,
        window_end,
        event_start,
        SUGGEST_MAX_CANDIDATES,
    )
    .await
    .map_err(|e| format!("Failed to suggest meetings for event {}: {}", event_id, e))?;

    Ok(candidates
        .into_iter()
        .map(|(id, title, created_at)| MeetingCandidate {
            id,
            title,
            created_at: created_at.to_rfc3339(),
        })
        .collect())
}
