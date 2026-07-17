use ari_engine::providers::openai::OpenAIModel;

/// Fetch OpenAI models from API
///
/// # Arguments
/// * `api_key` - OpenAI API key
///
/// # Returns
/// Vector of available models, or fallback models on error
#[tauri::command]
pub async fn get_openai_models(api_key: Option<String>) -> Result<Vec<OpenAIModel>, String> {
    ari_engine::providers::openai::get_openai_models(api_key).await
}
