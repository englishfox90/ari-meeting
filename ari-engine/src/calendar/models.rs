// Calendar (F4) wire types. All response structs are `camelCase` on the wire per the
// frontend/backend IPC contract.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarInfo {
    pub id: String,
    pub title: String,
    pub color: Option<String>,
    pub selected: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Attendee {
    pub name: Option<String>,
    pub email: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEvent {
    pub id: String,
    pub calendar_id: String,
    pub calendar_title: Option<String>,
    pub title: String,
    pub start_time: String,
    pub end_time: String,
    pub is_all_day: bool,
    pub location: Option<String>,
    pub notes: Option<String>,
    pub organizer: Option<String>,
    pub attendees: Vec<Attendee>,
    pub meeting_id: Option<String>,
    pub link_source: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkedMeeting {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub has_summary: bool,
    pub summary_snippet: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEventDetail {
    pub id: String,
    pub calendar_id: String,
    pub calendar_title: Option<String>,
    pub title: String,
    pub start_time: String,
    pub end_time: String,
    pub is_all_day: bool,
    pub location: Option<String>,
    pub notes: Option<String>,
    pub organizer: Option<String>,
    pub attendees: Vec<Attendee>,
    pub meeting_id: Option<String>,
    pub link_source: Option<String>,
    pub linked_meeting: Option<LinkedMeeting>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingCandidate {
    pub id: String,
    pub title: String,
    pub created_at: String,
}

/// Native (EventKit) representation of a single calendar, independent of any DB row.
#[derive(Debug, Clone)]
pub struct NativeCalendar {
    pub id: String,
    pub title: String,
    pub color: Option<String>,
}

/// Native (EventKit) representation of a single event, independent of any DB row.
#[derive(Debug, Clone)]
pub struct NativeEvent {
    pub id: String,
    pub calendar_id: String,
    pub calendar_title: Option<String>,
    pub title: String,
    pub start_time: chrono::DateTime<chrono::Utc>,
    pub end_time: chrono::DateTime<chrono::Utc>,
    pub is_all_day: bool,
    pub location: Option<String>,
    pub notes: Option<String>,
    pub organizer: Option<String>,
    pub attendees: Vec<Attendee>,
    // ---- Recurrence signals (F9 Meeting Series) ----
    /// EventKit `calendarItemExternalIdentifier` — stable across all occurrences of a
    /// recurring event, so it serves as the series key. `None` for non-recurring or
    /// unsaved events.
    pub series_key: Option<String>,
    /// Whether this event has recurrence rules (`hasRecurrenceRules`).
    pub has_recurrence: bool,
    /// RFC3339 UTC of this specific occurrence (`occurrenceDate`), if any.
    pub occurrence_date: Option<String>,
    /// Whether this occurrence was detached/edited from the series (`isDetached`).
    pub is_detached: bool,
}
