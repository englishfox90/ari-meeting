# ari-engine extraction — protocol & service map

Status: design doc for **Phase 1.5** of `plans/swift-migration-plan.md` ("Engine extraction — the seam the whole plan hangs on"). This doc specifies the wire protocol between the Tauri host (first client) and the new headless `ari-engine` daemon, and maps the live `frontend/src-tauri` command/event surface onto it. It does not carve any code — that's the Phase 1.5 implementation work this doc scopes.

Companion: `.claude/context/open-questions.md`, `.claude/context/architecture.md`, `plans/swift-migration-plan.md` §Phase 1.5 / §Phase 2.

## Overview / goals

Today `frontend/src-tauri` is a Rust `lib` crate embedded in a Tauri app: it owns the SQLite DB, the audio pipeline, five sidecars (llama-helper, apple-helper, diarize-helper, ffmpeg, and the in-process whisper/parakeet engines), and answers ~210 live `#[tauri::command]`s directly against the Next.js frontend via Tauri's `invoke`/`emit` IPC.

Phase 1.5 pulls that engine out from under Tauri into a standalone headless daemon, **`ari-engine`**, that speaks a versioned protocol over stdio instead of Tauri's IPC. The Tauri host becomes the **first client**: its existing `invoke` handlers forward to engine requests, and its existing `emit` calls become relays of engine-pushed events. Behavior must be identical before and after — this is a pure refactor with an end-to-end regression pass, done *before* any Swift shell exists, in the language and test harness we already have.

Goals:
- Define the message envelope and its three categories (request/response, event, stream) precisely enough to implement against.
- Enumerate every live command into named services (`recording`, `transcription`, `summary`, …) with a proposed `service.verb` method name, so the carve has a checklist.
- Enumerate every emitted event channel and which service owns it, distinguishing request-scoped streams from free-running push events.
- State the cross-cutting rules (single DB owner, error shape, versioning) once, so per-service tables don't repeat them.
- Record what's already been deleted (the pruned-vestigial set) and what's still pending a decision (the deferred dead-command group), so the carve doesn't drag known-dead surface across the seam.

Non-goals: choosing between stdio and a local socket for the *real* Phase 1.5 build (this doc assumes stdio, per the plan text, but the wire-format description is transport-agnostic enough to survive a later swap); redesigning any command's business logic; touching the Swift tree (that's Phase 2, the second client).

## Transport & message envelope

**Transport:** newline-delimited JSON (NDJSON) over the child process's stdio. The host spawns `ari-engine` and:
- writes one JSON object per line to the engine's **stdin** (requests),
- reads one JSON object per line from the engine's **stdout** (responses, events, streams),
- treats the engine's **stderr** as log output only — never protocol.

Every message carries a top-level integer `v`, the **wire-protocol version** (starts at `1`). There are three message `kind`s.

### 1. Request / response (commands)

Client → engine:

```json
{"v": 1, "id": 482, "kind": "request", "method": "recording.start", "params": {"micDeviceName": "Built-in Microphone", "meetingName": "Weekly Sync"}}
```

Engine → client, success:

```json
{"v": 1, "id": 482, "kind": "response", "ok": true, "result": {"recordingId": "b9e1..."}}
```

Engine → client, failure:

```json
{"v": 1, "id": 482, "kind": "response", "ok": false, "error": {"code": "engine_error", "message": "Microphone permission not granted", "data": null}}
```

`id` is a client-generated, monotonically increasing `u64`, echoed back unchanged so the client can correlate out-of-order responses (the engine may interleave responses if it processes requests concurrently). `params`/`result` mirror today's Rust command's args/return struct as JSON — same field names, same casing convention as today's serde structs (no change to Layer-2 casing rules from `.claude/rules/tauri-ipc.md`; only the Layer-1 "top-level camelCase via Tauri's arg conversion" behavior is replaced by "top-level camelCase because that's what `params` now literally is").

### 2. Events (unsolicited push, engine → client)

```json
{"v": 1, "kind": "event", "channel": "transcript-update", "payload": {"meetingId": "b9e1...", "text": "...", "isFinal": false}}
```

No `id` — these aren't tied to a specific request. This is the direct wire form of today's Tauri `app.emit("channel", payload)` calls (live transcript segments, download progress, recording lifecycle, shutdown progress, etc.). The host's job is to relay each one straight to its own `app.emit` call so existing frontend `listen()` call sites need no changes.

### 3. Streaming (long response tied to a request)

```json
{"v": 1, "id": 501, "kind": "stream", "event": "delta", "payload": {"text": "Based on the "}}
{"v": 1, "id": 501, "kind": "stream", "event": "delta", "payload": {"text": "meeting notes..."}}
{"v": 1, "id": 501, "kind": "stream", "event": "done", "payload": {"sources": [{"meetingId": "...", "snippet": "..."}]}}
```

or, on failure mid-stream:

```json
{"v": 1, "id": 501, "kind": "stream", "event": "error", "payload": {"code": "engine_error", "message": "Ollama connection refused"}}
```

`id` here **is** the originating request's `id` — streams are always tied to a request that kicked them off (e.g. `recall.ask` today emits `ask-stream-delta`/`ask-stream-done` via `recall::stream::api_answer_meetings_locally_stream`). A stream always terminates in exactly one `done` or `error` message; the client should not expect a terminal `response` message for a request that produced a stream — the stream's `done`/`error` is the terminal signal for that `id`.

## Cross-cutting rules

- **Single DB owner (plan principle 3).** `ari-engine` is the only process that opens the SQLite file. Neither the Tauri host nor the future Swift shell ever touch it directly — all persistence goes through engine methods. This is the Swift-migration-plan restatement of the existing "DB access through `database/repositories/` only" rule; the repository layer doesn't move, it just becomes reachable only from inside the engine process.
- **Error model.** Every live command today returns `Result<T, String>` at the Tauri boundary. Initially, map `Err(String)` straight to `{"code": "engine_error", "message": <the string>}` — a single generic code, no attempt to enumerate error taxonomies yet. Refining `code` per service (e.g. `recording.device_busy`, `recall.provider_unreachable`) is deferred to a later pass once real client error-handling needs are known; don't invent a taxonomy speculatively.
- **Method naming.** `<service>.<verb>`. `service` comes from the command's domain (see the service map below); `verb` comes from the command's own name with the domain prefix/module path stripped (e.g. `api::api_delete_meeting` → `meetings.delete`; `audio::recording_commands::pause_recording` → `recording.pause`; `recall::commands::recall_reindex` → `recall.reindex`). Rust already namespaces most of this surface via `module::submodule::fn`, so the mapping is close to mechanical — the table below makes it explicit per command.
- **Versioning.** `v` is the **envelope** version; a breaking change to the envelope itself (adding/removing a `kind`, changing `id` semantics, etc.) bumps it. Method-level evolution — new methods, new optional params, new result fields — is additive within a `v` and does not require a bump.
- **Strangler compatibility.** The Tauri host is the first client and must be behaviorally invisible to the frontend: every existing `invoke(cmd, args)` call site keeps working unchanged, now implemented as "host command handler builds a `request`, writes it to the engine, awaits the matching `response`/`stream`". Every existing `emit` call becomes "host relays an `event`/`stream` message from the engine verbatim." The Swift shell (Phase 2) is the **second client** of the same protocol — it never gets a bespoke API; anything not expressible in this protocol isn't available to either client.
- **UI-adjacent OS calls are the client's job; the engine is pure logic + data (decided 2026-07-17).** `ari-engine` is headless — it has no window, no `AppHandle`, and no main-thread AppKit run loop. Two classes of today's commands depend on exactly those and therefore **do not become engine RPCs**; they stay on the client (Tauri host now, Swift shell later), which then hands the engine the *result*:
  - **Native file pickers** (`selectAndValidateAudio`, `selectLegacyPath`) — the client presents `NSOpenPanel`/the Tauri dialog and sends the chosen path to the engine as a plain `params` string. The engine method becomes "validate/import *this path*", never "open a picker".
  - **Main-thread permission prompts** (`triggerMicrophonePermission`, the system-audio permission prompts) — the client runs the TCC prompt on its UI thread (today's `app.run_on_main_thread(...)` pattern) and reports the granted/denied outcome to the engine. The engine may still *check* a permission's current status (a pure syscall, no UI) via an RPC, but it never *shows* the prompt.

  This is one consistent boundary — "if it needs a window or the main thread, it's client-side" — and it's the same split the Swift shell will need natively, so drawing it now costs nothing later. Commands in the service map below that fall on the client side of this line are tagged **[client-side]**.

## Service map

Grouped from the `generate_handler!` list in `frontend/src-tauri/src/lib.rs`. **Updated 2026-07-17** to reflect the completed prunes: the 36 vestigial (commit `3a04394`) and 37 dead (commit `ae47d5f`) commands have been removed from the tree, so this map now lists only the **~211 surviving live commands** — the dead rows the first draft still carried are gone. `#[cfg(target_os = "macos")]`-gated commands are noted since the engine itself is macOS-only (per project scope) — the gate becomes moot once the engine only ever runs on macOS, but is called out for traceability against today's source.

### `recording`

| method | Rust command | notes |
|---|---|---|
| `recording.start` | `start_recording` | top-level fn in `lib.rs` |
| `recording.stop` | `stop_recording` | |
| `recording.isRecording` | `is_recording` | |
| `recording.getTranscriptionStatus` | `get_transcription_status` | |
| `recording.readAudioFile` | `read_audio_file` | |
| `recording.getAudioDevices` | `get_audio_devices` | |
| `recording.triggerMicrophonePermission` | `trigger_microphone_permission` | **[client-side]** — main-thread AppKit TCC prompt; engine records the outcome |
| `recording.startWithDevicesAndMeeting` | `start_recording_with_devices_and_meeting` | (`start_recording_with_devices`, the meeting-less variant, was pruned as dead) |
| `recording.startAudioLevelMonitoring` | `start_audio_level_monitoring` | |
| `recording.stopAudioLevelMonitoring` | `stop_audio_level_monitoring` | |
| `recording.pause` | `audio::recording_commands::pause_recording` | |
| `recording.resume` | `audio::recording_commands::resume_recording` | |
| `recording.isPaused` | `audio::recording_commands::is_recording_paused` | |
| `recording.getState` | `audio::recording_commands::get_recording_state` | |
| `recording.getMeetingFolderPath` | `audio::recording_commands::get_meeting_folder_path` | |
| `recording.getTranscriptHistory` | `audio::recording_commands::get_transcript_history` | reload-sync path |
| `recording.getMeetingName` | `audio::recording_commands::get_recording_meeting_name` | reload-sync path |
| `recording.getActiveAudioOutput` | `audio::recording_commands::get_active_audio_output` | Bluetooth playback warning (the `poll_audio_device_events`/`get_reconnection_status`/`attempt_device_reconnect` command wrappers were pruned as dead — the underlying device-monitor infra stays) |
| `recording.recoverAudioFromCheckpoints` | `audio::incremental_saver::recover_audio_from_checkpoints` | crash recovery |
| `recording.cleanupCheckpoints` | `audio::incremental_saver::cleanup_checkpoints` | |
| `recording.hasAudioCheckpoints` | `audio::incremental_saver::has_audio_checkpoints` | |
| `recording.getPreferences` | `audio::recording_preferences::get_recording_preferences` | |
| `recording.setPreferences` | `audio::recording_preferences::set_recording_preferences` | |
| `recording.getDefaultFolderPath` | `audio::recording_preferences::get_default_recordings_folder_path` | |
| `recording.openRecordingsFolder` | `audio::recording_preferences::open_recordings_folder` | |
| `recording.getAvailableAudioBackends` | `audio::recording_preferences::get_available_audio_backends` | (`select_recording_folder` was pruned as dead — the surviving file pickers are `selectAndValidateAudio`/`selectLegacyPath`) |
| `recording.getCurrentAudioBackend` | `audio::recording_preferences::get_current_audio_backend` | |
| `recording.setAudioBackend` | `audio::recording_preferences::set_audio_backend` | |
| `recording.getAudioBackendInfo` | `audio::recording_preferences::get_audio_backend_info` | |
| `recording.triggerSystemAudioPermission` | `audio::permissions::trigger_system_audio_permission_command` | **[client-side]** — shows a TCC prompt; engine records the outcome |
| `recording.preflightSystemAudioPermission` | `audio::permissions::preflight_system_audio_permission_command` | **[client-side]** |
| `recording.promptSystemAudioPermission` | `audio::permissions::prompt_system_audio_permission_command` | **[client-side]** |
| `recording.setLanguagePreference` | `set_language_preference` | top-level fn; global `LANGUAGE_PREFERENCE` state — carries over as engine-process global |

### `transcription` (whisper + parakeet + retranscription + import)

| method | Rust command | notes |
|---|---|---|
| `transcription.saveTranscript` | `save_transcript` | top-level fn |
| `transcription.whisperInit` | `whisper_engine::commands::whisper_init` | |
| `transcription.whisperGetAvailableModels` | `whisper_engine::commands::whisper_get_available_models` | |
| `transcription.whisperLoadModel` | `whisper_engine::commands::whisper_load_model` | |
| `transcription.whisperGetCurrentModel` | `whisper_engine::commands::whisper_get_current_model` | |
| `transcription.whisperIsModelLoaded` | `whisper_engine::commands::whisper_is_model_loaded` | |
| `transcription.whisperHasAvailableModels` | `whisper_engine::commands::whisper_has_available_models` | |
| `transcription.whisperValidateModelReady` | `whisper_engine::commands::whisper_validate_model_ready` | |
| `transcription.whisperTranscribeAudio` | `whisper_engine::commands::whisper_transcribe_audio` | |
| `transcription.whisperGetModelsDirectory` | `whisper_engine::commands::whisper_get_models_directory` | |
| `transcription.whisperDownloadModel` | `whisper_engine::commands::whisper_download_model` | drives `model-download-progress`/`model-loading-*` events |
| `transcription.whisperCancelDownload` | `whisper_engine::commands::whisper_cancel_download` | |
| `transcription.whisperDeleteCorruptedModel` | `whisper_engine::commands::whisper_delete_corrupted_model` | |
| `transcription.whisperOpenModelsFolder` | `whisper_engine::commands::open_models_folder` | |
| `transcription.parakeetInit` | `parakeet_engine::commands::parakeet_init` | Parakeet is the default provider |
| `transcription.parakeetGetAvailableModels` | `parakeet_engine::commands::parakeet_get_available_models` | |
| `transcription.parakeetLoadModel` | `parakeet_engine::commands::parakeet_load_model` | |
| `transcription.parakeetGetCurrentModel` | `parakeet_engine::commands::parakeet_get_current_model` | |
| `transcription.parakeetIsModelLoaded` | `parakeet_engine::commands::parakeet_is_model_loaded` | |
| `transcription.parakeetHasAvailableModels` | `parakeet_engine::commands::parakeet_has_available_models` | |
| `transcription.parakeetValidateModelReady` | `parakeet_engine::commands::parakeet_validate_model_ready` | |
| `transcription.parakeetTranscribeAudio` | `parakeet_engine::commands::parakeet_transcribe_audio` | |
| `transcription.parakeetGetModelsDirectory` | `parakeet_engine::commands::parakeet_get_models_directory` | |
| `transcription.parakeetDownloadModel` | `parakeet_engine::commands::parakeet_download_model` | |
| `transcription.parakeetRetryDownload` | `parakeet_engine::commands::parakeet_retry_download` | |
| `transcription.parakeetCancelDownload` | `parakeet_engine::commands::parakeet_cancel_download` | |
| `transcription.parakeetDeleteCorruptedModel` | `parakeet_engine::commands::parakeet_delete_corrupted_model` | |
| `transcription.parakeetOpenModelsFolder` | `parakeet_engine::commands::open_parakeet_models_folder` | |
| `transcription.getSystemResources` | `whisper_engine::parallel_commands::get_system_resources` | live memory probe — the one kept command from the whisper-parallel deletion group (see Deletion appendix) |
| `transcription.startRetranscription` | `audio::retranscription::start_retranscription_command` | (`is_retranscription_in_progress_command` pruned as dead) |
| `transcription.cancelRetranscription` | `audio::retranscription::cancel_retranscription_command` | |
| `transcription.selectAndValidateAudio` | `audio::import::select_and_validate_audio_command` | **[client-side]** — client presents the file picker, then calls the engine with the chosen path |
| `transcription.validateAudioFile` | `audio::import::validate_audio_file_command` | |
| `transcription.startImportAudio` | `audio::import::start_import_audio_command` | |
| `transcription.cancelImport` | `audio::import::cancel_import_command` | (`is_import_in_progress_command` pruned as dead) |

### `summary` (incl. templates, builtin-ai, claude-cli)

| method | Rust command | notes |
|---|---|---|
| `summary.processTranscript` | `summary::commands::api_process_transcript` | main entry point into `generate_summary()` |
| `summary.get` | `summary::commands::api_get_summary` | |
| `summary.save` | `summary::commands::api_save_meeting_summary` | |
| `summary.getLanguage` | `summary::commands::api_get_meeting_summary_language` | |
| `summary.saveLanguage` | `summary::commands::api_save_meeting_summary_language` | |
| `summary.getDetectedLanguage` | `summary::commands::api_get_meeting_detected_summary_language` | |
| `summary.saveDetectedLanguage` | `summary::commands::api_save_meeting_detected_summary_language` | |
| `summary.detectTranscriptLanguage` | `summary::commands::api_detect_transcript_summary_language` | |
| `summary.cancel` | `summary::commands::api_cancel_summary` | |
| `summary.listTemplates` | `summary::template_commands::api_list_templates` | (`api_get_template_details`/`api_validate_template` pruned as dead) |
| `summary.suggestTemplate` | `summary::template_selector::api_suggest_template` | F6 auto-suggest |
| `summary.claudeCliDetect` | `summary::claude_cli::claude_cli_detect` | |
| `summary.builtinAiListModels` | `summary::summary_engine::commands::builtin_ai_list_models` | drives llama-helper sidecar |
| `summary.builtinAiGetModelInfo` | `summary::summary_engine::commands::builtin_ai_get_model_info` | |
| `summary.builtinAiDownloadModel` | `summary::summary_engine::commands::builtin_ai_download_model` | |
| `summary.builtinAiCancelDownload` | `summary::summary_engine::commands::builtin_ai_cancel_download` | |
| `summary.builtinAiDeleteModel` | `summary::summary_engine::commands::builtin_ai_delete_model` | |
| `summary.builtinAiIsModelReady` | `summary::summary_engine::commands::builtin_ai_is_model_ready` | |
| `summary.builtinAiGetAvailableModel` | `summary::summary_engine::commands::builtin_ai_get_available_summary_model` | |
| `summary.builtinAiGetRecommendedModel` | `summary::summary_engine::commands::builtin_ai_get_recommended_model` | |

### `meetings` (api_* meetings/transcripts/export)

| method | Rust command | notes |
|---|---|---|
| `meetings.list` | `api::api_get_meetings` | |
| `meetings.searchTranscripts` | `api::api_search_transcripts` | pre-F7 keyword search; superseded by `recall.*` for new work but still a live command |
| `meetings.delete` | `api::api_delete_meeting` | |
| `meetings.get` | `api::api_get_meeting` | |
| `meetings.getMetadata` | `api::api_get_meeting_metadata` | |
| `meetings.getTranscripts` | `api::api_get_meeting_transcripts` | |
| `meetings.saveTitle` | `api::api_save_meeting_title` | |
| `meetings.exportLocally` | `api::api_export_meeting_locally` | |
| `meetings.saveTranscript` | `api::api_save_transcript` | distinct from `transcription.saveTranscript` (top-level `save_transcript`) — both exist in lib.rs today; note the naming collision in Open Questions |
| `meetings.openFolder` | `api::open_meeting_folder` | |
| `meetings.getTemplate` | `api::api_get_meeting_template` | |
| `meetings.openExternalUrl` | `api::open_external_url` | generic utility parked here for lack of a better home — low confidence, could equally sit in `system` |
| `meetings.setMeetingTimeFromSource` | `meeting_time::set_meeting_time_from_source` | F4 support: realigns imported-recording timestamps |

### `settings` (config, api keys, language, model config)

| method | Rust command | notes |
|---|---|---|
| `settings.getModelConfig` | `api::api_get_model_config` | |
| `settings.saveModelConfig` | `api::api_save_model_config` | |
| `settings.getApiKey` | `api::api_get_api_key` | |
| `settings.getTranscriptConfig` | `api::api_get_transcript_config` | |
| `settings.saveTranscriptConfig` | `api::api_save_transcript_config` | |
| `settings.getTranscriptApiKey` | `api::api_get_transcript_api_key` | |
| `settings.saveCustomOpenAiConfig` | `api::api_save_custom_openai_config` | |
| `settings.getCustomOpenAiConfig` | `api::api_get_custom_openai_config` | |
| `settings.testCustomOpenAiConnection` | `api::api_test_custom_openai_connection` | |
| `settings.getAppConfig` | `app_config::app_config_get` | F3 support: global organization config |
| `settings.setAppConfigOrganization` | `app_config::app_config_set_organization` | |
| `settings.getNotificationSettings` | `notifications::commands::get_notification_settings` | |
| `settings.setNotificationSettings` | `notifications::commands::set_notification_settings` | |
| `settings.getMenuBarEnabled` | `tray::get_menu_bar_enabled` | |
| `settings.setMenuBarEnabled` | `tray::set_menu_bar_enabled` | |

Commented-out in `lib.rs` today (`api_get_auto_generate_setting` / `api_save_auto_generate_setting`) — not registered, excluded from the 210 live count; flagged only so the carve doesn't resurrect them by accident.

### `recall` (ask / index / embedders / conversations)

| method | Rust command | notes |
|---|---|---|
| `recall.answerLocally` | `api::api_answer_meetings_locally` | the safety-hardened shell — bounded context, loopback-only, no invented citations; **preserve invariants verbatim** (`local_recall_tests`) |
| `recall.answerLocallyStream` | `recall::stream::api_answer_meetings_locally_stream` | request-scoped `kind:"stream"`; drives `ask-stream-delta`/`ask-stream-done` |
| `recall.indexStatus` | `recall::commands::recall_index_status` | |
| `recall.reindex` | `recall::commands::recall_reindex` | drives `recall-reindex-progress`/`recall-reindex-complete` |
| `recall.getEmbedder` | `recall::commands::recall_get_embedder` | |
| `recall.setEmbedder` | `recall::commands::recall_set_embedder` | Apple NLEmbedding / Nomic GGUF / Ollama — see `ask-embedder-pluggable` memory note |
| `recall.embedderListModels` | `recall::embed_models::recall_embedder_list_models` | |
| `recall.embedderDownloadModel` | `recall::embed_models::recall_embedder_download_model` | drives `recall-embedder-download-progress` |
| `recall.embedderCancelDownload` | `recall::embed_models::recall_embedder_cancel_download` | |
| `recall.embedderDeleteModel` | `recall::embed_models::recall_embedder_delete_model` | (`recall_embedder_is_ready` pruned as dead) |
| `recall.conversationList` | `recall::conversations::ask_conversation_list` | |
| `recall.conversationGet` | `recall::conversations::ask_conversation_get` | |
| `recall.conversationCreate` | `recall::conversations::ask_conversation_create` | |
| `recall.messageAppend` | `recall::conversations::ask_message_append` | (`ask_conversation_rename` pruned as dead) |
| `recall.conversationDelete` | `recall::conversations::ask_conversation_delete` | |

### `providers` (ollama / openai / anthropic / groq / openrouter)

| method | Rust command | notes |
|---|---|---|
| `providers.ollamaGetModels` | `ollama::get_ollama_models` | |
| `providers.ollamaPullModel` | `ollama::pull_ollama_model` | drives `ollama-model-download-progress/complete/error` |
| `providers.ollamaDeleteModel` | `ollama::delete_ollama_model` | |
| `providers.ollamaGetModelContext` | `ollama::get_ollama_model_context` | |
| `providers.openaiGetModels` | `openai::openai::get_openai_models` | |
| `providers.anthropicGetModels` | `anthropic::anthropic::get_anthropic_models` | |
| `providers.groqGetModels` | `groq::groq::get_groq_models` | |
| `providers.openrouterGetModels` | `openrouter::get_openrouter_models` | |

### `calendar` (F4/F5 — macOS-only EventKit surface)

| method | Rust command | notes |
|---|---|---|
| `calendar.permissionStatus` | `calendar::commands::calendar_permission_status` | `#[cfg(macos)]` in lib.rs today (moot once engine is macOS-only) |
| `calendar.requestAccess` | `calendar::commands::calendar_request_access` | `#[cfg(macos)]` |
| `calendar.listCalendars` | `calendar::commands::calendar_list_calendars` | `#[cfg(macos)]` |
| `calendar.setSelected` | `calendar::commands::calendar_set_selected` | `#[cfg(macos)]` — this is the command whose camelCase-key trap is documented in `tauri-ipc.md`; re-verify param casing survives the protocol swap |
| `calendar.syncEvents` | `calendar::commands::calendar_sync_events` | `#[cfg(macos)]`; drives `calendar-sync-updated` |
| `calendar.getEvents` | `calendar::commands::calendar_get_events` | |
| `calendar.getEvent` | `calendar::commands::calendar_get_event` | |
| `calendar.linkMeeting` | `calendar::commands::calendar_link_meeting` | |
| `calendar.unlinkMeeting` | `calendar::commands::calendar_unlink_meeting` | |
| `calendar.suggestMeetings` | `calendar::commands::calendar_suggest_meetings` | |
| `calendar.syncRange` | `calendar::commands::calendar_sync_range` | `#[cfg(macos)]` |
| `calendar.getEventsRange` | `calendar::commands::calendar_get_events_range` | |

### `persons` (F2/F3 profiles)

| method | Rust command | notes |
|---|---|---|
| `persons.list` | `persons::commands::person_list` | |
| `persons.get` | `persons::commands::person_get` | |
| `persons.upsert` | `persons::commands::person_upsert` | |
| `persons.delete` | `persons::commands::person_delete` | |
| `persons.ownerGet` | `persons::commands::owner_get` | |
| `persons.ownerSet` | `persons::commands::owner_set` | |
| `persons.importFromEvent` | `persons::commands::person_import_from_event` | |
| `persons.meetingParticipants` | `persons::commands::meeting_participants` | |
| `persons.factsForPerson` | `persons::commands::profile_facts_for_person` | |
| `persons.factsPending` | `persons::commands::profile_facts_pending` | |
| `persons.factConfirm` | `persons::commands::profile_fact_confirm` | |
| `persons.factReject` | `persons::commands::profile_fact_reject` | |
| `persons.factAddManual` | `persons::commands::profile_fact_add_manual` | |
| `persons.factSources` | `persons::commands::profile_fact_sources` | |
| `persons.extractFactsForMeeting` | `persons::commands::person_extract_facts_for_meeting` | |
| `persons.reconcileFactsForMeeting` | `persons::commands::person_reconcile_facts_for_meeting` | |
| `persons.factsNeedingReview` | `persons::commands::person_facts_needing_review` | |
| `persons.summaryContextForMeeting` | `persons::commands::summary_context_for_meeting` | the F2/F3/F4/F6 "Context Assembly" convergence point per `product.md` |

### `series` (F9 meeting series)

| method | Rust command | notes |
|---|---|---|
| `series.create` | `meeting_series::commands::series_create` | |
| `series.list` | `meeting_series::commands::series_list` | |
| `series.get` | `meeting_series::commands::series_get` | |
| `series.forMeeting` | `meeting_series::commands::series_for_meeting` | |
| `series.linkMeeting` | `meeting_series::commands::series_link_meeting` | |
| `series.unlinkMeeting` | `meeting_series::commands::series_unlink_meeting` | |
| `series.updateMeta` | `meeting_series::commands::series_update_meta` | |
| `series.updateLedger` | `meeting_series::commands::series_update_ledger` | |
| `series.rebuildLedger` | `meeting_series::commands::series_rebuild_ledger` | |
| `series.rescanHeuristic` | `meeting_series::commands::series_rescan_heuristic` | |
| `series.setTemplate` | `meeting_series::commands::series_set_template` | |

### `diarization` (F1)

| method | Rust command | notes |
|---|---|---|
| `diarization.diarizeMeeting` | `diarization::commands::diarize_meeting` | drives the diarize-helper sidecar |
| `diarization.speakerListForMeeting` | `diarization::commands::speaker_list_for_meeting` | |
| `diarization.assignSpeakerToPerson` | `diarization::commands::speaker_assign_to_person` | |
| `diarization.speakerMatchSuggestions` | `diarization::commands::speaker_match_suggestions` | |
| `diarization.meetingSpeakerLabels` | `diarization::commands::meeting_speaker_labels` | |
| `diarization.reassignTranscriptLine` | `diarization::commands::speaker_reassign_transcript_line` | manual per-line reassign |
| `diarization.resetOwnerVoiceprint` | `diarization::commands::speaker_reset_owner_voiceprint` | |
| `diarization.speakerVoiceprintSignatures` | `diarization::voiceprint::speaker_voiceprint_signatures` | |
| `diarization.personVoiceprintSignature` | `diarization::voiceprint::person_voiceprint_signature` | |
| `diarization.personVoiceprintSignatures` | `diarization::voiceprint::person_voiceprint_signatures` | |

### `notch` (Ari Notch sidecar bridge)

| method | Rust command | notes |
|---|---|---|
| `notch.enable` | `notch::bridge::notch_enable` | |
| `notch.disable` | `notch::bridge::notch_disable` | |
| `notch.status` | `notch::bridge::notch_status` | drives `notch-navigate` |

### `apple` (Apple on-device intelligence probe)

| method | Rust command | notes |
|---|---|---|
| `apple.probe` | `apple::apple_probe` | |
| `apple.ensureAssets` | `apple::apple_ensure_assets` | drives `apple-assets-progress` |

### `onboarding`

| method | Rust command | notes |
|---|---|---|
| `onboarding.getStatus` | `onboarding::get_onboarding_status` | |
| `onboarding.saveStatus` | `onboarding::save_onboarding_status_cmd` | struct param `OnboardingStatus` — unrenamed serde, nested keys stay snake_case; the protocol's `params` JSON preserves that shape verbatim |
| `onboarding.complete` | `onboarding::complete_onboarding` | (`reset_onboarding_status_cmd` pruned as dead) |

### `database`

| method | Rust command | notes |
|---|---|---|
| `database.checkFirstLaunch` | `database::commands::check_first_launch` | drives `first-launch-detected` |
| `database.selectLegacyPath` | `database::commands::select_legacy_database_path` | **[client-side]** — client presents the file picker, then calls the engine with the chosen path |
| `database.detectLegacy` | `database::commands::detect_legacy_database` | |
| `database.checkDefaultLegacy` | `database::commands::check_default_legacy_database` | |
| `database.checkHomebrew` | `database::commands::check_homebrew_database` | |
| `database.importAndInitialize` | `database::commands::import_and_initialize_database` | drives `database-initialized` |
| `database.initializeFresh` | `database::commands::initialize_fresh_database` | |
| `database.getDirectory` | `database::commands::get_database_directory` | |
| `database.openFolder` | `database::commands::open_database_folder` | |

### `system` (devices, permissions, tray, console — and anything not confidently classified elsewhere)

| method | Rust command | notes |
|---|---|---|
| `system.showConsole` | `console_utils::show_console` | |
| `system.hideConsole` | `console_utils::hide_console` | |
| `system.toggleConsole` | `console_utils::toggle_console` | |
| `system.openSystemSettings` | `utils::open_system_settings` | `#[cfg(macos)]` |
| `system.trackMeetingEnded` | `analytics::commands::track_meeting_ended` | inert no-op (telemetry removed) but has a real internal caller — kept per the vestigial-prune exceptions; low confidence this belongs in `system` vs. `meetings`, flagged for reviewer judgment |

## Event-channel map

Found via `grep -rn '\.emit(' frontend/src-tauri/src` (including multi-line `app.emit(\n "channel-name",` call sites) — **50 distinct channels emitted** (close to the plan's measured 51; the discrepancy is grep-methodology noise, not a material gap). Cross-referenced against `frontend/src` `listen(...)` call sites for confirmed-listened status.

All channels below map to `kind:"event"` except the two recall streaming channels, which are `kind:"stream"` (tied to `recall.answerLocallyStream`'s request `id`) — listed separately.

### Streaming (request-scoped, `recall` service)

| channel (today's name → maps to `stream.event`) | owning method |
|---|---|
| `ask-stream-delta` → `event:"delta"` | `recall.answerLocallyStream` |
| `ask-stream-done` → `event:"done"` | `recall.answerLocallyStream` |

### Free events, confirmed frontend listener

| channel | service | listener |
|---|---|---|
| `request-recording-toggle` | `recording` (host/tray-originated, not engine — see note) | `app/layout.tsx` |
| `recording-started` | `recording` | `services/recordingService.ts` |
| `recording-paused` | `recording` | `services/recordingService.ts` |
| `recording-resumed` | `recording` | `services/recordingService.ts` |
| `recording-stopped` | `recording` | `services/recordingService.ts` |
| `recording-shutdown-progress` | `recording` | `services/recordingService.ts` |
| `recording-error` | `recording` | `services/recordingService.ts` |
| `recording-stop-complete` | `recording` | referenced per `external-stop-must-emit-complete` memory note; every non-UI stop path must emit this or the frontend orphans at 70% |
| `audio-levels` | `recording` | `components/DeviceSelection.tsx` |
| `speech-detected` | `recording`/`transcription` | `services/recordingService.ts` |
| `transcript-update` | `transcription` | multiple contexts (live transcript display) |
| `transcription-error` | `transcription` | `components/RecordingControls.tsx` |
| `import-progress` / `import-complete` / `import-error` | `transcription` | `hooks/useImportAudio.ts` |
| `retranscription-progress` / `retranscription-complete` / `retranscription-error` | `transcription` | `components/MeetingDetails/RetranscribeDialog.tsx` |
| `model-download-progress` / `model-download-complete` / `model-download-error` | `transcription` (whisper) | `components/WhisperModelManager.tsx` et al. |
| `ollama-model-download-progress` / `-complete` / `-error` | `providers` | `contexts/OllamaDownloadContext.tsx` |
| `parakeet-model-download-progress` / `-complete` / `-error` | `transcription` (parakeet) | `components/ParakeetModelManager.tsx` |
| `builtin-ai-download-progress` | `summary` | `components/BuiltInModelManager.tsx` |
| `recall-reindex-complete` | `recall` | `components/MeetingSearchSettings.tsx` |
| `apple-assets-progress` | `apple` | `services/appleService.ts` |
| `calendar-sync-updated` | `calendar` | `services/calendarService.ts` |
| `model-config-updated` | `settings` | `hooks/meeting-details/useModelConfiguration.ts` (event name doesn't appear in the `emit(` grep verbatim — verify the emitting call site before relying on this one; possibly a same-process context event, not an engine event) |

### Free events, no confirmed listener found — verify before relying on

These appeared in the `.emit(` grep but no matching `listen('<name>', ...)` call site was found in `frontend/src`. Per the plan's own caveat, this is a **lower bound** — the frontend has an `invokeTauri`-style wrapper pattern that can obscure a listener from a flat grep, so treat these as "needs a targeted look," not "confirmed dead":

- `transcription-progress`
- `transcription-queue-complete`
- `transcription-warning`
- `transcript-chunk-loss-detected`
- `recording-saved`
- `system-audio-started` / `system-audio-stopped`
- `database-initialized`
- `first-launch-detected`
- `notch-navigate`
- `recall-reindex-progress`
- `recall-embedder-download-progress`
- `model-loading-started` / `model-loading-completed` / `model-loading-failed` (whisper)
- `parakeet-model-loading-started` / `parakeet-model-loading-completed` / `parakeet-model-loading-failed`

## Migration / strangler sequencing

1. **Host-as-first-client (this extraction).** Carve `ari-engine` out of `frontend/src-tauri` as a separate crate/binary owning the DB, audio pipeline, and sidecars. Every `#[tauri::command]` handler in the Tauri host is rewritten to: serialize its args into a `request` per the method table above, write it to the engine's stdin, await the correlated `response` (or drive a `stream` through to completion), and return/forward exactly what it returns today. Every `app.emit(...)` call site in the engine becomes an `event`/`stream` message that the host relays via its own unchanged `app.emit(...)`. No frontend file changes — the whole point is that `invoke`/`listen` call sites are unaware anything moved.
2. **End-to-end regression before/after.** Because behavior must be byte-identical from the frontend's perspective, this phase's exit test is: run the existing frontend test suite + a manual pass through record → transcribe → summarize → ask-meetings → calendar-linked meeting, once against the pre-extraction monolith and once against host-fronting-`ari-engine`, and diff results.
3. **Swift shell as second client (Phase 2).** The native macOS SwiftUI app spawns `ari-engine` directly (same protocol, same method table) instead of going through Tauri. No new engine-side work is implied by this — Phase 2 is purely "write a Swift NDJSON client speaking the protocol this doc defines." Any command found to be unreachable or awkward from Swift is a signal to revisit this doc's service map, not to special-case the Swift client.
4. **Retire the Tauri host only after Phase 2's SwiftUI shell reaches parity** — per plan principle 1 ("strangler, never big-bang"), nothing is deleted until its replacement beats it.

## Deletion appendix

### (a) Vestigial group — already pruned, committed

37 commands identified as vestigial (analytics no-ops, whisper parallel-processing scaffolding, HTTP-era leftovers); **36 removed** on `phase1.5/prune-vestigial-commands`, with **3 explicit keep exceptions** because each still has a real live caller:

- **24 analytics no-ops removed**, except `analytics::commands::track_meeting_ended` — **kept**, has a real internal caller (mapped to `system.trackMeetingEnded` above).
- **10 whisper parallel-processing commands removed**, except `whisper_engine::parallel_commands::get_system_resources` — **kept**, a live memory probe (mapped to `transcription.getSystemResources` above).
- **2 HTTP-era commands removed**, except the `APP_SERVER_URL` constant — **kept**, still backs `make_api_request` (see part (b) below; this "keep" is provisional pending that subsystem's removal as a unit).

This group is fully resolved for the Phase 1.5 carve — do not re-audit it, and do not carry any of the 34 actually-removed commands across the seam.

### (b) Dead-command group — re-verify pass done, pruned (commit `ae47d5f`)

37 commands were flagged unwired-dead by the grep audit. The per-command re-verify pass (widened grep across `invoke`/`invokeTauri`/`*Service.ts`, plus Rust-internal caller checks that ignore same-name struct-method collisions) ran on 2026-07-17: **37 removed, 1 kept.**

- **Kept (real internal caller, not dead):** `is_recording_paused` — called directly from `tray.rs:339` and `notch/bridge.rs:537`, so it's a live method that also happens to be a command. Mapped to `recording.isPaused` above.
- **HTTP-profile unit removed as a bundle:** the `api_get_profile`/`api_save_profile`/`api_update_profile` trio + their only callers `make_api_request`/`get_server_address` + the `APP_SERVER_URL` (`"http://localhost:5167"`) constant + 4 profile DTO structs. This closes out the "never reintroduce localhost:5167" cleanup from repo-root `CLAUDE.md`.
- **Everything else** (12 notification commands, system-audio monitoring/permission wrappers, device-reconnect wrappers, screen-recording permission wrappers, import/retranscription in-progress flags, `select_recording_folder`, `recall_embedder_is_ready`, `ask_conversation_rename`, `reset_onboarding_status_cmd`, the two template authoring-helper commands) removed with their orphaned DTOs/imports/re-exports; two system-audio tests were rewritten to call the underlying non-command fns so coverage survived.

**Follow-up candidate (out of this pass's scope):** `audio::init_system_audio_state()` / `SystemAudioDetectorState` is still `.manage()`d in `lib.rs` but its only consumer commands are now gone — a safe removal once someone confirms the app-init wiring, tracked below.

## Open questions

1. ✅ **RESOLVED (2026-07-17) — native file pickers & main-thread permission prompts are client-side.** Folded into the cross-cutting "UI-adjacent OS calls are the client's job" rule above (this merges the former Q1 + Q5). The surviving affected commands (`selectAndValidateAudio`, `selectLegacyPath`, `triggerMicrophonePermission`, the system-audio permission prompts) are tagged **[client-side]** in the service map; `select_recording_folder` was pruned as dead so it's moot.
2. ✅ **RESOLVED (2026-07-17) — the ~33-command re-verify pass is done** (see Deletion appendix (b); commit `ae47d5f`). No dead-command plumbing will be carried across the seam.
3. **`meetings.saveTranscript` vs `transcription.saveTranscript` naming collision.** `api::api_save_transcript` and the top-level `save_transcript` are both live, separate commands with overlapping names once namespaced. Confirm they're actually distinct in purpose (or that one is dead) before finalizing method names — flagged, not resolved, in the service map above.
4. **`model-config-updated` event.** Listened to in `hooks/meeting-details/useModelConfiguration.ts` but not found via the `.emit(` grep — needs a targeted look to confirm whether it's an engine-emitted event (belongs in this map) or a same-process React/context event (doesn't cross the protocol boundary at all).
5. **`SystemAudioDetectorState` app-init cleanup.** Its consumer commands were pruned but it's still `.manage()`d in `lib.rs`; safe to remove once the app-init wiring is confirmed (follow-up from the dead-command pass).
6. **Concurrent request ordering.** The envelope allows out-of-order responses via `id` correlation; confirm whether `ari-engine` will actually process requests concurrently (multiple in-flight commands) or serially (one at a time, `id` correlation used only for safety) — affects whether the host needs a real pending-request map or can get away with a simple queue.
