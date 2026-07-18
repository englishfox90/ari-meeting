// Meeting Series (F9) — pure command logic. The `#[tauri::command]` shims (registered as
// `meeting_series::commands::*` in `lib.rs`'s `generate_handler!` list) stay host-side in
// `frontend/src-tauri/src/meeting_series/commands.rs` and call straight into these `*_impl`
// fns, per the ari-engine carve's per-service migration recipe
// (`docs/plans/ari-engine-carve.md`).

use crate::database::repositories::meeting::MeetingsRepository;
use crate::database::repositories::meeting_series::{
    MeetingSeriesMemberRow, MeetingSeriesRepository,
};
use crate::engine::Engine;
use crate::meeting_series::models::{SeriesDetail, SeriesForMeeting, SeriesMember, SeriesSummary};

/// Resolve a meeting's current title (falls back to "Untitled meeting" if the row is gone).
async fn meeting_title(pool: &sqlx::SqlitePool, meeting_id: &str) -> Result<String, sqlx::Error> {
    let meta = MeetingsRepository::get_meeting_metadata(pool, meeting_id).await?;
    Ok(meta
        .map(|m| m.title)
        .unwrap_or_else(|| "Untitled meeting".to_string()))
}

pub async fn series_list_impl(engine: &Engine) -> Result<Vec<SeriesSummary>, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let rows = MeetingSeriesRepository::list_series(pool)
        .await
        .map_err(|e| format!("Failed to list series: {}", e))?;

    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let members = MeetingSeriesRepository::list_members(pool, &row.id)
            .await
            .map_err(|e| format!("Failed to list members for series {}: {}", row.id, e))?;
        // Members are ordered by occurrence_time ASC — the last one with a time is the latest.
        let last_meeting_time = members
            .iter()
            .rev()
            .find_map(|m| m.occurrence_time.clone());
        out.push(SeriesSummary {
            id: row.id,
            title: row.title,
            series_key: row.series_key,
            detected_type: row.detected_type,
            cadence: row.cadence,
            meeting_count: members.len() as i64,
            last_meeting_time,
        });
    }
    Ok(out)
}

pub async fn series_get_impl(engine: &Engine, series_id: String) -> Result<SeriesDetail, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let series = MeetingSeriesRepository::get_series(pool, &series_id)
        .await
        .map_err(|e| format!("Failed to load series {}: {}", series_id, e))?
        .ok_or_else(|| format!("Series {} not found", series_id))?;

    let member_rows = MeetingSeriesRepository::list_members(pool, &series_id)
        .await
        .map_err(|e| format!("Failed to list members for series {}: {}", series_id, e))?;

    let mut members = Vec::with_capacity(member_rows.len());
    for m in member_rows {
        let title = meeting_title(pool, &m.meeting_id)
            .await
            .map_err(|e| format!("Failed to resolve meeting {}: {}", m.meeting_id, e))?;
        members.push(SeriesMember {
            meeting_id: m.meeting_id,
            title,
            occurrence_time: m.occurrence_time,
        });
    }

    let ledger = MeetingSeriesRepository::get_ledger(pool, &series_id)
        .await
        .map_err(|e| format!("Failed to load ledger for series {}: {}", series_id, e))?;
    let (ledger_markdown, ledger_version) = match ledger {
        Some(l) => (l.ledger_markdown, l.version),
        None => (None, 0),
    };

    Ok(SeriesDetail {
        id: series.id,
        title: series.title,
        detected_type: series.detected_type,
        cadence: series.cadence,
        members,
        ledger_markdown,
        ledger_version,
    })
}

pub async fn series_for_meeting_impl(
    engine: &Engine,
    meeting_id: String,
) -> Result<Option<SeriesForMeeting>, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let series = match MeetingSeriesRepository::series_for_meeting(pool, &meeting_id)
        .await
        .map_err(|e| format!("Failed to find series for meeting {}: {}", meeting_id, e))?
    {
        Some(s) => s,
        None => return Ok(None),
    };

    let members: Vec<MeetingSeriesMemberRow> =
        MeetingSeriesRepository::list_members(pool, &series.id)
            .await
            .map_err(|e| format!("Failed to list members for series {}: {}", series.id, e))?;

    let idx = match members.iter().position(|m| m.meeting_id == meeting_id) {
        Some(i) => i,
        // The join said this meeting is a member but list_members disagrees — treat as
        // "not in a series" rather than fabricating a position.
        None => return Ok(None),
    };

    let prev_meeting_id = if idx > 0 {
        Some(members[idx - 1].meeting_id.clone())
    } else {
        None
    };
    let next_meeting_id = members.get(idx + 1).map(|m| m.meeting_id.clone());

    Ok(Some(SeriesForMeeting {
        series_id: series.id,
        series_title: series.title,
        position: (idx as i64) + 1,
        total: members.len() as i64,
        prev_meeting_id,
        next_meeting_id,
        series_template: series.template_id,
    }))
}

/// Manually create a new (empty) meeting series. Returns the new series id.
/// Rejects a blank/whitespace-only title — No-Fake-State (no untitled ghost series).
/// The created series has no `series_key` (manual, not calendar-derived) and no owner.
pub async fn series_create_impl(
    engine: &Engine,
    title: String,
    detected_type: Option<String>,
    cadence: Option<String>,
) -> Result<String, String> {
    let title = title.trim();
    if title.is_empty() {
        return Err("Series title cannot be empty".to_string());
    }
    let db = engine.db().await?;
    let pool = db.pool();
    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();

    MeetingSeriesRepository::insert_series(
        pool,
        &id,
        None, // series_key — manual series aren't calendar-keyed
        title,
        detected_type.as_deref(),
        cadence.as_deref(),
        None, // owner_person_id
        &now,
    )
    .await
    .map_err(|e| format!("Failed to create series: {}", e))?;

    Ok(id)
}

pub async fn series_link_meeting_impl(
    engine: &Engine,
    meeting_id: String,
    series_id: String,
) -> Result<(), String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let now = chrono::Utc::now().to_rfc3339();

    // Use the meeting's created_at as the occurrence time so manual members sort with the
    // auto-detected ones. Non-fatal if the lookup fails — link with no time.
    let occurrence_time = MeetingsRepository::get_meeting_metadata(pool, &meeting_id)
        .await
        .ok()
        .flatten()
        .map(|m| m.created_at.0.to_rfc3339());

    MeetingSeriesRepository::upsert_member(
        pool,
        &series_id,
        &meeting_id,
        occurrence_time.as_deref(),
        "manual",
        &now,
    )
    .await
    .map_err(|e| format!("Failed to link meeting {} to series {}: {}", meeting_id, series_id, e))
}

pub async fn series_unlink_meeting_impl(
    engine: &Engine,
    meeting_id: String,
    series_id: String,
) -> Result<(), String> {
    let db = engine.db().await?;
    let pool = db.pool();
    MeetingSeriesRepository::remove_member(pool, &series_id, &meeting_id)
        .await
        .map_err(|e| {
            format!(
                "Failed to unlink meeting {} from series {}: {}",
                meeting_id, series_id, e
            )
        })
}

pub async fn series_update_meta_impl(
    engine: &Engine,
    series_id: String,
    title: String,
    detected_type: Option<String>,
    cadence: Option<String>,
) -> Result<(), String> {
    let db = engine.db().await?;
    let pool = db.pool();
    // Preserve the existing owner_person_id — this command only edits title/type/cadence.
    let existing = MeetingSeriesRepository::get_series(pool, &series_id)
        .await
        .map_err(|e| format!("Failed to load series {}: {}", series_id, e))?
        .ok_or_else(|| format!("Series {} not found", series_id))?;
    let now = chrono::Utc::now().to_rfc3339();

    MeetingSeriesRepository::update_series_meta(
        pool,
        &series_id,
        &title,
        detected_type.as_deref(),
        cadence.as_deref(),
        existing.owner_person_id.as_deref(),
        &now,
    )
    .await
    .map_err(|e| format!("Failed to update series {}: {}", series_id, e))
}

/// Heuristic (non-calendar) series detection: cluster meetings not in any series by
/// normalized title and form series from clusters of 2+. Returns the number of NEW series
/// created. Idempotent — re-running detects nothing new.
pub async fn series_rescan_heuristic_impl(engine: &Engine) -> Result<usize, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    crate::meeting_series::detection::rescan_heuristic_series(pool)
        .await
        .map_err(|e| format!("Failed to rescan heuristic series: {}", e))
}

/// F9 template inheritance: remember the summary template a meeting's series settled on, so
/// future occurrences inherit it instead of re-classifying. No-op (Ok) if the meeting isn't
/// in any series.
pub async fn series_set_template_impl(
    engine: &Engine,
    meeting_id: String,
    template_id: String,
) -> Result<(), String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let series = MeetingSeriesRepository::series_for_meeting(pool, &meeting_id)
        .await
        .map_err(|e| format!("Failed to find series for meeting {}: {}", meeting_id, e))?;
    let series = match series {
        Some(s) => s,
        None => return Ok(()),
    };
    let now = chrono::Utc::now().to_rfc3339();
    MeetingSeriesRepository::set_template(pool, &series.id, Some(template_id.as_str()), &now)
        .await
        .map_err(|e| format!("Failed to set template for series {}: {}", series.id, e))
}

/// Recompute the rolling series ledger for the series that `meeting_id` belongs to.
///
/// Delegates to `meeting_series::ledger::rebuild_ledger_for_meeting`, which folds this
/// meeting's finished summary into the rolling `series_ledger` via one bounded LLM reduce.
/// Returns `Ok(())` quickly (no LLM work) when the meeting isn't in any series or has no
/// finished summary — see the No-Fake-State gating inside the ledger module.
pub async fn series_update_ledger_impl(
    engine: &Engine,
    meeting_id: String,
) -> Result<(), String> {
    let db = engine.db().await?;
    let pool = db.pool();
    crate::meeting_series::ledger::rebuild_ledger_for_meeting(engine, pool, &meeting_id)
        .await
        .map_err(|e| format!("Failed to update series ledger for meeting {}: {}", meeting_id, e))
}

/// Rebuild a series' ledger from scratch by folding every member meeting's EXISTING finished
/// summary in chronological order.
///
/// Delegates to `meeting_series::ledger::rebuild_ledger_for_series`. This is the on-demand
/// path for a hand-curated series whose meetings were summarized before being linked (the
/// incremental per-meeting reduce only fires when a summary is (re)generated after linking).
///
/// Returns the rebuilt ledger markdown, or `None` when NO member has a usable summary yet —
/// in which case any existing ledger is left untouched (No-Fake-State: we never fabricate or
/// blank a ledger).
pub async fn series_rebuild_ledger_impl(
    engine: &Engine,
    series_id: String,
) -> Result<Option<String>, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    crate::meeting_series::ledger::rebuild_ledger_for_series(engine, pool, &series_id)
        .await
        .map_err(|e| format!("Failed to rebuild series ledger for {}: {}", series_id, e))
}
