// Meeting-time correction (F4 calendar support).
//
// Imported meetings are inserted with `created_at = import time` (see
// `audio/import.rs`, which is upstream and left untouched per the additive-only rule).
// The calendar matching paths (`calendar_suggest_meetings`, background auto-match) key
// on `created_at`, so an upload made hours after the meeting lands outside the event's
// window and can't be linked. This command runs AFTER a successful import and realigns
// the meeting's `created_at` to the source audio file's last-modified time — a reliable
// proxy for when the meeting actually happened.
//
// Registered as `meeting_time::set_meeting_time_from_source` in `lib.rs`.

use crate::database::repositories::calendar::CalendarRepository;
use crate::engine::Engine;

/// Set an imported meeting's `created_at` from its source audio file's modified time.
///
/// Best-effort and non-fatal: the caller (frontend import flow) ignores failures so a
/// successful import is never undone by a timestamp-correction hiccup. Returns the
/// applied RFC3339 timestamp on success, or `None` if the meeting id was not found.
async fn set_meeting_time_from_source_impl(
    engine: &Engine,
    meeting_id: String,
    source_path: String,
) -> Result<Option<String>, String> {
    let modified = std::fs::metadata(&source_path)
        .and_then(|meta| meta.modified())
        .map_err(|e| format!("Could not read modified time for '{}': {}", source_path, e))?;

    let created_at: chrono::DateTime<chrono::Utc> = modified.into();

    let db = engine.db().await?;
    let pool = db.pool();
    let rows = CalendarRepository::realign_meeting_created_at(pool, &meeting_id, created_at)
        .await
        .map_err(|e| format!("Failed to realign meeting time for {}: {}", meeting_id, e))?;

    if rows == 0 {
        log::warn!(
            "🕒 meeting_time: no meeting matched id {} (nothing realigned)",
            meeting_id
        );
        return Ok(None);
    }

    log::info!(
        "🕒 meeting_time: realigned meeting {} created_at → {} (from source file mtime)",
        meeting_id,
        created_at.to_rfc3339()
    );
    Ok(Some(created_at.to_rfc3339()))
}

#[tauri::command]
pub async fn set_meeting_time_from_source(
    meeting_id: String,
    source_path: String,
    engine: tauri::State<'_, std::sync::Arc<crate::engine::Engine>>,
) -> Result<Option<String>, String> {
    set_meeting_time_from_source_impl(&engine, meeting_id, source_path).await
}
