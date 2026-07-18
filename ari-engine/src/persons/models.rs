// Person Profiles (F2) + Owner Context (F3) wire types. All response structs are
// `camelCase` on the wire per the frontend/backend IPC contract (mirrors calendar/models.rs).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Person {
    pub id: String,
    pub email: Option<String>,
    pub display_name: String,
    pub role: Option<String>,
    pub organization: Option<String>,
    pub domain: Option<String>,
    pub notes: Option<String>,
    pub is_owner: bool,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonSummary {
    pub id: String,
    pub email: Option<String>,
    pub display_name: String,
    pub role: Option<String>,
    pub organization: Option<String>,
    pub is_owner: bool,
    pub active_fact_count: i64,
    pub pending_fact_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileFact {
    pub id: String,
    pub person_id: String,
    pub fact_text: String,
    pub fact_kind: String,
    pub source_meeting_id: Option<String>,
    pub source_meeting_title: Option<String>,
    pub source_segment_ref: Option<String>,
    pub source_kind: String,
    pub confidence: f64,
    /// Number of recorded sources (origin + reaffirmations + carried-forward lineage) backing
    /// this fact. A real corroboration signal; 0 for manually-added facts.
    pub source_count: i64,
    pub status: String,
    pub superseded_by: Option<String>,
    pub created_at: String,
}

/// One recorded observation backing a `ProfileFact` — the wire shape of a
/// `profile_fact_sources` row (F2 multi-source facts).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileFactSource {
    pub id: String,
    pub fact_id: String,
    pub meeting_id: Option<String>,
    pub meeting_title: Option<String>,
    pub segment_ref: Option<String>,
    pub source_kind: String,
    /// 'origin' | 'reaffirmed' | 'carried'
    pub relation: String,
    pub confidence: f64,
    pub observed_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileFactWithPerson {
    pub fact: ProfileFact,
    pub person_id: String,
    pub person_display_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonDetail {
    pub person: Person,
    pub facts: Vec<ProfileFact>,
    pub meeting_count: i64,
}

pub use crate::models::NewPerson;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractionResult {
    pub created: i64,
    pub meeting_id: String,
    pub message: String,
}

/// Result of `persons::reconciliation::reconcile_facts_for_meeting`. Reconciliation
/// replaces plain extraction: instead of only ever inserting new pending facts, it shows
/// the model each participant's CURRENT facts and asks it to add/keep/supersede/remove,
/// then enforces a per-person active-fact cap. See `.claude/context/product.md` F2 and
/// the reconciliation contract in `persons::reconciliation`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReconciliationResult {
    pub meeting_id: String,
    pub added: i64,
    pub superseded: i64,
    pub kept: i64,
    pub removed: i64,
    /// How many active facts were auto-pruned afterward for exceeding the per-person cap
    /// (a subset of `removed`'s counterpart at the DB level, but tracked separately since
    /// it's cap-enforcement, not a model decision).
    pub capped: i64,
    pub message: String,
}
