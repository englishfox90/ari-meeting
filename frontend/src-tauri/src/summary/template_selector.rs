//! F6: Automatic template selection.
//!
//! Classifies a meeting transcript against the available summary templates and
//! returns the best-fitting `template_id`. This runs once, just before summary
//! generation, so the summary is shaped by the *kind* of meeting without the
//! user having to pick a template. The user can always override the pick and
//! regenerate.
//!
//! Design notes:
//! - Additive-only: a new module + one new Tauri command. No upstream edits
//!   beyond registration in `lib.rs` and the `pub mod` in `summary/mod.rs`.
//! - Reuses the configured summary provider/model via `SettingsRepository`, so
//!   it works with cloud, Ollama, Built-in AI, Custom OpenAI, Claude CLI, and
//!   Apple Foundation without new configuration.
//! - Never hard-fails the summary flow: any error (no config, provider down,
//!   junk response) falls back to `standard_meeting` rather than blocking.

use crate::database::repositories::setting::SettingsRepository;
use crate::engine::Engine;
use crate::summary::llm_client::{generate_summary, LLMProvider};
use crate::summary::templates;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::{AppHandle, Runtime};
use tracing::{info, warn};

/// Meeting type is almost always evident early (greetings, agenda, roll-call),
/// so a bounded prefix keeps classification cheap and inside local-model context.
const MAX_CLASSIFY_CHARS: usize = 4_000;

/// Safe fallback when nothing else fits or the classifier is unavailable.
const DEFAULT_TEMPLATE_ID: &str = "standard_meeting";

/// The auto-selected template returned to the frontend.
#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct TemplateSuggestion {
    pub id: String,
    pub name: String,
}

/// Builds the (system, user) classification prompt from the available
/// templates and a bounded transcript excerpt.
fn build_template_selection_prompt(
    options: &[(String, String, String)],
    excerpt: &str,
    speaker_count: Option<u32>,
    calendar_context: Option<&str>,
) -> (String, String) {
    let system = "You are a meeting classifier. From the list of templates, choose the single one that best fits the meeting transcript. Respond with ONLY the template id exactly as written in the list — no quotes, no punctuation, no explanation. If none clearly fits, respond with \"standard_meeting\".".to_string();

    let mut options_block = String::new();
    for (id, name, description) in options {
        options_block.push_str(&format!("- {id}: {name} — {description}\n"));
    }

    let mut signals_block = String::new();
    if let Some(count) = speaker_count {
        signals_block.push_str(&format!("- Distinct speakers detected: {count}\n"));
    }
    if let Some(context) = calendar_context.filter(|c| !c.trim().is_empty()) {
        signals_block.push_str(&format!("- Calendar event context: {context}\n"));
    }
    let signals_section = if signals_block.is_empty() {
        String::new()
    } else {
        format!("\nAdditional signals:\n{signals_block}")
    };

    let user = format!(
        "Available templates (id: name — description):\n{options_block}\nTranscript excerpt:\n<transcript>\n{excerpt}\n</transcript>{signals_section}\n\nRespond with exactly one template id from the list above."
    );

    (system, user)
}

/// Maps a raw model response to a valid template id. Tolerant of extra prose,
/// quotes, and casing; falls back to `standard_meeting` (or the first template)
/// when the response names nothing valid.
fn parse_selected_template_id(response: &str, valid_ids: &[String]) -> String {
    let cleaned = response
        .trim()
        .trim_matches(|c: char| {
            c == '"' || c == '\'' || c == '`' || c == '.' || c == ':' || c.is_whitespace()
        })
        .to_lowercase();

    // Exact id match wins.
    if let Some(hit) = valid_ids.iter().find(|id| id.to_lowercase() == cleaned) {
        return (*hit).clone();
    }

    // Otherwise, the model may have wrapped the id in extra words. No template
    // id is a substring of another, so a contains-check is unambiguous here.
    if let Some(hit) = valid_ids
        .iter()
        .find(|id| cleaned.contains(&id.to_lowercase()))
    {
        return (*hit).clone();
    }

    valid_ids
        .iter()
        .find(|id| id.as_str() == DEFAULT_TEMPLATE_ID)
        .cloned()
        .or_else(|| valid_ids.first().cloned())
        .unwrap_or_else(|| DEFAULT_TEMPLATE_ID.to_string())
}

/// Picks the default suggestion without an LLM call.
fn default_suggestion(options: &[(String, String, String)]) -> TemplateSuggestion {
    let (id, name, _) = options
        .iter()
        .find(|(id, _, _)| id == DEFAULT_TEMPLATE_ID)
        .or_else(|| options.first())
        .cloned()
        .unwrap_or_else(|| {
            (
                DEFAULT_TEMPLATE_ID.to_string(),
                "Standard Meeting Notes".to_string(),
                String::new(),
            )
        });
    TemplateSuggestion { id, name }
}

/// The provider/model parameters needed to make one classification call.
struct ResolvedModel {
    provider: LLMProvider,
    model: String,
    api_key: String,
    ollama_endpoint: Option<String>,
    custom_openai_endpoint: Option<String>,
    app_data_dir: Option<PathBuf>,
}

/// Resolves the currently-configured summary model the same way the summary
/// service does, condensed to what a single stateless call needs.
async fn resolve_model(engine: &Engine) -> Result<ResolvedModel, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let config = SettingsRepository::get_model_config(pool)
        .await
        .map_err(|e| format!("Could not read model configuration: {e}"))?
        .ok_or_else(|| "Configure a summary model before auto-selecting a template.".to_string())?;

    let provider = LLMProvider::from_str(&config.provider)
        .map_err(|_| format!("Unsupported provider: {}", config.provider))?;

    let app_data_dir = Some(engine.paths().app_data.clone());

    // Custom OpenAI keeps its endpoint/key/model in a separate JSON config.
    if provider == LLMProvider::CustomOpenAI {
        let custom = SettingsRepository::get_custom_openai_config(pool)
            .await
            .map_err(|e| format!("Could not read Custom OpenAI configuration: {e}"))?
            .ok_or_else(|| "Custom OpenAI selected but not configured.".to_string())?;
        return Ok(ResolvedModel {
            provider,
            model: custom.model,
            api_key: custom.api_key.unwrap_or_default(),
            ollama_endpoint: None,
            custom_openai_endpoint: Some(custom.endpoint),
            app_data_dir,
        });
    }

    // Keyless providers vs. cloud providers that need an API key.
    let api_key = match provider {
        LLMProvider::Ollama
        | LLMProvider::BuiltInAI
        | LLMProvider::ClaudeCLI
        | LLMProvider::AppleFoundation => String::new(),
        _ => SettingsRepository::get_api_key(pool, &config.provider)
            .await
            .map_err(|e| format!("Could not read API key: {e}"))?
            .unwrap_or_default(),
    };

    Ok(ResolvedModel {
        provider,
        model: config.model,
        api_key,
        ollama_endpoint: config.ollama_endpoint,
        custom_openai_endpoint: None,
        app_data_dir,
    })
}

/// F6: auto-select the best-fitting summary template for a transcript.
///
/// Returns the chosen `{ id, name }`. Never errors on classifier failure —
/// it degrades to the default template so summary generation is never blocked.
async fn api_suggest_template_impl(
    engine: &Engine,
    text: String,
    speaker_count: Option<u32>,
    calendar_context: Option<String>,
) -> Result<TemplateSuggestion, String> {
    let options = templates::list_templates();
    if options.is_empty() {
        return Err("No templates available.".to_string());
    }
    let valid_ids: Vec<String> = options.iter().map(|(id, _, _)| id.clone()).collect();

    // Nothing to classify, or no real choice to make.
    let trimmed = text.trim();
    if trimmed.is_empty() || options.len() == 1 {
        return Ok(default_suggestion(&options));
    }

    let resolved = match resolve_model(engine).await {
        Ok(r) => r,
        Err(e) => {
            warn!("Template auto-select: falling back to default ({e})");
            return Ok(default_suggestion(&options));
        }
    };

    let excerpt: String = trimmed.chars().take(MAX_CLASSIFY_CHARS).collect();
    let (system_prompt, user_prompt) = build_template_selection_prompt(
        &options,
        &excerpt,
        speaker_count,
        calendar_context.as_deref(),
    );

    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| format!("Could not start the classifier request: {e}"))?;

    let raw = match generate_summary(
        &client,
        &resolved.provider,
        &resolved.model,
        &resolved.api_key,
        &system_prompt,
        &user_prompt,
        resolved.ollama_endpoint.as_deref(),
        resolved.custom_openai_endpoint.as_deref(),
        Some(32),   // classification output is one short id (CustomOpenAI only)
        Some(0.0),  // deterministic (CustomOpenAI only)
        None,
        resolved.app_data_dir.as_ref(),
        None,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            warn!("Template classifier call failed, using default: {e}");
            return Ok(default_suggestion(&options));
        }
    };

    let id = parse_selected_template_id(&raw, &valid_ids);
    let name = options
        .iter()
        .find(|(oid, _, _)| oid == &id)
        .map(|(_, n, _)| n.clone())
        .unwrap_or_else(|| id.clone());

    info!("Auto-selected template '{}' for summary", id);
    Ok(TemplateSuggestion { id, name })
}

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

#[cfg(test)]
mod tests {
    use super::*;

    fn ids() -> Vec<String> {
        vec![
            "standard_meeting".to_string(),
            "team_meeting".to_string(),
            "one_on_one".to_string(),
            "daily_standup".to_string(),
        ]
    }

    #[test]
    fn parses_exact_id() {
        assert_eq!(parse_selected_template_id("team_meeting", &ids()), "team_meeting");
    }

    #[test]
    fn parses_with_surrounding_noise() {
        assert_eq!(
            parse_selected_template_id("  \"one_on_one\".\n", &ids()),
            "one_on_one"
        );
    }

    #[test]
    fn parses_id_embedded_in_prose() {
        assert_eq!(
            parse_selected_template_id("The best fit is daily_standup here.", &ids()),
            "daily_standup"
        );
    }

    #[test]
    fn is_case_insensitive() {
        assert_eq!(parse_selected_template_id("TEAM_MEETING", &ids()), "team_meeting");
    }

    #[test]
    fn falls_back_to_standard_on_garbage() {
        assert_eq!(
            parse_selected_template_id("I don't know", &ids()),
            "standard_meeting"
        );
    }

    #[test]
    fn falls_back_to_first_when_no_standard() {
        let alt = vec!["team_meeting".to_string(), "one_on_one".to_string()];
        assert_eq!(parse_selected_template_id("???", &alt), "team_meeting");
    }

    #[test]
    fn default_suggestion_prefers_standard_meeting() {
        let opts = vec![
            ("team_meeting".to_string(), "Team Meeting".to_string(), "d".to_string()),
            (
                "standard_meeting".to_string(),
                "Standard Meeting Notes".to_string(),
                "d".to_string(),
            ),
        ];
        assert_eq!(
            default_suggestion(&opts),
            TemplateSuggestion {
                id: "standard_meeting".to_string(),
                name: "Standard Meeting Notes".to_string()
            }
        );
    }

    #[test]
    fn prompt_lists_all_options_and_wraps_excerpt() {
        let opts = vec![
            ("team_meeting".to_string(), "Team Meeting".to_string(), "team sync".to_string()),
            ("one_on_one".to_string(), "1:1 Meeting".to_string(), "manager 1:1".to_string()),
        ];
        let (system, user) = build_template_selection_prompt(&opts, "hello team", None, None);
        assert!(system.contains("meeting classifier"));
        assert!(user.contains("team_meeting: Team Meeting — team sync"));
        assert!(user.contains("one_on_one: 1:1 Meeting — manager 1:1"));
        assert!(user.contains("<transcript>\nhello team\n</transcript>"));
    }

    #[test]
    fn prompt_includes_speaker_count_and_calendar_context_when_present() {
        let opts = vec![(
            "one_on_one".to_string(),
            "1:1 Meeting".to_string(),
            "manager 1:1".to_string(),
        )];
        let (_, user) = build_template_selection_prompt(
            &opts,
            "hello",
            Some(2),
            Some("Weekly 1:1 with Jamie"),
        );
        assert!(user.contains("Distinct speakers detected: 2"));
        assert!(user.contains("Calendar event context: Weekly 1:1 with Jamie"));
    }

    #[test]
    fn prompt_omits_signals_section_when_absent() {
        let opts = vec![(
            "standard_meeting".to_string(),
            "Standard Meeting Notes".to_string(),
            "d".to_string(),
        )];
        let (_, user) = build_template_selection_prompt(&opts, "hello", None, None);
        assert!(!user.contains("Additional signals"));
    }
}
