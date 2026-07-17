#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

// Logging is owned by `tauri-plugin-log` (registered in `app_lib::run()`),
// which writes a rolling file to the OS log dir plus stdout. We deliberately
// do NOT call `env_logger::init()` here — the `log` crate allows only one
// global logger, and env_logger would claim the slot before the plugin can.
fn main() {
    app_lib::run();
}
