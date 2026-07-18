use tauri::command;
use ari_engine::providers::ollama::{self, OllamaModel};

#[command]
pub async fn get_ollama_models(endpoint: Option<String>) -> Result<Vec<OllamaModel>, String> {
    ollama::get_ollama_models(endpoint).await
}

#[command]
pub async fn pull_ollama_model(
    model_name: String,
    endpoint: Option<String>,
    engine: tauri::State<'_, std::sync::Arc<ari_engine::engine::Engine>>,
) -> Result<(), String> {
    ollama::pull_ollama_model_impl(&engine, model_name, endpoint).await
}

#[command]
pub async fn delete_ollama_model(
    model_name: String,
    endpoint: Option<String>,
) -> Result<(), String> {
    ollama::delete_ollama_model(model_name, endpoint).await
}

/// Get the context size for a specific Ollama model
///
/// This command fetches model metadata and returns the context size.
/// Results are cached for 5 minutes to avoid repeated API calls.
///
/// # Arguments
/// * `model_name` - Name of the model (e.g., "llama3.2:1b")
/// * `endpoint` - Optional custom Ollama endpoint
///
/// # Returns
/// Context size in tokens, or error message
#[command]
pub async fn get_ollama_model_context(
    model_name: String,
    endpoint: Option<String>,
) -> Result<usize, String> {
    ollama::get_ollama_model_context(model_name, endpoint).await
}

/// Generate a single embedding for `text` via a local Ollama server (`/api/embeddings`).
/// Best-effort: callers treat any error as "semantic arm unavailable" and fall back to
/// lexical search, so this never surfaces to the user. Not a Tauri command — used
/// internally by the recall index/search.
pub async fn get_ollama_embedding(
    endpoint: Option<&str>,
    model: &str,
    text: &str,
) -> Result<Vec<f32>, String> {
    ollama::get_ollama_embedding(endpoint, model, text).await
}
