//! Global language-preference storage, moved verbatim out of the Tauri host crate
//! (Stage B1 of the ari-engine carve). Pure `std::sync` global state, zero Tauri deps.

use std::sync::Mutex as StdMutex;

// Global language preference storage (default to "auto-translate" for automatic translation to English)
static LANGUAGE_PREFERENCE: std::sync::LazyLock<StdMutex<String>> =
    std::sync::LazyLock::new(|| StdMutex::new("auto-translate".to_string()));

pub fn set_language_preference_internal(language: String) -> Result<(), String> {
    let mut lang_pref = LANGUAGE_PREFERENCE
        .lock()
        .map_err(|e| format!("Failed to set language preference: {}", e))?;
    *lang_pref = language;
    Ok(())
}

/// Internal helper function to get language preference (for use within Rust code)
pub fn get_language_preference_internal() -> Option<String> {
    LANGUAGE_PREFERENCE.lock().ok().map(|lang| lang.clone())
}
