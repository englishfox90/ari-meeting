// Person Profiles (F2) + Owner Context (F3) — Tauri command surface. Registered as
// `persons::commands::*` in `lib.rs`'s `generate_handler!` list under the
// `// Person Profiles (F2/F3)` block. The pure `*_impl` logic now lives in
// `ari-engine::persons::commands`; these are thin shims per the ari-engine carve's
// per-service migration recipe (`docs/plans/ari-engine-carve.md`). See the frozen F2
// implementation contract (scratchpad `F2-contract.md`) for exact argument/return shapes.

use crate::engine::Engine;
use ari_engine::persons::commands as engine_commands;
use ari_engine::persons::models::{
    ExtractionResult, NewPerson, Person, PersonDetail, PersonSummary, ProfileFact,
    ProfileFactSource, ProfileFactWithPerson, ReconciliationResult,
};

#[tauri::command]
pub async fn person_list(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<PersonSummary>, String> {
    engine_commands::person_list_impl(&engine).await
}

#[tauri::command]
pub async fn person_get(
    person_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<PersonDetail, String> {
    engine_commands::person_get_impl(&engine, person_id).await
}

#[tauri::command]
pub async fn person_upsert(
    person: NewPerson,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Person, String> {
    engine_commands::person_upsert_impl(&engine, person).await
}

#[tauri::command]
pub async fn person_delete(
    person_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_commands::person_delete_impl(&engine, person_id).await
}

#[tauri::command]
pub async fn owner_get(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Option<Person>, String> {
    engine_commands::owner_get_impl(&engine).await
}

#[tauri::command]
pub async fn owner_set(
    person: NewPerson,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Person, String> {
    engine_commands::owner_set_impl(&engine, person).await
}

#[tauri::command]
pub async fn person_import_from_event(
    event_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<Person>, String> {
    engine_commands::person_import_from_event_impl(&engine, event_id).await
}

#[tauri::command]
pub async fn meeting_participants(
    meeting_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<PersonSummary>, String> {
    engine_commands::meeting_participants_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn profile_facts_for_person(
    person_id: String,
    include_superseded: bool,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<ProfileFact>, String> {
    engine_commands::profile_facts_for_person_impl(&engine, person_id, include_superseded).await
}

#[tauri::command]
pub async fn profile_facts_pending(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<ProfileFactWithPerson>, String> {
    engine_commands::profile_facts_pending_impl(&engine).await
}

#[tauri::command]
pub async fn profile_fact_confirm(
    fact_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_commands::profile_fact_confirm_impl(&engine, fact_id).await
}

#[tauri::command]
pub async fn profile_fact_reject(
    fact_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_commands::profile_fact_reject_impl(&engine, fact_id).await
}

#[tauri::command]
pub async fn profile_fact_add_manual(
    person_id: String,
    fact_text: String,
    fact_kind: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<ProfileFact, String> {
    engine_commands::profile_fact_add_manual_impl(&engine, person_id, fact_text, fact_kind).await
}

#[tauri::command]
pub async fn profile_fact_sources(
    fact_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<ProfileFactSource>, String> {
    engine_commands::profile_fact_sources_impl(&engine, fact_id).await
}

#[tauri::command]
pub async fn person_extract_facts_for_meeting(
    meeting_id: String,
    _app: tauri::AppHandle,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<ExtractionResult, String> {
    engine_commands::person_extract_facts_for_meeting_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn person_reconcile_facts_for_meeting(
    meeting_id: String,
    _app: tauri::AppHandle,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<ReconciliationResult, String> {
    engine_commands::person_reconcile_facts_for_meeting_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn person_facts_needing_review(
    person_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<ProfileFact>, String> {
    engine_commands::person_facts_needing_review_impl(&engine, person_id).await
}

/// **Host seam:** `organization` is company-wide config loaded from the Tauri `AppHandle`
/// via `crate::app_config::load` — a HOST-ONLY module (`app_config_dir` resolution) that
/// cannot move to `ari-engine`. This shim resolves it here and passes only the resolved
/// `String` into the engine-side `_impl`, per the ari-engine carve's "THE ONE HOST SEAM"
/// handling (`docs/plans/ari-engine-carve.md`).
#[tauri::command]
pub async fn summary_context_for_meeting(
    meeting_id: String,
    app: tauri::AppHandle,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<String, String> {
    let organization = crate::app_config::load(&app)
        .map(|c| c.organization)
        .unwrap_or_default();
    engine_commands::summary_context_for_meeting_impl(&engine, &organization, meeting_id).await
}
