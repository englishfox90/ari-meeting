# Rule: Coding Conventions

## Rust

- **Errors:** internal code uses `anyhow::Result`; the Tauri command boundary returns `Result<T, String>` (stringify with `format!` / `map_err`). Follow the existing shape.
- **Shared async state:** `Arc<RwLock<T>>` for shared state, `Arc<AtomicBool>` for flags (see `recording_state.rs`). Some subsystems use module-level `LazyLock`/`lazy_static`/atomics (`RECORDING_FLAG`, `LANGUAGE_PREFERENCE`) rather than Tauri `State` — global mutable state is a real pattern here; tread carefully with concurrency.
- **Hot-path logging:** use `perf_debug!` / `perf_trace!` (defined in `lib.rs`) — they compile to no-ops in release. Do **not** use raw `log::debug!` in audio inner loops.
- **DB access goes through `database/repositories/` only** — never inline `sqlx` queries in command modules.
- **Async runtime:** tokio "full". Use `tauri::async_runtime::spawn` for non-blocking init; `block_on` only where a result must exist before commands run (DB init).
- **macOS threading:** permission prompts must run on the main thread — use `app.run_on_main_thread(...)` + a oneshot channel (see `trigger_microphone_permission`). Follow this for any AppKit-touching call.
- Emoji log lines are idiomatic in this codebase — match the surrounding style.

## Frontend (TypeScript / React)

- **Errors:** try-catch with user-friendly messages.
- **State:** React Context only. No redux/zustand/react-query. Add providers to the `layout.tsx` tree; route recording state through `RecordingStateContext` / `recordingService`, not ad-hoc `invoke`.
- **Class merging:** always use `cn()` from `@/lib/utils` — never manual string concatenation of Tailwind classes.
- **Colors:** use the HSL CSS-variable tokens in `globals.css`. Never hardcode hex values in components.
- **Import alias:** `@/*` → `./src/*` (the only path alias).
- **Strict TypeScript** (`strict: true`). Keep `npx tsc --noEmit` clean.

## Naming

- Audio devices are **"microphone" and "system"** — never "input"/"output".

## Paths

- Never hardcode filesystem paths. Use Tauri's path APIs (`downloadDir`, app-data dir, etc.) for correct macOS locations.

## Audio facts (for anyone touching capture)

- Pipeline assumes a consistent **48 kHz** sample rate; resampling happens at capture. Recording is 48 kHz mono AAC (mic 16→48 kHz resample, system 48 kHz passthrough).
- VAD reduces Whisper load ~70% (only speech segments are transcribed).
- Bluetooth/AirPods playback distortion is a **macOS resampling artifact, not a bug** in our code.
