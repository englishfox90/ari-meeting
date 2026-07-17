use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex as StdMutex;
// Removed unused import

// Performance optimization: Conditional logging macros for hot paths
#[cfg(debug_assertions)]
macro_rules! perf_debug {
    ($($arg:tt)*) => {
        log::debug!($($arg)*)
    };
}

#[cfg(not(debug_assertions))]
macro_rules! perf_debug {
    ($($arg:tt)*) => {};
}

#[cfg(debug_assertions)]
macro_rules! perf_trace {
    ($($arg:tt)*) => {
        log::trace!($($arg)*)
    };
}

#[cfg(not(debug_assertions))]
macro_rules! perf_trace {
    ($($arg:tt)*) => {};
}

// Make these macros available to other modules
pub(crate) use perf_debug;
pub(crate) use perf_trace;

// Re-export async logging macros for external use (removed due to macro conflicts)

// Declare audio module
pub mod analytics;
pub mod api;
pub mod app_config;
pub mod apple;
pub mod audio;
pub mod calendar;
pub mod config;
pub mod console_utils;
pub mod database;
pub mod diarization;
pub mod engine;
pub mod logging;
pub mod meeting_series;
pub mod meeting_time;
pub mod notch;
pub mod notifications;
pub mod ollama;
pub mod onboarding;
pub mod openai;
pub mod anthropic;
pub mod groq;
pub mod openrouter;
pub mod parakeet_engine;
pub mod persons;
pub mod recall;
pub mod state;
pub mod summary;
pub mod tray;
pub mod utils;
pub mod whisper_engine;

use audio::{list_audio_devices, AudioDevice};
#[cfg(target_os = "macos")]
use audio::request_audio_permission_on_main;
#[cfg(not(target_os = "macos"))]
use audio::trigger_audio_permission;
use log::{error as log_error, info as log_info};
use notifications::commands::NotificationManagerState;
use std::sync::Arc;
use tauri::{AppHandle, Manager, Runtime};
use tokio::sync::RwLock;

static RECORDING_FLAG: AtomicBool = AtomicBool::new(false);

// Global language preference storage (default to "auto-translate" for automatic translation to English)
static LANGUAGE_PREFERENCE: std::sync::LazyLock<StdMutex<String>> =
    std::sync::LazyLock::new(|| StdMutex::new("auto-translate".to_string()));

#[derive(Debug, Deserialize)]
struct RecordingArgs {
    save_path: String,
}

#[derive(Debug, Serialize, Clone)]
struct TranscriptionStatus {
    chunks_in_queue: usize,
    is_processing: bool,
    last_activity_ms: u64,
}

#[tauri::command]
async fn start_recording<R: Runtime>(
    app: AppHandle<R>,
    mic_device_name: Option<String>,
    system_device_name: Option<String>,
    meeting_name: Option<String>,
) -> Result<(), String> {
    log_info!("🔥 CALLED start_recording with meeting: {:?}", meeting_name);
    log_info!(
        "📋 Backend received parameters - mic: {:?}, system: {:?}, meeting: {:?}",
        mic_device_name,
        system_device_name,
        meeting_name
    );

    if is_recording().await {
        return Err("Recording already in progress".to_string());
    }

    // Call the actual audio recording system with meeting name
    match audio::recording_commands::start_recording_with_devices_and_meeting(
        app.clone(),
        mic_device_name,
        system_device_name,
        meeting_name.clone(),
    )
    .await
    {
        Ok(_) => {
            RECORDING_FLAG.store(true, Ordering::SeqCst);
            tray::update_tray_menu(&app);

            log_info!("Recording started successfully");

            // Show recording started notification through NotificationManager
            // This respects user's notification preferences
            let notification_manager_state = app.state::<NotificationManagerState<R>>();
            if let Err(e) = notifications::commands::show_recording_started_notification(
                &app,
                &notification_manager_state,
                meeting_name.clone(),
            )
            .await
            {
                log_error!(
                    "Failed to show recording started notification: {}",
                    e
                );
            } else {
                log_info!("Successfully showed recording started notification");
            }

            Ok(())
        }
        Err(e) => {
            log_error!("Failed to start audio recording: {}", e);
            Err(format!("Failed to start recording: {}", e))
        }
    }
}

#[tauri::command]
async fn stop_recording<R: Runtime>(app: AppHandle<R>, args: RecordingArgs) -> Result<(), String> {
    log_info!("Attempting to stop recording...");

    // Check the actual audio recording system state instead of the flag
    if !audio::recording_commands::is_recording().await {
        log_info!("Recording is already stopped");
        return Ok(());
    }

    // Call the actual audio recording system to stop
    match audio::recording_commands::stop_recording(
        app.clone(),
        audio::recording_commands::RecordingArgs {
            save_path: args.save_path.clone(),
        },
    )
    .await
    {
        Ok(_) => {
            RECORDING_FLAG.store(false, Ordering::SeqCst);
            tray::update_tray_menu(&app);

            // Create the save directory if it doesn't exist
            if let Some(parent) = std::path::Path::new(&args.save_path).parent() {
                if !parent.exists() {
                    log_info!("Creating directory: {:?}", parent);
                    if let Err(e) = std::fs::create_dir_all(parent) {
                        let err_msg = format!("Failed to create save directory: {}", e);
                        log_error!("{}", err_msg);
                        return Err(err_msg);
                    }
                }
            }

            // Show recording stopped notification through NotificationManager
            // This respects user's notification preferences
            let notification_manager_state = app.state::<NotificationManagerState<R>>();
            if let Err(e) = notifications::commands::show_recording_stopped_notification(
                &app,
                &notification_manager_state,
            )
            .await
            {
                log_error!(
                    "Failed to show recording stopped notification: {}",
                    e
                );
            } else {
                log_info!("Successfully showed recording stopped notification");
            }

            Ok(())
        }
        Err(e) => {
            log_error!("Failed to stop audio recording: {}", e);
            // Still update the flag even if stopping failed
            RECORDING_FLAG.store(false, Ordering::SeqCst);
            tray::update_tray_menu(&app);
            Err(format!("Failed to stop recording: {}", e))
        }
    }
}

#[tauri::command]
async fn is_recording() -> bool {
    audio::recording_commands::is_recording().await
}

#[tauri::command]
fn get_transcription_status() -> TranscriptionStatus {
    TranscriptionStatus {
        chunks_in_queue: 0,
        is_processing: false,
        last_activity_ms: 0,
    }
}

#[tauri::command]
fn read_audio_file(file_path: String) -> Result<tauri::ipc::Response, String> {
    // Return raw bytes via the IPC binary channel (received as an ArrayBuffer on the
    // frontend). Returning `Vec<u8>` instead serializes the file as a JSON array of
    // numbers — for a 100+ MB recording that is a multi-hundred-MB JSON payload whose
    // synchronous deserialization froze the WebView main thread for ~30s on open.
    match std::fs::read(&file_path) {
        Ok(data) => Ok(tauri::ipc::Response::new(data)),
        Err(e) => Err(format!("Failed to read audio file: {}", e)),
    }
}

#[tauri::command]
async fn save_transcript(file_path: String, content: String) -> Result<(), String> {
    log_info!("Saving transcript to: {}", file_path);

    // Ensure parent directory exists
    if let Some(parent) = std::path::Path::new(&file_path).parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("Failed to create directory: {}", e))?;
        }
    }

    // Write content to file
    std::fs::write(&file_path, content)
        .map_err(|e| format!("Failed to write transcript: {}", e))?;

    log_info!("Transcript saved successfully");
    Ok(())
}

// Audio level monitoring commands
#[tauri::command]
async fn start_audio_level_monitoring<R: Runtime>(
    app: AppHandle<R>,
    device_names: Vec<String>,
) -> Result<(), String> {
    log_info!(
        "Starting audio level monitoring for devices: {:?}",
        device_names
    );

    audio::simple_level_monitor::start_monitoring(app, device_names)
        .await
        .map_err(|e| format!("Failed to start audio level monitoring: {}", e))
}

#[tauri::command]
async fn stop_audio_level_monitoring() -> Result<(), String> {
    log_info!("Stopping audio level monitoring");

    audio::simple_level_monitor::stop_monitoring()
        .await
        .map_err(|e| format!("Failed to stop audio level monitoring: {}", e))
}

// Analytics commands are now handled by analytics::commands module

// Whisper commands are now handled by whisper_engine::commands module

#[tauri::command]
async fn get_audio_devices() -> Result<Vec<AudioDevice>, String> {
    list_audio_devices()
        .await
        .map_err(|e| format!("Failed to list audio devices: {}", e))
}

#[tauri::command]
async fn trigger_microphone_permission(app: AppHandle) -> Result<bool, String> {
    #[cfg(target_os = "macos")]
    {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        app.run_on_main_thread(move || request_audio_permission_on_main(sender))
            .map_err(|error| format!("Failed to schedule microphone permission request: {error}"))?;
        return tokio::time::timeout(std::time::Duration::from_secs(60), receiver)
            .await
            .map_err(|_| "Timed out waiting for microphone authorization.".to_string())?
            .map_err(|_| "Microphone permission request was cancelled.".to_string())?;
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        tokio::task::spawn_blocking(trigger_audio_permission)
            .await
            .map_err(|e| format!("Microphone permission task failed: {}", e))?
            .map_err(|e| format!("Failed to trigger microphone permission: {}", e))
    }
}

#[tauri::command]
async fn start_recording_with_devices_and_meeting<R: Runtime>(
    app: AppHandle<R>,
    mic_device_name: Option<String>,
    system_device_name: Option<String>,
    meeting_name: Option<String>,
) -> Result<(), String> {
    log_info!("🚀 CALLED start_recording_with_devices_and_meeting - Mic: {:?}, System: {:?}, Meeting: {:?}",
             mic_device_name, system_device_name, meeting_name);

    // Clone meeting_name for notification use later
    let meeting_name_for_notification = meeting_name.clone();

    // Call the recording module functions that support meeting names
    let recording_result = match (mic_device_name.clone(), system_device_name.clone()) {
        (None, None) => {
            log_info!(
                "No devices specified, starting with defaults and meeting: {:?}",
                meeting_name
            );
            audio::recording_commands::start_recording_with_meeting_name(app.clone(), meeting_name)
                .await
        }
        _ => {
            log_info!(
                "Starting with specified devices: mic={:?}, system={:?}, meeting={:?}",
                mic_device_name,
                system_device_name,
                meeting_name
            );
            audio::recording_commands::start_recording_with_devices_and_meeting(
                app.clone(),
                mic_device_name,
                system_device_name,
                meeting_name,
            )
            .await
        }
    };

    match recording_result {
        Ok(_) => {
            log_info!("Recording started successfully via tauri command");

            // Show recording started notification through NotificationManager
            // This respects user's notification preferences
            let notification_manager_state = app.state::<NotificationManagerState<R>>();
            if let Err(e) = notifications::commands::show_recording_started_notification(
                &app,
                &notification_manager_state,
                meeting_name_for_notification.clone(),
            )
            .await
            {
                log_error!(
                    "Failed to show recording started notification: {}",
                    e
                );
            }

            Ok(())
        }
        Err(e) => {
            log_error!("Failed to start recording via tauri command: {}", e);
            Err(e)
        }
    }
}

#[tauri::command]
async fn set_language_preference(language: String) -> Result<(), String> {
    let mut lang_pref = LANGUAGE_PREFERENCE
        .lock()
        .map_err(|e| format!("Failed to set language preference: {}", e))?;
    log_info!("Setting language preference to: {}", language);
    *lang_pref = language;
    Ok(())
}

// Internal helper function to get language preference (for use within Rust code)
pub fn get_language_preference_internal() -> Option<String> {
    LANGUAGE_PREFERENCE.lock().ok().map(|lang| lang.clone())
}

pub fn run() {
    log::set_max_level(log::LevelFilter::Info);

    let mut builder = tauri::Builder::default();

    // Register file+stdout logging first so every subsequent plugin/setup log
    // line is persisted to the rolling log file (see `logging` module).
    builder = builder.plugin(logging::plugin());

    #[cfg(any(target_os = "macos", windows, target_os = "linux"))]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, args, cwd| {
            log_info!(
                "Second app instance requested with args: {:?}, cwd: {:?}",
                args,
                cwd
            );

            tray::focus_main_window(app);
        }));
    }

    builder
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .manage(whisper_engine::parallel_commands::ParallelProcessorState::new())
        .manage(Arc::new(RwLock::new(
            None::<notifications::manager::NotificationManager<tauri::Wry>>,
        )) as NotificationManagerState<tauri::Wry>)
        .manage(audio::init_system_audio_state())
        .manage(summary::summary_engine::ModelManagerState(Arc::new(tokio::sync::Mutex::new(None))))
        .manage(recall::embed_models::EmbedModelManagerState::new())
        .setup(|_app| {
            log::info!("Application setup complete");

            // Build the headless-engine context (Stage A of the ari-engine
            // carve — docs/plans/ari-engine-carve.md). Managed here, before the
            // DB init block_on below, so `State<'_, Arc<Engine>>` is available
            // to every command. It is *live but not yet consumed* — commands
            // still use the legacy `AppState`/managed states until each service
            // migrates onto `&Engine`, so this changes no runtime behavior.
            {
                use tauri::Manager as _;
                let paths = engine::Paths::from_tauri(_app.handle())
                    .expect("Failed to resolve engine paths");
                let events: std::sync::Arc<dyn engine::EventSink> =
                    std::sync::Arc::new(engine::TauriEventSink::new(_app.handle().clone()));
                // Share the SAME inner Arcs as the separately-managed sub-states
                // (managed above in the builder chain), so startup init that
                // writes through the managed state is visible via engine.*().
                let parallel = _app.state::<whisper_engine::parallel_commands::ParallelProcessorState>();
                let summary_models = _app.state::<summary::summary_engine::ModelManagerState>();
                let embed_models = _app.state::<recall::embed_models::EmbedModelManagerState>();
                let shared_parallel = whisper_engine::parallel_commands::ParallelProcessorState {
                    processor: parallel.processor.clone(),
                    system_monitor: parallel.system_monitor.clone(),
                };
                let shared_summary = summary::summary_engine::ModelManagerState(summary_models.0.clone());
                let shared_embed = recall::embed_models::EmbedModelManagerState(embed_models.0.clone());
                _app.manage(std::sync::Arc::new(engine::Engine::new(
                    paths,
                    events,
                    shared_parallel,
                    shared_summary,
                    shared_embed,
                )));
            }

            // Enforce the rolling log-retention window on startup.
            if let Ok(log_dir) = _app.handle().path().app_log_dir() {
                logging::prune_old_logs(&log_dir);
                log::info!("📝 Logs: {}", log_dir.display());
            }

            if tray::menu_bar_enabled(_app.handle()) {
                if let Err(e) = tray::create_tray(_app.handle()) {
                    log::error!("Failed to create system tray: {}", e);
                }
            }

            // Initialize notification system with proper defaults
            log::info!("Initializing notification system...");
            let app_for_notif = _app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let notif_state = app_for_notif.state::<NotificationManagerState<tauri::Wry>>();
                match notifications::commands::initialize_notification_manager(app_for_notif.clone()).await {
                    Ok(manager) => {
                        // Set default consent and permissions on first launch
                        if let Err(e) = manager.set_consent(true).await {
                            log::error!("Failed to set initial consent: {}", e);
                        }
                        if let Err(e) = manager.request_permission().await {
                            log::error!("Failed to request initial permission: {}", e);
                        }

                        // Store the initialized manager
                        let mut state_lock = notif_state.write().await;
                        *state_lock = Some(manager);
                        log::info!("Notification system initialized with default permissions");
                    }
                    Err(e) => {
                        log::error!("Failed to initialize notification manager: {}", e);
                    }
                }
            });

            // Set models directory to use app_data_dir (unified storage location)
            whisper_engine::commands::set_models_directory(&_app.handle());

            // Initialize Whisper engine on startup
            tauri::async_runtime::spawn(async {
                if let Err(e) = whisper_engine::commands::whisper_init().await {
                    log::error!("Failed to initialize Whisper engine on startup: {}", e);
                }
            });

            // Set Parakeet models directory
            parakeet_engine::commands::set_models_directory(&_app.handle());

            // Initialize Parakeet engine on startup
            tauri::async_runtime::spawn(async {
                if let Err(e) = parakeet_engine::commands::parakeet_init().await {
                    log::error!("Failed to initialize Parakeet engine on startup: {}", e);
                }
            });

            // Initialize ModelManager for summary engine (async, non-blocking)
            let app_handle_for_model_manager = _app.handle().clone();
            tauri::async_runtime::spawn(async move {
                match summary::summary_engine::commands::init_model_manager_at_startup(&app_handle_for_model_manager).await {
                    Ok(_) => log::info!("ModelManager initialized successfully at startup"),
                    Err(e) => {
                        log::warn!("Failed to initialize ModelManager at startup: {}", e);
                        log::warn!("ModelManager will be lazy-initialized on first use");
                    }
                }
            });

            // Trigger system audio permission request on startup (similar to microphone permission)
            // #[cfg(target_os = "macos")]
            // {
            //     tauri::async_runtime::spawn(async {
            //         if let Err(e) = audio::permissions::trigger_system_audio_permission() {
            //             log::warn!("Failed to trigger system audio permission: {}", e);
            //         }
            //     });
            // }

            // Initialize database (handles first launch detection and conditional setup)
            tauri::async_runtime::block_on(async {
                database::setup::initialize_database_on_startup(&_app.handle()).await
            })
            .expect("Failed to initialize database");

            // Periodic calendar background sync (F4 Phase 2) — runs on its own loop,
            // independent of any command call; safe to spawn now that AppState is managed.
            calendar::sync::spawn_background_sync(_app.handle().clone());

            // Recall (F7): backfill the semantic index for existing meetings in the
            // background. Idempotent + self-guarded (skips already-indexed, re-embeds
            // lexical-only meetings once the embedder is available); new meetings also
            // index on save. Best-effort — never blocks startup.
            {
                // Make the app-data dir available to the recall embedder (GGUF sidecar model
                // path) without threading it through detached index tasks.
                if let Ok(dir) = _app.handle().path().app_data_dir() {
                    recall::embedding::set_app_data_dir(dir);
                }
                let app_handle_for_recall = _app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    let pool = {
                        let state = app_handle_for_recall.state::<state::AppState>();
                        state.db_manager.pool().clone()
                    };
                    match recall::indexer::reindex_all(&pool, false).await {
                        Ok(count) => {
                            log::info!("recall: startup backfill processed {count} meeting(s)")
                        }
                        Err(error) => log::warn!("recall: startup backfill failed: {error}"),
                    }
                });
            }

            // Ari Notch (WS-B) — start the sidecar bridge if `showNotch` is set.
            // Best-effort: no-ops when the pref is off or the binary is absent.
            notch::bridge::init_at_startup(_app.handle().clone());

            // Ari Notch (WS-D) — reminder scheduler that fires upcoming-meeting
            // alerts to the notch + the system notification path (completes F5).
            // Reads cached calendar events; best-effort, never blocks startup.
            notch::scheduler::spawn_scheduler(_app.handle().clone());

            // Initialize bundled templates directory for dynamic template discovery
            log::info!("Initializing bundled templates directory...");
            if let Ok(resource_path) = _app.handle().path().resource_dir() {
                let templates_dir = resource_path.join("templates");
                log::info!("Setting bundled templates directory to: {:?}", templates_dir);
                summary::templates::set_bundled_templates_dir(templates_dir);
            } else {
                log::warn!("Failed to resolve resource directory for templates");
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                #[cfg(target_os = "macos")]
                let _ = (window, api);

                #[cfg(not(target_os = "macos"))]
                if window.label() == "main" {
                    api.prevent_close();
                    if let Err(e) = window.hide() {
                        log::error!("Failed to hide main window on close request: {}", e);
                    } else {
                        log::info!("Main window hidden to tray on close request");
                    }
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            start_recording,
            stop_recording,
            is_recording,
            get_transcription_status,
            read_audio_file,
            save_transcript,
            analytics::commands::track_meeting_ended,
            whisper_engine::commands::whisper_init,
            whisper_engine::commands::whisper_get_available_models,
            whisper_engine::commands::whisper_load_model,
            whisper_engine::commands::whisper_get_current_model,
            whisper_engine::commands::whisper_is_model_loaded,
            whisper_engine::commands::whisper_has_available_models,
            whisper_engine::commands::whisper_validate_model_ready,
            whisper_engine::commands::whisper_transcribe_audio,
            whisper_engine::commands::whisper_get_models_directory,
            whisper_engine::commands::whisper_download_model,
            whisper_engine::commands::whisper_cancel_download,
            whisper_engine::commands::whisper_delete_corrupted_model,
            // Parakeet engine commands
            parakeet_engine::commands::parakeet_init,
            parakeet_engine::commands::parakeet_get_available_models,
            parakeet_engine::commands::parakeet_load_model,
            parakeet_engine::commands::parakeet_get_current_model,
            parakeet_engine::commands::parakeet_is_model_loaded,
            parakeet_engine::commands::parakeet_has_available_models,
            parakeet_engine::commands::parakeet_validate_model_ready,
            parakeet_engine::commands::parakeet_transcribe_audio,
            parakeet_engine::commands::parakeet_get_models_directory,
            parakeet_engine::commands::parakeet_download_model,
            parakeet_engine::commands::parakeet_retry_download,
            parakeet_engine::commands::parakeet_cancel_download,
            parakeet_engine::commands::parakeet_delete_corrupted_model,
            parakeet_engine::commands::open_parakeet_models_folder,
            // Parallel processing commands
            whisper_engine::parallel_commands::get_system_resources,
            get_audio_devices,
            trigger_microphone_permission,
            start_recording_with_devices_and_meeting,
            start_audio_level_monitoring,
            stop_audio_level_monitoring,
            // Recording pause/resume commands
            audio::recording_commands::pause_recording,
            audio::recording_commands::resume_recording,
            audio::recording_commands::is_recording_paused,
            audio::recording_commands::get_recording_state,
            audio::recording_commands::get_meeting_folder_path,
            // Reload sync commands (retrieve transcript history and meeting name)
            audio::recording_commands::get_transcript_history,
            audio::recording_commands::get_recording_meeting_name,
            // Playback device detection (Bluetooth warning)
            audio::recording_commands::get_active_audio_output,
            // Audio recovery commands (for transcript recovery feature)
            audio::incremental_saver::recover_audio_from_checkpoints,
            audio::incremental_saver::cleanup_checkpoints,
            audio::incremental_saver::has_audio_checkpoints,
            console_utils::show_console,
            console_utils::hide_console,
            console_utils::toggle_console,
            ollama::get_ollama_models,
            ollama::pull_ollama_model,
            ollama::delete_ollama_model,
            ollama::get_ollama_model_context,
            openai::openai::get_openai_models,
            anthropic::anthropic::get_anthropic_models,
            groq::groq::get_groq_models,
            api::api_get_meetings,
            api::api_search_transcripts,
            api::api_answer_meetings_locally,
            recall::stream::api_answer_meetings_locally_stream,
            recall::commands::recall_index_status,
            recall::commands::recall_reindex,
            recall::commands::recall_get_embedder,
            recall::commands::recall_set_embedder,
            recall::embed_models::recall_embedder_list_models,
            recall::embed_models::recall_embedder_download_model,
            recall::embed_models::recall_embedder_cancel_download,
            recall::embed_models::recall_embedder_delete_model,
            recall::conversations::ask_conversation_list,
            recall::conversations::ask_conversation_get,
            recall::conversations::ask_conversation_create,
            recall::conversations::ask_message_append,
            recall::conversations::ask_conversation_delete,
            api::api_get_model_config,
            api::api_save_model_config,
            api::api_get_api_key,
            // api::api_get_auto_generate_setting,
            // api::api_save_auto_generate_setting,
            api::api_get_transcript_config,
            api::api_save_transcript_config,
            api::api_get_transcript_api_key,
            api::api_delete_meeting,
            api::api_get_meeting,
            api::api_get_meeting_metadata,
            api::api_get_meeting_transcripts,
            api::api_save_meeting_title,
            api::api_export_meeting_locally,
            api::api_save_transcript,
            api::open_meeting_folder,
            api::api_get_meeting_template,
            api::open_external_url,
            // Custom OpenAI commands
            api::api_save_custom_openai_config,
            api::api_get_custom_openai_config,
            api::api_test_custom_openai_connection,
            // Summary commands
            summary::commands::api_process_transcript,
            summary::commands::api_get_summary,
            summary::commands::api_save_meeting_summary,
            summary::commands::api_get_meeting_summary_language,
            summary::commands::api_save_meeting_summary_language,
            summary::commands::api_get_meeting_detected_summary_language,
            summary::commands::api_save_meeting_detected_summary_language,
            summary::commands::api_detect_transcript_summary_language,
            summary::commands::api_cancel_summary,
            // Template commands
            summary::template_commands::api_list_templates,
            summary::template_selector::api_suggest_template,
            // Built-in AI commands
            summary::claude_cli::claude_cli_detect,
            summary::summary_engine::commands::builtin_ai_list_models,
            summary::summary_engine::commands::builtin_ai_get_model_info,
            summary::summary_engine::commands::builtin_ai_download_model,
            summary::summary_engine::commands::builtin_ai_cancel_download,
            summary::summary_engine::commands::builtin_ai_delete_model,
            summary::summary_engine::commands::builtin_ai_is_model_ready,
            summary::summary_engine::commands::builtin_ai_get_available_summary_model,
            summary::summary_engine::commands::builtin_ai_get_recommended_model,
            openrouter::get_openrouter_models,
            audio::recording_preferences::get_recording_preferences,
            audio::recording_preferences::set_recording_preferences,
            audio::recording_preferences::get_default_recordings_folder_path,
            audio::recording_preferences::open_recordings_folder,
            audio::recording_preferences::get_available_audio_backends,
            audio::recording_preferences::get_current_audio_backend,
            audio::recording_preferences::set_audio_backend,
            audio::recording_preferences::get_audio_backend_info,
            // Language preference commands
            set_language_preference,
            tray::get_menu_bar_enabled,
            tray::set_menu_bar_enabled,
            // Notification system commands
            notifications::commands::get_notification_settings,
            notifications::commands::set_notification_settings,
            // Screen Recording permission commands
            audio::permissions::trigger_system_audio_permission_command,
            audio::permissions::preflight_system_audio_permission_command,
            audio::permissions::prompt_system_audio_permission_command,
            // Database import commands
            database::commands::check_first_launch,
            database::commands::select_legacy_database_path,
            database::commands::detect_legacy_database,
            database::commands::check_default_legacy_database,
            database::commands::check_homebrew_database,
            database::commands::import_and_initialize_database,
            database::commands::initialize_fresh_database,
            // Database and Models path commands
            database::commands::get_database_directory,
            database::commands::open_database_folder,
            whisper_engine::commands::open_models_folder,
            // Onboarding commands
            onboarding::get_onboarding_status,
            onboarding::save_onboarding_status_cmd,
            onboarding::complete_onboarding,
            // System settings commands
            #[cfg(target_os = "macos")]
            utils::open_system_settings,
            // Retranscription commands
            audio::retranscription::start_retranscription_command,
            audio::retranscription::cancel_retranscription_command,
            // Import audio commands
            audio::import::select_and_validate_audio_command,
            audio::import::validate_audio_file_command,
            audio::import::start_import_audio_command,
            audio::import::cancel_import_command,
            // Calendar commands (F4) — EventKit permission/list/sync are macOS-only.
            #[cfg(target_os = "macos")]
            calendar::commands::calendar_permission_status,
            #[cfg(target_os = "macos")]
            calendar::commands::calendar_request_access,
            #[cfg(target_os = "macos")]
            calendar::commands::calendar_list_calendars,
            #[cfg(target_os = "macos")]
            calendar::commands::calendar_set_selected,
            #[cfg(target_os = "macos")]
            calendar::commands::calendar_sync_events,
            calendar::commands::calendar_get_events,
            calendar::commands::calendar_get_event,
            calendar::commands::calendar_link_meeting,
            calendar::commands::calendar_unlink_meeting,
            calendar::commands::calendar_suggest_meetings,
            #[cfg(target_os = "macos")]
            calendar::commands::calendar_sync_range,
            calendar::commands::calendar_get_events_range,
            // Meeting-time correction for imported recordings (F4 support)
            meeting_time::set_meeting_time_from_source,
            // Person Profiles (F2/F3)
            persons::commands::person_list,
            persons::commands::person_get,
            persons::commands::person_upsert,
            persons::commands::person_delete,
            persons::commands::owner_get,
            persons::commands::owner_set,
            persons::commands::person_import_from_event,
            persons::commands::meeting_participants,
            persons::commands::profile_facts_for_person,
            persons::commands::profile_facts_pending,
            persons::commands::profile_fact_confirm,
            persons::commands::profile_fact_reject,
            persons::commands::profile_fact_add_manual,
            persons::commands::profile_fact_sources,
            persons::commands::person_extract_facts_for_meeting,
            persons::commands::person_reconcile_facts_for_meeting,
            persons::commands::person_facts_needing_review,
            persons::commands::summary_context_for_meeting,
            // Meeting Series (F9)
            meeting_series::commands::series_create,
            meeting_series::commands::series_list,
            meeting_series::commands::series_get,
            meeting_series::commands::series_for_meeting,
            meeting_series::commands::series_link_meeting,
            meeting_series::commands::series_unlink_meeting,
            meeting_series::commands::series_update_meta,
            meeting_series::commands::series_update_ledger,
            meeting_series::commands::series_rebuild_ledger,
            meeting_series::commands::series_rescan_heuristic,
            meeting_series::commands::series_set_template,
            // Speaker Diarization (F1) — offline orchestration + read surface
            diarization::commands::diarize_meeting,
            diarization::commands::speaker_list_for_meeting,
            diarization::commands::speaker_assign_to_person,
            diarization::commands::speaker_match_suggestions,
            diarization::commands::meeting_speaker_labels,
            diarization::commands::speaker_reassign_transcript_line,
            diarization::commands::speaker_reset_owner_voiceprint,
            diarization::voiceprint::speaker_voiceprint_signatures,
            diarization::voiceprint::person_voiceprint_signature,
            diarization::voiceprint::person_voiceprint_signatures,
            // App-level config (F3 support) — global organization
            app_config::app_config_get,
            app_config::app_config_set_organization,
            // Ari Notch (WS-B) — sidecar bridge lifecycle
            notch::bridge::notch_enable,
            notch::bridge::notch_disable,
            notch::bridge::notch_status,
            // Apple on-device intelligence (Phase 1) — availability probe
            apple::apple_probe,
            apple::apple_ensure_assets,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|_app_handle, event| {
            match event {
                #[cfg(target_os = "macos")]
                tauri::RunEvent::Reopen { .. } => {
                    tray::focus_main_window(_app_handle);
                }
                tauri::RunEvent::Exit => {
                    log::info!("Application exiting, cleaning up resources...");
                    tauri::async_runtime::block_on(async {
                        // Clean up database connection and checkpoint WAL
                        if let Some(app_state) = _app_handle.try_state::<state::AppState>() {
                            log::info!("Starting database cleanup...");
                            if let Err(e) = app_state.db_manager.cleanup().await {
                                log::error!("Failed to cleanup database: {}", e);
                            } else {
                                log::info!("Database cleanup completed successfully");
                            }
                        } else {
                            log::warn!("AppState not available for database cleanup (likely first launch)");
                        }

                        // Clean up sidecar
                        log::info!("Cleaning up sidecar...");
                        if let Err(e) = summary::summary_engine::force_shutdown_sidecar().await {
                            log::error!("Failed to force shutdown sidecar: {}", e);
                        }

                        // Clean up apple-helper sidecar
                        if let Err(e) = apple::helper::force_shutdown().await {
                            log::error!("Failed to force shutdown apple-helper sidecar: {}", e);
                        }
                    });
                    log::info!("Application cleanup complete");
                }
                _ => {}
            }
        });
}
