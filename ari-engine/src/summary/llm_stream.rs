//! Streaming counterpart of `llm_client::generate_summary` (additive; the
//! non-streaming path is untouched). `generate_summary_stream` invokes `on_delta`
//! for each incremental chunk of the answer and returns the full accumulated text
//! so callers can run their usual post-processing (e.g. recall citation
//! verification) on the authoritative complete answer.
//!
//! Streaming coverage:
//! - **HTTP providers** (OpenAI / Groq / OpenRouter / Ollama / CustomOpenAI): true
//!   token streaming via OpenAI-style SSE (`choices[].delta.content`).
//! - **Claude**: true token streaming via Anthropic SSE (`content_block_delta`).
//! - **Built-in AI** (llama-helper sidecar): true token streaming.
//! - **Claude CLI / Apple FoundationModels**: graceful fallback — the full answer
//!   is produced by the existing non-streaming call, then emitted as a single
//!   delta. Still correct, just not incremental (these wrap separate binaries).

use futures_util::StreamExt;
use reqwest::{header, Client};
use std::path::PathBuf;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

use super::llm_client::{ChatMessage, LLMProvider};

const REQUEST_TIMEOUT_DURATION: Duration = Duration::from_secs(300);

/// Generate a summary/answer, streaming incremental text to `on_delta`.
/// Returns the full accumulated answer on success.
pub async fn generate_summary_stream<F>(
    client: &Client,
    provider: &LLMProvider,
    model_name: &str,
    api_key: &str,
    system_prompt: &str,
    user_prompt: &str,
    ollama_endpoint: Option<&str>,
    custom_openai_endpoint: Option<&str>,
    max_tokens: Option<u32>,
    temperature: Option<f32>,
    top_p: Option<f32>,
    app_data_dir: Option<&PathBuf>,
    cancellation_token: Option<&CancellationToken>,
    mut on_delta: F,
) -> Result<String, String>
where
    F: FnMut(&str),
{
    if let Some(token) = cancellation_token {
        if token.is_cancelled() {
            return Err("Answer generation was cancelled".to_string());
        }
    }

    // Built-in AI: true streaming via the sidecar.
    if provider == &LLMProvider::BuiltInAI {
        let app_data_dir = app_data_dir
            .ok_or_else(|| "app_data_dir is required for BuiltInAI provider".to_string())?;
        return crate::summary_engine::generate_with_builtin_stream(
            app_data_dir,
            model_name,
            system_prompt,
            user_prompt,
            cancellation_token,
            |delta| on_delta(delta),
        )
        .await
        .map_err(|e| e.to_string());
    }

    // Claude CLI: no incremental protocol wired — produce the full answer, emit once.
    if provider == &LLMProvider::ClaudeCLI {
        let full = crate::summary::claude_cli::generate_with_claude_cli(
            model_name,
            system_prompt,
            user_prompt,
            cancellation_token,
        )
        .await?;
        if !full.is_empty() {
            on_delta(&full);
        }
        return Ok(full);
    }

    // Apple FoundationModels: same graceful fallback.
    if provider == &LLMProvider::AppleFoundation {
        let full = crate::apple::helper::summarize(
            user_prompt,
            system_prompt,
            max_tokens.unwrap_or(512),
            cancellation_token,
        )
        .await?;
        if !full.is_empty() {
            on_delta(&full);
        }
        return Ok(full);
    }

    // ---- HTTP providers (SSE) ----
    let is_claude = provider == &LLMProvider::Claude;

    let (api_url, mut headers) = match provider {
        LLMProvider::OpenAI => (
            "https://api.openai.com/v1/chat/completions".to_string(),
            header::HeaderMap::new(),
        ),
        LLMProvider::Groq => (
            "https://api.groq.com/openai/v1/chat/completions".to_string(),
            header::HeaderMap::new(),
        ),
        LLMProvider::OpenRouter => (
            "https://openrouter.ai/api/v1/chat/completions".to_string(),
            header::HeaderMap::new(),
        ),
        LLMProvider::Ollama => {
            let host = ollama_endpoint
                .map(|s| s.to_string())
                .unwrap_or_else(|| "http://localhost:11434".to_string());
            (format!("{}/v1/chat/completions", host), header::HeaderMap::new())
        }
        LLMProvider::CustomOpenAI => {
            let endpoint = custom_openai_endpoint
                .ok_or_else(|| "Custom OpenAI endpoint not configured".to_string())?;
            (
                format!("{}/chat/completions", endpoint.trim_end_matches('/')),
                header::HeaderMap::new(),
            )
        }
        LLMProvider::Claude => {
            let mut header_map = header::HeaderMap::new();
            header_map.insert(
                "x-api-key",
                api_key.parse().map_err(|_| "Invalid API key format".to_string())?,
            );
            header_map.insert(
                "anthropic-version",
                "2023-06-01".parse().map_err(|_| "Invalid anthropic version".to_string())?,
            );
            ("https://api.anthropic.com/v1/messages".to_string(), header_map)
        }
        // Handled above with early returns.
        LLMProvider::BuiltInAI | LLMProvider::ClaudeCLI | LLMProvider::AppleFoundation => {
            unreachable!("local providers handled before the HTTP match")
        }
    };

    if !is_claude {
        headers.insert(
            header::AUTHORIZATION,
            format!("Bearer {}", api_key)
                .parse()
                .map_err(|_| "Invalid authorization header".to_string())?,
        );
    }
    headers.insert(
        header::CONTENT_TYPE,
        "application/json".parse().map_err(|_| "Invalid content type".to_string())?,
    );

    // Body with `stream: true`. Built manually (serde_json) so we don't touch the
    // upstream ChatRequest/ClaudeRequest structs.
    let request_body = if is_claude {
        serde_json::json!({
            "model": model_name,
            "max_tokens": 2048,
            "system": system_prompt,
            "stream": true,
            "messages": [ChatMessage { role: "user".to_string(), content: user_prompt.to_string() }],
        })
    } else {
        let apply_params = provider == &LLMProvider::CustomOpenAI;
        let mut body = serde_json::json!({
            "model": model_name,
            "stream": true,
            "messages": [
                ChatMessage { role: "system".to_string(), content: system_prompt.to_string() },
                ChatMessage { role: "user".to_string(), content: user_prompt.to_string() },
            ],
        });
        if apply_params {
            if let Some(m) = max_tokens {
                body["max_tokens"] = serde_json::json!(m);
            }
            if let Some(t) = temperature {
                body["temperature"] = serde_json::json!(t);
            }
            if let Some(p) = top_p {
                body["top_p"] = serde_json::json!(p);
            }
        }
        body
    };

    let request_future = client
        .post(api_url)
        .headers(headers)
        .json(&request_body)
        .timeout(REQUEST_TIMEOUT_DURATION)
        .send();

    let response = if let Some(token) = cancellation_token {
        tokio::select! {
            result = request_future => result.map_err(|e| format!("Failed to send request to LLM: {}", e))?,
            _ = token.cancelled() => return Err("Answer generation was cancelled".to_string()),
        }
    } else {
        request_future
            .await
            .map_err(|e| format!("Failed to send request to LLM: {}", e))?
    };

    if !response.status().is_success() {
        let error_body = response.text().await.unwrap_or_else(|_| "Unknown error".to_string());
        return Err(format!("LLM API request failed: {}", error_body));
    }

    // Byte-buffer the SSE body and decode only complete lines, so a multi-byte
    // UTF-8 character split across network chunks is never corrupted.
    let mut stream = response.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    let mut full = String::new();

    while let Some(chunk) = stream.next().await {
        if let Some(token) = cancellation_token {
            if token.is_cancelled() {
                return Err("Answer generation was cancelled".to_string());
            }
        }
        let chunk = chunk.map_err(|e| format!("LLM stream error: {}", e))?;
        buf.extend_from_slice(&chunk);

        // Drain complete newline-terminated lines.
        while let Some(nl) = buf.iter().position(|&b| b == b'\n') {
            let line_bytes: Vec<u8> = buf.drain(..=nl).collect();
            let line = String::from_utf8_lossy(&line_bytes);
            let line = line.trim();
            let Some(data) = line.strip_prefix("data:") else {
                continue; // SSE `event:`/comment/blank lines
            };
            let data = data.trim();
            if data.is_empty() || data == "[DONE]" {
                continue;
            }
            let Ok(value) = serde_json::from_str::<serde_json::Value>(data) else {
                continue;
            };
            let delta = extract_delta(is_claude, &value);
            if !delta.is_empty() {
                on_delta(&delta);
                full.push_str(&delta);
            }
        }
    }

    Ok(full)
}

/// Pull the incremental text out of one parsed SSE event.
fn extract_delta(is_claude: bool, value: &serde_json::Value) -> String {
    if is_claude {
        // Anthropic: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
        value
            .get("delta")
            .and_then(|d| d.get("text"))
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string()
    } else {
        // OpenAI-compatible: {"choices":[{"delta":{"content":"..."}}]}
        value
            .get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("delta"))
            .and_then(|d| d.get("content"))
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string()
    }
}
