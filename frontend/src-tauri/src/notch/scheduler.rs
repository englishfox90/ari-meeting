//! WS-D — the upcoming-meeting reminder scheduler that completes F5.
//!
//! A background loop ticks every [`TICK_INTERVAL`] and, for each configured lead
//! time (from the notification settings' `meeting_reminder_minutes`, default
//! `[15, 5]`), fires exactly once per `(event_id, lead)`:
//!   1. pushes a [`NotchInbound::UpcomingMeeting`] to the notch sidecar (the
//!      prompt-to-record surface), via [`crate::notch::bridge::push_inbound`], and
//!   2. shows a system meeting-reminder notification through the existing
//!      [`NotificationManager::show_meeting_reminder`] path (respecting its own
//!      consent/DND/settings gates) — this scheduler is that method's FIRST caller,
//!      wiring the previously-orphaned F5 plumbing.
//!
//! It dismisses a prompt (`DismissUpcoming`) once the event's start has passed by
//! more than [`LINGER_AFTER_START`] (a grace window so a running-late user still
//! sees the prompt-to-record right after the meeting was due to begin), the event
//! gains a `meeting_id` (it got recorded — the time-window auto-matcher in
//! `calendar/sync.rs` links a notch-started recording with no extra plumbing), or
//! the event disappears from the range (cancelled).
//!
//! ## Design: pure decision core + thin glue (mirrors WS-B `bridge.rs`)
//!
//! [`due_events`] is a side-effect-free function that decides which
//! `(event_id, lead)` pairs to fire and which `event_id`s to dismiss. It is
//! unit-tested WITHOUT tokio, a DB, or a Tauri runtime. The tokio loop, the DB
//! read, and the bridge/notification calls are the thin, untested glue around it.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Duration as ChronoDuration, Utc};

use crate::database::repositories::calendar::{CalendarEventRow, CalendarRepository};
use crate::notch::protocol::NotchInbound;
use crate::notifications::commands::NotificationManagerState;

// ============================================================================
// Tunables
// ============================================================================

/// How often the scheduler loop wakes to evaluate upcoming events.
const TICK_INTERVAL: std::time::Duration = std::time::Duration::from_secs(30);

/// Let the DB + notification manager finish startup before the first tick.
const INITIAL_DELAY: std::time::Duration = std::time::Duration::from_secs(8);

/// A fire is admitted when `now` is within this tolerance of `event.start - lead`.
/// Must exceed half the tick interval so at least one tick lands inside the
/// window; keeping it well above avoids a missed fire, while staying small enough
/// that a late app-start does not resurrect a long-past lead (e.g. firing a
/// "15 minutes" reminder when only 8 minutes remain).
const FIRE_TOLERANCE: ChronoDuration = ChronoDuration::seconds(45);

/// Extra minutes beyond the largest lead to include in the DB range query, so an
/// event sitting just past a lead boundary is still considered.
const RANGE_SLACK_MINUTES: i64 = 2;

/// How long the upcoming-meeting prompt lingers after the scheduled start before
/// it is auto-dismissed. Gives a running-late user a window to still hit
/// record — we don't yank the prompt the instant the meeting was due to begin.
///
/// Kept in sync with the in-app "From your calendar" panel's `LATE_JOIN_MINUTES`
/// (`frontend/src/components/recording/UpcomingMeetingsPanel.tsx`) so both
/// late-join surfaces offer the same window.
const LINGER_AFTER_START: ChronoDuration = ChronoDuration::minutes(30);

// ============================================================================
// Pure decision core
// ============================================================================

/// A minimal, pure projection of a calendar event for scheduling decisions.
#[derive(Debug, Clone, PartialEq)]
pub struct SchedEvent {
    pub id: String,
    pub start: DateTime<Utc>,
    pub has_meeting: bool,
    pub title: String,
    pub attendee_count: u32,
}

/// The decisions produced by one tick: which `(event_id, lead_minutes)` pairs to
/// fire, and which `event_id`s to dismiss.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Reminders {
    pub fire: Vec<(String, i64)>,
    pub dismiss: Vec<String>,
}

/// Pure scheduling decision. No I/O, no clock — `now` is injected.
///
/// Fire rule: for an event that has NOT started and does NOT already have a
/// recording, fire `(id, lead)` when `|now - (start - lead)| <= FIRE_TOLERANCE`
/// and it has not already fired.
///
/// Dismiss rule: an event that was fired at least once is dismissed (once) when
/// its start has passed by more than [`LINGER_AFTER_START`] OR it gained a
/// recording. An event that was previously fired but is absent from `events`
/// (cancelled / rolled out of range) is also dismissed. Already-dismissed events
/// are never re-emitted.
pub fn due_events(
    now: DateTime<Utc>,
    events: &[SchedEvent],
    leads: &[i64],
    fired: &HashSet<(String, i64)>,
    dismissed: &HashSet<String>,
) -> Reminders {
    let mut out = Reminders::default();

    // Set of event ids present in the current range this tick.
    let present: HashSet<&str> = events.iter().map(|e| e.id.as_str()).collect();

    for event in events {
        let already_started = now >= event.start;
        // The prompt lingers past the scheduled start; it only expires once the
        // grace window has also elapsed (so a late user can still hit record).
        let linger_expired = now >= event.start + LINGER_AFTER_START;

        // ---- Dismissals for present events ----
        let was_fired = fired.iter().any(|(id, _)| id == &event.id);
        if was_fired
            && !dismissed.contains(&event.id)
            && (linger_expired || event.has_meeting)
        {
            out.dismiss.push(event.id.clone());
            // A dismissed event should not also fire this tick.
            continue;
        }

        // ---- Fires ----
        if event.has_meeting || already_started {
            continue;
        }
        for &lead in leads {
            let fire_time = event.start - ChronoDuration::minutes(lead);
            let delta = (now - fire_time).abs();
            if delta <= FIRE_TOLERANCE && !fired.contains(&(event.id.clone(), lead)) {
                out.fire.push((event.id.clone(), lead));
            }
        }
    }

    // ---- Dismiss events that were fired but have vanished from the range ----
    for (id, _lead) in fired {
        if !present.contains(id.as_str()) && !dismissed.contains(id) {
            // Avoid pushing the same id twice (multiple leads may have fired).
            if !out.dismiss.iter().any(|d| d == id) {
                out.dismiss.push(id.clone());
            }
        }
    }

    out
}

// ============================================================================
// Row → SchedEvent mapping (thin, glue-side)
// ============================================================================

/// Count attendees from the row's JSON array; `0` if absent/unparseable.
fn attendee_count(row: &CalendarEventRow) -> u32 {
    row.attendees
        .as_deref()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
        .and_then(|v| v.as_array().map(|a| a.len() as u32))
        .unwrap_or(0)
}

/// Map a DB row into a [`SchedEvent`]; `None` if `start_time` can't be parsed.
fn row_to_sched(row: &CalendarEventRow) -> Option<SchedEvent> {
    let start = DateTime::parse_from_rfc3339(&row.start_time)
        .ok()?
        .with_timezone(&Utc);
    Some(SchedEvent {
        id: row.id.clone(),
        start,
        has_meeting: row.meeting_id.is_some(),
        title: row.title.clone(),
        attendee_count: attendee_count(row),
    })
}

// ============================================================================
// Live glue: the background loop
// ============================================================================

/// Spawn the reminder scheduler loop. Fire-and-forget; never panics, logs and
/// continues on any error. Reading cached calendar events is a plain DB read, so
/// this runs on every platform (the EventKit *fetch* that populates the cache is
/// the macOS-only part, and lives in `calendar/sync.rs`).
pub fn spawn_scheduler(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(INITIAL_DELAY).await;

        // De-dupe state, owned by this single task (no shared-state concurrency).
        let mut fired: HashSet<(String, i64)> = HashSet::new();
        let mut dismissed: HashSet<String> = HashSet::new();

        loop {
            tick(&app, &mut fired, &mut dismissed).await;
            tokio::time::sleep(TICK_INTERVAL).await;
        }
    });
}

/// One scheduler evaluation. Reads events, runs the pure decision core, then
/// performs the side effects (notch push + system notification).
async fn tick(
    app: &tauri::AppHandle,
    fired: &mut HashSet<(String, i64)>,
    dismissed: &mut HashSet<String>,
) {
    use tauri::Manager;

    // Leads come from the notification settings so the user's configured reminder
    // times drive both surfaces. Fall back to the documented default if the
    // manager hasn't initialized yet.
    let leads = read_leads(app).await;
    if leads.is_empty() {
        return;
    }
    let max_lead = leads.iter().copied().max().unwrap_or(0);

    let now = Utc::now();
    let range_end = now + ChronoDuration::minutes(max_lead + RANGE_SLACK_MINUTES);
    // Reach back past `now` by the linger window so an event that already started
    // is still returned — otherwise it would vanish from the range and be
    // dismissed immediately at start, defeating the grace period.
    let range_start = now - LINGER_AFTER_START;

    // Load candidate rows from the DB (same pool-access pattern as calendar sync).
    let rows = {
        let db = match app.state::<std::sync::Arc<crate::engine::Engine>>().db().await {
            Ok(db) => db,
            Err(e) => {
                log::warn!("notch scheduler: DB not ready: {e}");
                return;
            }
        };
        let pool = db.pool();
        match CalendarRepository::list_events_in_range(pool, range_start, range_end).await {
            Ok(rows) => rows,
            Err(e) => {
                log::warn!("notch scheduler: failed to list events: {e}");
                return;
            }
        }
    };

    let events: Vec<SchedEvent> = rows.iter().filter_map(row_to_sched).collect();
    // Keep a lookup for building the fire payloads.
    let by_id: HashMap<&str, &SchedEvent> = events.iter().map(|e| (e.id.as_str(), e)).collect();

    let decision = due_events(now, &events, &leads, fired, dismissed);

    if decision.fire.is_empty() && decision.dismiss.is_empty() {
        return;
    }

    // Is a recording already active? Used only to annotate the notch prompt.
    let already_recording = crate::audio::recording_commands::get_recording_state()
        .await
        .get("is_recording")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // ---- Fires ----
    for (event_id, lead) in &decision.fire {
        let Some(ev) = by_id.get(event_id.as_str()) else {
            continue;
        };
        let starts_in_seconds = (ev.start - now).num_seconds().max(0) as u64;

        // 1) Notch prompt-to-record surface (also caches title for the linkage).
        crate::notch::bridge::push_inbound(NotchInbound::UpcomingMeeting {
            event_id: event_id.clone(),
            title: ev.title.clone(),
            starts_in_seconds,
            start_iso: ev.start.to_rfc3339(),
            attendee_count: ev.attendee_count,
            already_recording,
        });

        // 2) System notification (respects the manager's consent/DND/settings gates).
        show_reminder(app, *lead as u64, ev.title.clone()).await;

        fired.insert((event_id.clone(), *lead));
        log::info!(
            "notch scheduler: fired T-{lead} reminder for event {event_id} ('{}')",
            ev.title
        );
    }

    // ---- Dismissals ----
    for event_id in &decision.dismiss {
        crate::notch::bridge::push_inbound(NotchInbound::DismissUpcoming {
            event_id: event_id.clone(),
        });
        dismissed.insert(event_id.clone());
        log::debug!("notch scheduler: dismissed upcoming prompt for event {event_id}");
    }
}

/// Read `meeting_reminder_minutes` from the notification settings; default to
/// `[15, 5]` if the manager is not yet initialized.
async fn read_leads(app: &tauri::AppHandle) -> Vec<i64> {
    use tauri::Manager;
    let state = app.state::<NotificationManagerState<tauri::Wry>>();
    let guard = state.read().await;
    match guard.as_ref() {
        Some(mgr) => mgr
            .get_settings()
            .await
            .notification_preferences
            .meeting_reminder_minutes
            .iter()
            .map(|&m| m as i64)
            .collect(),
        None => vec![15, 5],
    }
}

/// Best-effort system meeting-reminder notification, gated by the manager itself.
async fn show_reminder(app: &tauri::AppHandle, minutes: u64, title: String) {
    use tauri::Manager;
    let state = app.state::<NotificationManagerState<tauri::Wry>>();
    let guard = state.read().await;
    if let Some(mgr) = guard.as_ref() {
        if let Err(e) = mgr.show_meeting_reminder(minutes, Some(title)).await {
            log::warn!("notch scheduler: show_meeting_reminder failed: {e}");
        }
    }
}

// ============================================================================
// Unit tests — pure decision core only (no tokio / DB / Tauri)
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(id: &str, start: DateTime<Utc>, has_meeting: bool) -> SchedEvent {
        SchedEvent {
            id: id.to_string(),
            start,
            has_meeting,
            title: format!("Meeting {id}"),
            attendee_count: 3,
        }
    }

    fn base() -> DateTime<Utc> {
        // A fixed anchor "meeting start".
        DateTime::parse_from_rfc3339("2026-07-14T10:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    const LEADS: [i64; 2] = [15, 5];

    #[test]
    fn fires_exactly_at_t_minus_15() {
        let start = base();
        let now = start - ChronoDuration::minutes(15);
        let events = [ev("E1", start, false)];
        let r = due_events(now, &events, &LEADS, &HashSet::new(), &HashSet::new());
        assert_eq!(r.fire, vec![("E1".to_string(), 15)]);
        assert!(r.dismiss.is_empty());
    }

    #[test]
    fn fires_exactly_at_t_minus_5() {
        let start = base();
        let now = start - ChronoDuration::minutes(5);
        let events = [ev("E1", start, false)];
        let r = due_events(now, &events, &LEADS, &HashSet::new(), &HashSet::new());
        assert_eq!(r.fire, vec![("E1".to_string(), 5)]);
    }

    #[test]
    fn no_fire_earlier_than_tolerance() {
        let start = base();
        // 15m + 2s before start: just outside the T-15 tolerance window (45s).
        let now = start - ChronoDuration::minutes(15) - ChronoDuration::seconds(120);
        let events = [ev("E1", start, false)];
        let r = due_events(now, &events, &LEADS, &HashSet::new(), &HashSet::new());
        assert!(r.fire.is_empty(), "must not fire before the tolerance window");
        assert!(r.dismiss.is_empty());
    }

    #[test]
    fn no_duplicate_fire_when_already_in_fired_set() {
        let start = base();
        let now = start - ChronoDuration::minutes(15);
        let events = [ev("E1", start, false)];
        let mut fired = HashSet::new();
        fired.insert(("E1".to_string(), 15));
        let r = due_events(now, &events, &LEADS, &fired, &HashSet::new());
        assert!(r.fire.is_empty(), "second tick in the window must not re-fire");
    }

    #[test]
    fn no_fire_for_event_that_already_has_meeting() {
        let start = base();
        let now = start - ChronoDuration::minutes(15);
        let events = [ev("E1", start, true)]; // already recorded/linked
        let r = due_events(now, &events, &LEADS, &HashSet::new(), &HashSet::new());
        assert!(r.fire.is_empty(), "recorded events never fire a reminder");
    }

    #[test]
    fn no_dismiss_while_lingering_after_start() {
        let start = base();
        // Start just passed but still inside the linger grace window.
        let now = start + ChronoDuration::seconds(1);
        let events = [ev("E1", start, false)];
        let mut fired = HashSet::new();
        fired.insert(("E1".to_string(), 5));
        let r = due_events(now, &events, &LEADS, &fired, &HashSet::new());
        assert!(
            r.dismiss.is_empty(),
            "prompt must linger past start for the late-user grace window"
        );
        assert!(r.fire.is_empty(), "no new reminders fire after start");
    }

    #[test]
    fn dismiss_once_linger_window_expires() {
        let start = base();
        // Just past the linger grace window.
        let now = start + LINGER_AFTER_START + ChronoDuration::seconds(1);
        let events = [ev("E1", start, false)];
        let mut fired = HashSet::new();
        fired.insert(("E1".to_string(), 5));
        let r = due_events(now, &events, &LEADS, &fired, &HashSet::new());
        assert_eq!(r.dismiss, vec!["E1".to_string()]);
        assert!(r.fire.is_empty());
    }

    #[test]
    fn dismiss_when_event_gains_meeting() {
        let start = base();
        let now = start - ChronoDuration::minutes(4); // still before start
        let events = [ev("E1", start, true)]; // got recorded
        let mut fired = HashSet::new();
        fired.insert(("E1".to_string(), 5));
        let r = due_events(now, &events, &LEADS, &fired, &HashSet::new());
        assert_eq!(r.dismiss, vec!["E1".to_string()]);
    }

    #[test]
    fn dismiss_when_event_vanishes_from_range() {
        let now = base();
        // E1 was fired earlier but is absent from this tick's events (cancelled).
        let events: [SchedEvent; 0] = [];
        let mut fired = HashSet::new();
        fired.insert(("E1".to_string(), 15));
        let r = due_events(now, &events, &LEADS, &fired, &HashSet::new());
        assert_eq!(r.dismiss, vec!["E1".to_string()]);
    }

    #[test]
    fn no_redundant_dismiss_when_already_dismissed() {
        let start = base();
        let now = start + LINGER_AFTER_START + ChronoDuration::seconds(1);
        let events = [ev("E1", start, false)];
        let mut fired = HashSet::new();
        fired.insert(("E1".to_string(), 5));
        let mut dismissed = HashSet::new();
        dismissed.insert("E1".to_string());
        let r = due_events(now, &events, &LEADS, &fired, &dismissed);
        assert!(r.dismiss.is_empty(), "already-dismissed events don't re-emit");
    }

    #[test]
    fn vanished_event_dismissed_once_across_multiple_fired_leads() {
        let now = base();
        let events: [SchedEvent; 0] = [];
        let mut fired = HashSet::new();
        fired.insert(("E1".to_string(), 15));
        fired.insert(("E1".to_string(), 5));
        let r = due_events(now, &events, &LEADS, &fired, &HashSet::new());
        assert_eq!(r.dismiss, vec!["E1".to_string()], "one dismiss per event id");
    }

    #[test]
    fn full_lifecycle_t15_then_t5_then_dismiss() {
        let start = base();
        let events = [ev("E1", start, false)];
        let mut fired: HashSet<(String, i64)> = HashSet::new();
        let dismissed: HashSet<String> = HashSet::new();

        // Tick 1: T-15 → fire (15).
        let r1 = due_events(
            start - ChronoDuration::minutes(15),
            &events,
            &LEADS,
            &fired,
            &dismissed,
        );
        assert_eq!(r1.fire, vec![("E1".to_string(), 15)]);
        for f in &r1.fire {
            fired.insert(f.clone());
        }

        // Tick 2: T-5 → fire (5), no re-fire of 15.
        let r2 = due_events(
            start - ChronoDuration::minutes(5),
            &events,
            &LEADS,
            &fired,
            &dismissed,
        );
        assert_eq!(r2.fire, vec![("E1".to_string(), 5)]);
        for f in &r2.fire {
            fired.insert(f.clone());
        }

        // Tick 3: start just passed, still lingering → no dismiss, no fire.
        let r3 = due_events(
            start + ChronoDuration::seconds(2),
            &events,
            &LEADS,
            &fired,
            &dismissed,
        );
        assert!(r3.fire.is_empty());
        assert!(r3.dismiss.is_empty(), "prompt lingers through the grace window");

        // Tick 4: grace window expired → dismiss, no fire.
        let r4 = due_events(
            start + LINGER_AFTER_START + ChronoDuration::seconds(2),
            &events,
            &LEADS,
            &fired,
            &dismissed,
        );
        assert!(r4.fire.is_empty());
        assert_eq!(r4.dismiss, vec!["E1".to_string()]);
    }
}
