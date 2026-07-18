//! Thin `#[tauri::command]` shim — the pure logic (`TemplateInfo` +
//! `list_templates_impl`) now lives in `ari_engine::summary::template_commands`,
//! per the ari-engine carve's per-service migration recipe
//! (`docs/plans/ari-engine-carve.md`).

pub use ari_engine::summary::template_commands::{list_templates_impl, TemplateInfo};
use tauri::Runtime;
use tracing::info;

/// Lists all available templates
///
/// Returns templates from both built-in (embedded) and custom (user data directory) sources.
/// Templates are automatically discovered - no code changes needed to add new templates.
///
/// # Returns
/// Vector of TemplateInfo with id, name, and description for each template
#[tauri::command]
pub async fn api_list_templates<R: Runtime>(
    _app: tauri::AppHandle<R>,
) -> Result<Vec<TemplateInfo>, String> {
    info!("api_list_templates called");

    let template_infos = list_templates_impl();

    info!("Found {} available templates", template_infos.len());

    Ok(template_infos)
}
