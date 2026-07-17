use ari_engine::providers::groq::GroqModel;

/// Fetch Groq models from API
///
/// # Arguments
/// * `api_key` - Groq API key
///
/// # Returns
/// Vector of available models, or fallback models on error
#[tauri::command]
pub async fn get_groq_models(api_key: Option<String>) -> Result<Vec<GroqModel>, String> {
    ari_engine::providers::groq::get_groq_models(api_key).await
}
