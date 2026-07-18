//! F6: Automatic template selection — thin `#[tauri::command]` shim. The pure
//! classification logic (`api_suggest_template_impl`) now lives in
//! `ari_engine::summary::template_selector`, per the ari-engine carve's
//! per-service migration recipe (`docs/plans/ari-engine-carve.md`).

use ari_engine::engine::Engine;
pub use ari_engine::summary::template_selector::{api_suggest_template_impl, TemplateSuggestion};
use tauri::{AppHandle, Runtime};

/// F6: auto-select the best-fitting summary template for a transcript.
///
/// Returns the chosen `{ id, name }`. Never errors on classifier failure —
/// it degrades to the default template so summary generation is never blocked.
#[tauri::command]
pub async fn api_suggest_template<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    text: String,
    speaker_count: Option<u32>,
    calendar_context: Option<String>,
) -> Result<TemplateSuggestion, String> {
    api_suggest_template_impl(&engine, text, speaker_count, calendar_context).await
}
