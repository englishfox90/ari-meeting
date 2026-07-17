use ari_engine::providers::anthropic::AnthropicModel;

/// Fetch Anthropic models from API
///
/// # Arguments
/// * `api_key` - Anthropic API key
///
/// # Returns
/// Vector of available models, or fallback models on error
#[tauri::command]
pub async fn get_anthropic_models(api_key: Option<String>) -> Result<Vec<AnthropicModel>, String> {
    ari_engine::providers::anthropic::get_anthropic_models(api_key).await
}
