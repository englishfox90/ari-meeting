//! Locate the `apple-helper` sidecar binary.
//!
//! This is a PURPOSE-BUILT resolver for the Apple helper — it deliberately does
//! NOT reuse `summary::summary_engine::sidecar::resolve_helper_binary`, which is
//! hard-coded to the base name `llama-helper` and wraps spawns in `nice -n 10`.
//! The apple-helper has its own base name and env override, and must never be
//! `nice`d.
//!
//! Search order:
//! 1. `ARI_APPLE_HELPER_BIN` env override (dev / manual).
//! 2. Next to the running executable: `apple-helper-aarch64-apple-darwin`
//!    (exact match, then a fuzzy `apple-helper*` scan of the exe dir — Tauri
//!    stages `externalBin` sidecars beside the app binary with a target-triple
//!    suffix).
//! 3. Dev fallback: `<workspace>/target/{release,debug}/apple-helper`.
//!
//! Returns `Err` when nothing is found. Callers MUST treat that as "no Apple
//! helper available" (log at debug, no error/panic) — the app runs fine without
//! it and reports availability honestly.

use std::path::PathBuf;

use anyhow::{anyhow, Result};

/// Base name of the Apple helper sidecar binary.
const BIN_BASE: &str = "apple-helper";

/// The only target triple this macOS-only app ships for.
const TARGET_TRIPLE: &str = "aarch64-apple-darwin";

/// Resolve the path to the `apple-helper` sidecar binary, or `Err` if absent.
pub fn resolve_apple_binary() -> Result<PathBuf> {
    // 1. Environment override (dev mode or manual staging).
    if let Ok(env_path) = std::env::var("ARI_APPLE_HELPER_BIN") {
        if !env_path.is_empty() {
            let path = PathBuf::from(env_path);
            if path.exists() {
                log::debug!(
                    "apple-helper: using ARI_APPLE_HELPER_BIN override: {}",
                    path.display()
                );
                return Ok(path);
            }
            log::debug!("apple-helper: ARI_APPLE_HELPER_BIN set but path does not exist");
        }
    }

    // 2. Bundled next to the executable (production `.app` / dev bundle).
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            let exact = exe_dir.join(format!("{BIN_BASE}-{TARGET_TRIPLE}"));
            if exact.exists() {
                log::debug!("apple-helper: found bundled binary {}", exact.display());
                return Ok(exact);
            }
            // Fuzzy: any `apple-helper*` sibling (ignore cargo `.d` depfiles).
            if let Ok(entries) = std::fs::read_dir(exe_dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                        if name.starts_with(BIN_BASE) && !name.ends_with(".d") {
                            log::debug!("apple-helper: fuzzy-matched {}", path.display());
                            return Ok(path);
                        }
                    }
                }
            }
        }
    }

    // 3. Dev fallback: workspace target dir. CARGO_MANIFEST_DIR at runtime is
    //    `frontend/src-tauri`; two parents up is the repo root that holds `target/`.
    if let Ok(manifest_dir) = std::env::var("CARGO_MANIFEST_DIR") {
        if let Some(root) = PathBuf::from(&manifest_dir)
            .parent()
            .and_then(|p| p.parent())
            .map(|p| p.to_path_buf())
        {
            for candidate in [
                root.join("target/release").join(BIN_BASE),
                root.join("target/debug").join(BIN_BASE),
            ] {
                if candidate.exists() {
                    log::debug!("apple-helper: using dev binary {}", candidate.display());
                    return Ok(candidate);
                }
            }
        }
    }

    Err(anyhow!(
        "apple-helper binary not found (set ARI_APPLE_HELPER_BIN or build the sidecar)"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_binary_is_err_not_panic() {
        // With no ARI_APPLE_HELPER_BIN and (almost certainly) no staged binary in
        // the test runner's exe dir, this must return gracefully — never panic.
        std::env::remove_var("ARI_APPLE_HELPER_BIN");
        let _ = resolve_apple_binary(); // result may be Ok or Err depending on env; must not panic
    }

    #[test]
    fn env_override_to_nonexistent_is_ignored() {
        std::env::set_var(
            "ARI_APPLE_HELPER_BIN",
            "/definitely/not/a/real/apple-helper-binary",
        );
        // Should fall through past the override without returning that bogus path.
        let resolved = resolve_apple_binary();
        if let Ok(p) = resolved {
            assert_ne!(
                p,
                PathBuf::from("/definitely/not/a/real/apple-helper-binary")
            );
        }
        std::env::remove_var("ARI_APPLE_HELPER_BIN");
    }
}
