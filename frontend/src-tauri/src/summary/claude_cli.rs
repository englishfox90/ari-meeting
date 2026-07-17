//! Claude CLI provider (additive)
//!
//! Uses the user's **locally installed** Claude Code CLI (`claude`) as a
//! summarization provider. No API key is stored in Ari — the CLI supplies its
//! own authentication (interactive login / keychain / `ANTHROPIC_API_KEY`).
//!
//! Like the BuiltInAI provider, this does not go over HTTP: it spawns the
//! `claude` binary in non-interactive ("print") mode and reads stdout.
//! `llm_client::generate_summary` early-returns into this module before its
//! HTTP `match provider` block.

use serde::Serialize;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

/// How long to wait for a single Claude CLI invocation before giving up.
const CLAUDE_CLI_TIMEOUT: Duration = Duration::from_secs(300);

/// Detection result for the frontend so it can show honest status
/// (installed path / version) rather than fake state.
#[derive(Debug, Clone, Serialize)]
pub struct ClaudeCliStatus {
    pub installed: bool,
    pub path: Option<String>,
    pub version: Option<String>,
}

/// Resolve the `claude` binary path.
///
/// A macOS `.app` bundle inherits a minimal PATH (not the user's shell PATH),
/// so we (1) ask a login shell where `claude` lives, then (2) fall back to the
/// well-known install locations.
pub fn resolve_claude_binary() -> Option<PathBuf> {
    if let Some(p) = resolve_via_login_shell() {
        return Some(p);
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(home) = std::env::var("HOME") {
        candidates.push(PathBuf::from(&home).join(".claude/local/claude"));
        candidates.push(PathBuf::from(&home).join(".local/bin/claude"));
    }
    candidates.push(PathBuf::from("/opt/homebrew/bin/claude"));
    candidates.push(PathBuf::from("/usr/local/bin/claude"));

    candidates.into_iter().find(|p| p.exists())
}

/// Ask the user's login shell to resolve `claude` (respects Homebrew, native
/// installer, and `/etc/paths`). Uses `-lc` (login, non-interactive) to avoid a
/// tty-less interactive shell hanging.
fn resolve_via_login_shell() -> Option<PathBuf> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let output = std::process::Command::new(&shell)
        .args(["-lc", "command -v claude"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    // `command -v` can emit multiple lines for aliases/functions; the resolved
    // path is the last non-empty line.
    let last = stdout.lines().map(str::trim).filter(|l| !l.is_empty()).last()?;
    let pb = PathBuf::from(last);
    if pb.exists() {
        Some(pb)
    } else {
        None
    }
}

/// Synchronous detection helper (spawns subprocesses; call off the async executor).
pub fn detect_claude_cli() -> ClaudeCliStatus {
    match resolve_claude_binary() {
        Some(bin) => {
            let version = std::process::Command::new(&bin)
                .arg("--version")
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .filter(|s| !s.is_empty());
            ClaudeCliStatus {
                installed: true,
                path: Some(bin.to_string_lossy().to_string()),
                version,
            }
        }
        None => ClaudeCliStatus {
            installed: false,
            path: None,
            version: None,
        },
    }
}

/// Generate a summary by shelling out to the local Claude CLI in print mode.
///
/// `model_name` may be an alias (`opus`/`sonnet`/`haiku`) or a full model id;
/// `"default"`/empty means "use the CLI's configured default" (no `--model`).
pub async fn generate_with_claude_cli(
    model_name: &str,
    system_prompt: &str,
    user_prompt: &str,
    cancellation_token: Option<&CancellationToken>,
) -> Result<String, String> {
    if let Some(token) = cancellation_token {
        if token.is_cancelled() {
            return Err("Summary generation was cancelled".to_string());
        }
    }

    let bin = resolve_claude_binary().ok_or_else(|| {
        "Claude CLI not found. Install Claude Code and make sure `claude` is on your PATH."
            .to_string()
    })?;

    // Fully replace the default agentic system prompt with our summarization
    // instruction so the CLI behaves as a plain completion endpoint.
    let mut args: Vec<String> = vec![
        "-p".to_string(),
        user_prompt.to_string(),
        "--system-prompt".to_string(),
        system_prompt.to_string(),
        "--output-format".to_string(),
        "text".to_string(),
    ];

    let model = model_name.trim();
    if !model.is_empty() && !model.eq_ignore_ascii_case("default") {
        args.push("--model".to_string());
        args.push(model.to_string());
    }

    // Run in a neutral cwd so the project's CLAUDE.md / skills are not loaded.
    let cwd = std::env::temp_dir();

    let mut cmd = tokio::process::Command::new(&bin);
    cmd.args(&args)
        .current_dir(&cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let child = cmd
        .spawn()
        .map_err(|e| format!("Failed to launch Claude CLI: {}", e))?;

    let run = async move {
        let output = child
            .wait_with_output()
            .await
            .map_err(|e| format!("Claude CLI failed: {}", e))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "Claude CLI exited with an error: {}",
                stderr.trim()
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    };

    // Race the run against cancellation and a hard timeout. `kill_on_drop`
    // ensures the child is terminated if either fires.
    if let Some(token) = cancellation_token {
        tokio::select! {
            r = tokio::time::timeout(CLAUDE_CLI_TIMEOUT, run) => {
                r.map_err(|_| "Claude CLI timed out".to_string())?
            }
            _ = token.cancelled() => Err("Summary generation was cancelled".to_string()),
        }
    } else {
        tokio::time::timeout(CLAUDE_CLI_TIMEOUT, run)
            .await
            .map_err(|_| "Claude CLI timed out".to_string())?
    }
}

/// Tauri command: report whether the local Claude CLI is available.
#[tauri::command]
pub async fn claude_cli_detect() -> Result<ClaudeCliStatus, String> {
    tauri::async_runtime::spawn_blocking(detect_claude_cli)
        .await
        .map_err(|e| format!("Claude CLI detection failed: {}", e))
}
