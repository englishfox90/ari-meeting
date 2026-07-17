# Rust / Tauri Backend — Scoped Rules

You're in the Rust core (`app_lib`). See the repo-root `CLAUDE.md` and `.claude/rules/` for the full picture; this is the backend-specific checklist.

## Before editing anything

Confirm the file is **live**, not dead. The old near-identical-name dead files (`lib_old_complex.rs`, `audio/core-old.rs`, `audio/recording_saver_old.rs`, `*.backup`, `audio/stt.rs`, `audio_v2/`) have been **removed**. If you meet dead code again, `grep "mod <name>" src/lib.rs` and check the `generate_handler!` list before building on it — and prefer deleting it to working around it. Details: `.claude/rules/no-legacy-files.md`.

## The rules that bite

1. **This is our codebase — refactor freely.** The former additive-only rule is retired; we no longer track upstream. New capability still tends to fit best as a new module + new tables + new commands (separation of concerns), but editing or reorganizing existing code is fully allowed. Keep it coherent and tested. (`.claude/rules/codebase-ownership.md`)
2. **Registering a command is TWO edits:** `#[tauri::command]` definition + add it to `generate_handler![…]` in `lib.rs`. Forgetting the second = silent "command not found". (`.claude/rules/tauri-ipc.md`)
3. **DB access goes through `database/repositories/` only.** Never inline `sqlx` in command modules. ⚠️ This tree is **frozen** (Swift-first going forward — see repo-root `CLAUDE.md` + `.claude/rules/swift-conventions.md`): do **not** add new tables/commands here. Net-new persistence goes to the Swift store (`grdb`/`sqlite-schema` skills). The old Rust `migration-writer` agent + `add-command` scaffolder have been removed. Existing repositories/migrations are still the pattern for a genuine bugfix to the frozen app.
4. **Command boundary returns `Result<T, String>`**; use `anyhow` internally. Most commands take `state: tauri::State<'_, AppState>`.
5. **Hot-path logging:** `perf_debug!` / `perf_trace!` (compiled out of release), never raw `log::debug!` in audio loops.
6. **macOS permission prompts run on the main thread** via `app.run_on_main_thread(...)` + oneshot channel (pattern: `trigger_microphone_permission`).
7. **Don't bump git-pinned crates** (`cpal`, `cidre`, `silero_rs`, `esaxx-rs`) or `whisper-rs`/`ort`/`llama-cpp-2` without approval. (`.claude/rules/platform-and-deps.md`)
8. **No HTTP backend.** App is native SQLite. Never reintroduce `localhost:5167` / the archived Python backend.
9. **Preserve recall invariants** in `api/api.rs` "Ask Meetings" (loopback-only Ollama, bounded context, no invented citations) — they have enforcing tests (`local_recall_tests`).

## Global state caution

Besides `AppState { db_manager }` and specialized managed states (`ParallelProcessorState`, `NotificationManagerState`, `ModelManagerState`), several subsystems use module-level `LazyLock`/`lazy_static`/atomics (`RECORDING_FLAG`, `LANGUAGE_PREFERENCE`). Global mutable state is a real pattern here — reason carefully about concurrency.
