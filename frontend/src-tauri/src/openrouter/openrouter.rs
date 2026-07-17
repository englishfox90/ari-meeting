pub use ari_engine::providers::openrouter::OpenRouterModel;

#[tauri::command]
pub fn get_openrouter_models() -> Result<Vec<OpenRouterModel>, String> {
    ari_engine::providers::openrouter::get_openrouter_models()
}
