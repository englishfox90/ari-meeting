# Architecture

Tauri 2 desktop app: a Rust core (audio, STT, persistence, LLM calls, commands) with a Next.js web frontend. Everything runs in-process — **no external server**.

## The five seams (where Ari's net-new work attaches)

Per the PRD, all new capability attaches at these existing seams:

1. **Audio pipeline** → decoded-PCM tap feeds speaker re-ID (F1).
2. **Database / repository layer** → new tables for speakers, profiles/facts, calendar-event links, embedding index (F1, F2, F4, F7).
3. **Notifications / tray** → calendar-triggered record prompt (F5).
4. **Summary prompt assembly** → the `SummaryContext` injection point (F2, F3, F6).
5. **Provider layer** → MCP extensibility (F8).

**Resolved seam locations** (from the 2026-07-14 investigation — full detail in `open-questions.md` and `../reference/reid-integration-contract.md`):
- **F1 PCM tap:** `audio/pipeline.rs:824`, right after `extract_window()` returns `(mic_window, sys_window)` and before `mix_window()` — 48 kHz mono f32, mic/system still separate. Clone off to an independent task; never block that loop. System audio is ONE mixed stream (Core Audio process tap), so remote-participant diarization needs embedding-clustering + calendar priors.
- **F1 speaker_id:** attach at `audio/transcription/worker.rs:208-220`; new `speaker_id` column (NOT the dead `speaker` column from migration `20251110000001`).
- **F7 retrieval:** swap only the retrieval call in `api_answer_meetings_locally` (`api/api.rs:665-671`); today it's pure SQL `LIKE` (no vectors/FTS). Keep the safety shell.

## Rust backend module map (`frontend/src-tauri/src/`)

- **`lib.rs`** — the real bootstrap. Declares modules, defines ~15 top-level commands, registers the `invoke_handler!` (~150 commands), sets up plugins/state/tray/DB in `run()`. `main.rs` just calls `app_lib::run()`.
- **`audio/`** — largest subsystem (LIVE). cpal capture + macOS ScreenCaptureKit (cidre), recording lifecycle, VAD, noise suppression, mixing, encoding, transcription orchestration.
  - `capture/` (core_audio, microphone, system), `devices/` (+ `platform/{macos,linux,windows}.rs`), `transcription/` (the `TranscriptionProvider` trait unifying whisper/parakeet), `pipeline.rs`, `recording_manager.rs`, `recording_commands.rs`, `recording_state.rs`, `recording_saver.rs`, `incremental_saver.rs` (crash-recovery checkpoints), `retranscription.rs`, `import.rs`, `vad.rs`, `device_monitor.rs`/`playback_monitor.rs` (Bluetooth/AirPods), `permissions.rs`.
  - The old dead files (`core-old.rs`, `recording_saver_old.rs`, `recording_commands.rs.backup`, `stt.rs`) have been **removed** (2026-07-16).
- **`audio_v2/`** — the dormant parallel rewrite (undeclared in `lib.rs`, wired to no command) has been **removed** (2026-07-16). If a live audio-path rewrite is wanted, start fresh per PRD §9.
- **`whisper_engine/`** — whisper.cpp STT via `whisper-rs` (Metal+CoreML on macOS). Includes `parallel_processor.rs` (multi-worker) + `acceleration.rs`.
- **`parakeet_engine/`** — ONNX STT (NVIDIA Parakeet) via `ort`. **Default transcription provider** (`parakeet-tdt-0.6b-v3-int8`).
- **`summary/`** — LLM summarization. `llm_client.rs` (`LLMProvider` enum + `generate_summary()` dispatch), `service`/`processor`, `templates/` (name + description + sections, each with its own LLM instruction + output format, loaded from JSON) + `template_commands.rs`, and `summary_engine/` = the **built-in local LLM** path (`sidecar.rs` drives the `llama-helper` child process over stdin/stdout JSON; idle-timeout auto-shutdown).
- **LLM providers:** `anthropic/`, `openai/`, `groq/`, `ollama/`, `openrouter/` — thin API clients, each exposing `get_*_models`.
- **`api/api.rs`** — meetings/transcripts/settings command surface (the `api_*` commands). Now hits **SQLite directly via repositories**. Residual HTTP profile commands are vestigial/dead.
- **`database/`** — SQLite via `sqlx`, WAL mode. `manager.rs` (pool), `setup.rs` (`initialize_database_on_startup`), `repositories/` (meeting, transcript, transcript_chunk, summary, setting) — **the only sanctioned DB access layer**. Migrations: timestamped `migrations/*.sql`.
- **`analytics/`** — **telemetry removed** (2026-07-14). PostHog is gone (`posthog-rs` dropped); `AnalyticsClient` and its Tauri commands are inert no-ops kept only so live callers (`audio/recording_commands.rs`, the registered commands in `lib.rs`, the frontend no-op stub) still compile and send nothing. Do not reintroduce telemetry. **`notifications/`** (consent/DND-gated), **`tray.rs`** (menu-bar), **`onboarding.rs`**, **`console_utils/`**, **`state.rs`** (`AppState { db_manager }`), **`config.rs`** (model catalog + defaults).
- **Removed (2026-07-16):** `lib_old_complex.rs` (the old 2,437-line monolith with the dead `TRANSCRIPT_SERVER_URL`) — deleted along with the other dead files.

## `llama-helper/` (separate top-level crate)

A standalone binary wrapping `llama-cpp-2` (llama.cpp), bundled as a Tauri **sidecar** and driven over stdin/stdout JSON. Isolated into its own process to (a) sandbox llama.cpp crashes/OOM out of the main app, (b) reclaim RAM on idle timeout, (c) compile the GPU feature independently. Built separately and copied into `binaries/`.

## Data / pipeline flow

`start_recording` → cpal mic + macOS ScreenCaptureKit system audio → DSP pipeline (VAD via silero, noise suppression via nnnoiseless, EBU R128 loudness, symphonia/ffmpeg encode; `incremental_saver` writes checkpoints) → transcription dispatched via `TranscriptionProvider` to Whisper or Parakeet (Parakeet is default) → transcript persisted via `api_save_transcript` → `TranscriptsRepository` → SQLite → `api_process_transcript` → `llm_client::generate_summary()` (provider from DB config: cloud / loopback-only Ollama / BuiltInAI sidecar) → saved via `SummaryRepository`.

**"Ask Meetings"** (`api_answer_meetings_locally`) is local-only RAG over saved transcripts: bounded context (48k chars / 64 sources), loopback-only Ollama, **never invents citations**, sources returned separately from answer text. Unit tests (`local_recall_tests`) enforce these invariants — preserve them.

## Frontend (`frontend/`)

- **Next.js 14 App Router**, static export (`output: 'export'` → `../out`), dev server on **port 3118**. `src/app/layout.tsx` (`'use client'`) hosts the whole provider tree. Routes: `/`, `/chat`, `/meetings`, `/meeting-details`, `/new-meeting`, `/settings`.
- **State: React Context only** (no redux/zustand/react-query). 12 providers in the layout tree; `RecordingStateContext` is the recording source of truth. Backend sync via `src/services/*Service.ts` wrappers + 1s polling of `is_recording` + event listeners.
- **UI:** shadcn/ui (new-york) on Radix + Tailwind 3.4 + `cn()` merge helper. HSL CSS-variable tokens in `src/app/globals.css`. Rich text via BlockNote/Tiptap (single pinned ProseMirror instance — see `next.config.js` aliases). Font: Space Grotesk (self-hosted).
- **`DESIGN.json` / `DESIGN.md`** (repo root) are the design source of truth and are **load-bearing** — `tests/lib/visual-system.test.mjs` asserts the implemented UI matches them.

## Key files reference

- `frontend/src-tauri/src/lib.rs` — command registry / entry
- `frontend/src-tauri/src/audio/pipeline.rs` — mixing + VAD
- `frontend/src-tauri/src/database/repositories/` — DB access
- `frontend/src-tauri/src/summary/summary_engine/sidecar.rs` — llama-helper driver
- `frontend/src/app/layout.tsx` — provider tree
- `frontend/src/contexts/RecordingStateContext.tsx` — recording state machine
