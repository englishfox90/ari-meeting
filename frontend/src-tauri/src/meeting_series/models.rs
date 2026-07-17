// Meeting Series (F9) wire types. All response structs are `camelCase` on the wire per the
// frontend/backend IPC contract (mirrors calendar/models.rs and persons/models.rs).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeriesSummary {
    pub id: String,
    pub title: String,
    pub series_key: Option<String>,
    pub detected_type: Option<String>,
    pub cadence: Option<String>,
    pub meeting_count: i64,
    pub last_meeting_time: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeriesMember {
    pub meeting_id: String,
    pub title: String,
    pub occurrence_time: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeriesDetail {
    pub id: String,
    pub title: String,
    pub detected_type: Option<String>,
    pub cadence: Option<String>,
    pub members: Vec<SeriesMember>,
    pub ledger_markdown: Option<String>,
    pub ledger_version: i64,
}

/// The series a given meeting belongs to, plus its position within the ordered member list
/// and pointers to the adjacent occurrences (for prev/next navigation in the UI).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeriesForMeeting {
    pub series_id: String,
    pub series_title: String,
    /// 1-based position of this meeting among the series members (ordered by occurrence).
    pub position: i64,
    pub total: i64,
    pub prev_meeting_id: Option<String>,
    pub next_meeting_id: Option<String>,
    /// F9 template inheritance: the summary template this series settled on (if any). When
    /// present, the summary pipeline reuses it instead of re-running LLM classification.
    pub series_template: Option<String>,
}
