# Open Questions & Working Worklist

PRD §9 discovery items. Investigated 2026-07-14 via read-only code analysis; verdicts below carry `file:line` evidence. Several are now **RESOLVED**; the remainder are user decisions or need the git remote.

## RESOLVED

### Q1 — Which audio stack is live? ✅ `audio/` is live; `audio_v2/` is dead
- `frontend/src-tauri/src/lib.rs:40` declares `pub mod audio;`. `audio_v2` was never declared anywhere (zero references outside its own directory, never compiled) — it has since been **deleted** (2026-07-16).
- Every registered audio command in the `generate_handler!` list (`lib.rs:552-781`) routes into `audio::`.
- The dead files inside `audio/` (`core-old.rs`, `recording_saver_old.rs`, `recording_commands.rs.backup`, `stt.rs`) — never in `audio/mod.rs`, never compiled — have also been **deleted** (2026-07-16).
- Note for F1: the deleted `audio/stt.rs` had a `speaker_embedding: Vec<f32>` field and referenced `pyannote`/`screenpipe_core` (crates absent from `Cargo.toml`). It was an earlier prototype, not live speaker-ID infra — noted here only as a historical pointer for what F1 explored.

### Q2 — The PCM seam for F1 ✅ `audio/pipeline.rs:824`
- Tap point: inside `AudioPipeline::run()`, immediately after `self.ring_buffer.extract_window()` returns `(mic_window, sys_window)` (line 824) and **before** `self.mixer.mix_window(...)` consumes them (line 826).
- Format there: **48 kHz mono f32, ~600 ms windows, mic and system still SEPARATE** — the last point they're separable. One line later they're mixed irreversibly.
- How to tap safely: clone the `Vec<f32>` windows and forward them non-blocking to an independent task/channel — mirror the existing `recording_sender_for_mixed` fork (`pipeline.rs:887-895`). **Never do embedding inference inline** in that loop (it's a single tokio task with a 50 ms recv timeout; blocking it starves VAD and drops speech).
- `AudioChunk` carries a free `device_type: DeviceType` (`Microphone`/`System`) label (`recording_state.rs:19-25`), so "local vs remote" is zero-cost per window.

### Q3 — System-audio channel reality ✅ ONE mixed mono stream
- macOS system audio uses a **Core Audio process tap** (`audio/capture/core_audio.rs:91`, `TapDesc::with_mono_global_tap_excluding_processes` with an empty exclusion list) — captures all system output mixed into one mono stream. **Not ScreenCaptureKit** (the `backend_config.rs` label is stale/aspirational).
- Per-process capture exists in the vendored `cidre` crate (`with_mono_mixdown_of_processes`, etc.) but is **unused** — and even it separates *apps*, not *people within a call*.
- **F1 remote-diarization ceiling is real:** individual remote participants cannot be separated from PCM alone. Pragmatic path = voice-embedding **clustering on the mixed system stream** (no capture-architecture change), leaning on the calendar attendee list (F4) to constrain the label space.

### Q4 — Re-ID integration contract ✅ (see also `../reference/reid-integration-contract.md` findings below)
- **PCM contract:** `AudioChunk { data: Vec<f32> (mono, [-1,1]), sample_rate, timestamp (sec from recording start), chunk_id, device_type }` (`recording_state.rs:19-25`). Two candidate inputs: pre-mix per-device 48 kHz (real source separation, needs own VAD) or post-VAD 16 kHz mixed segments (time-aligned to transcripts, but mixed).
- **`speaker_id` attachment point:** `audio/transcription/worker.rs:208-220`, where `TranscriptUpdate` is constructed — the exact segment PCM (`chunk.data`) is in scope, so re-ID can stamp the result before emit. Plumb a new `speaker_id` through 4 structs: `TranscriptUpdate` → `recording_saver::TranscriptSegment` → `api::TranscriptSegment` → `database::models::Transcript` → the INSERT in `repositories/transcript.rs:49-59`.
- ⚠️ **Do NOT reuse the existing `speaker` column** (migration `20251110000001_add_speaker_field.sql`) — it's dead/unused (never read or written), intended for mic/system labels. Add a distinct `speaker_id TEXT REFERENCES speakers(id)` via a new migration.
- **Timing is free:** segments carry `audio_start_time`/`audio_end_time` (recording-relative seconds); the VAD segment PCM == the transcription PCM == the transcript's time range, so embedding↔segment correlation needs no extra alignment at the worker.
- **F2 DB extension:** repository pattern (`database/repositories/`), timestamped migrations auto-run via `sqlx::migrate!` in `manager.rs:34`; sqlx uses **runtime** `query`/`query_as` (no compile-time macros → no `DATABASE_URL`/offline-cache concern). New tables `speakers` / `persons`(owner_profile) / `profile_facts` attach additively.
- **Threading:** run re-ID as a decoupled `tokio::spawn` (or `spawn_blocking` if CPU-bound). **Recommended contract:** emit the transcript with `speaker_id: None`, run re-ID off the hot path, then patch the DB row when the match completes — never block STT. Keep the ported module a **pure function** (PCM in → speaker_id + updated centroid out); the app owns all DB writes via a repository (per the repositories-only rule).
- **6 open contract questions** to settle with the module authors: embedding input format (pre-mix vs post-VAD), push vs pull, embedding dimension/model, per-segment latency budget, confirm-before-enroll gate ownership, where centroid state persists. These are the real F1 kickoff decisions.

### Q5 — Existing recall / F7 starting point ✅ keyword-only, no index
- `api_answer_meetings_locally` (`api/api.rs:626-721`) is a **safety-hardened shell**: input validation, provider gate (**Ollama loopback-only or BuiltInAI**, no cloud), ~48k-char / 64-source context bounding, anti-hallucination system prompt, and **sources returned separately from the answer** (never trust model citations). Tests enforce these (`local_recall_tests`).
- **Retrieval is pure SQL `LIKE` + term-count scoring** (`repositories/transcript.rs:138-219`). **No embeddings, no vectors, no FTS5, no ANN.** `transcript_chunks` is a one-row-per-meeting text cache for the summarizer, NOT a chunk index.
- **F7 must ADD:** a vector store (sqlite-vec/LanceDB/etc. — nothing today), a real per-chunk+embedding table, an embedding-generation step (candidate: Ollama's embedding endpoint, already the sanctioned loopback provider), and a similarity-search path. **Cleanest seam:** keep the outer command shell; swap only the retrieval call (`api.rs:665-671`) with a new `semantic_search` returning the same row shape, so all bounding/prompt/sources logic is untouched. Frontend wire points unchanged: `src/app/chat/page.tsx:31` (global) and `MeetingDetails/TranscriptPanel.tsx` (meeting-scoped).

## RESOLVED (formerly open)

- **Q6 — Distribution scope.** ✅ **Resolved (2026-07-16):** personal-use scope, **Developer ID + hardened runtime, NO App Sandbox** (sandboxing would break process-tap capture + sidecar model dirs; MAS/notarization not pursued). New code identity means a one-time re-grant of Mic/Screen/Calendar TCC. Revisit only if scope ever widens. See `plans/swift-migration-plan.md` (Decisions).
- **Q7 — Upstream merge-base & rebase cadence.** ✅ **Moot (2026-07-16):** the project has severed from upstream and is now Arivo's own — we no longer track or rebase against Meetily. See `../rules/codebase-ownership.md`.

## Standing risks (unchanged, PRD §9)

- F1 remote-diarization ceiling (mixed system stream) → mitigate with calendar attendee list.
- F2 profile decay / misattribution → provenance + supersession + confidence gate.
- F3/assembly prompt bloat/bias → keep context blocks terse.
- F5 macOS backgrounding + recording consent.

## Tracked tech-debt / follow-ups

- **⚠️ Live `prose` styling bug (pre-existing, not ours to fear breaking):** the loaded `tailwind.config.js` never registers `@tailwindcss/typography`, but `prose` classes are used in `src/app/chat/page.tsx:52` and `MeetingDetails/TranscriptPanel.tsx:176`. Markdown in those panels is unstyled today. Fix = add `require('@tailwindcss/typography')` to the `plugins` array in `tailwind.config.js` (this also enables the config dedup below).
- **Config dedup (verified safe actions):** authoritative configs are `tailwind.config.js`, `postcss.config.js`, `.eslintrc.json`.
  - `postcss.config.mjs` → **safe to delete** (subset missing autoprefixer; Next never loads it).
  - `eslint.config.mjs` → **safe to delete** (`next lint` on Next 14 only reads `.eslintrc.json`).
  - `tailwind.config.ts` → delete ONLY AFTER folding its `@tailwindcss/typography` plugin (and optionally its `fontSize` scale) into `tailwind.config.js`. Never delete `.js` (holds `darkMode: class`, shadcn color tokens, radii, accordion keyframes). Coordinate with in-flight color-token editing; changes to `tailwind.config.js` must stay in lockstep with `DESIGN.json`/`DESIGN.md` (visual-system test).
- **Rebrand `meetily` → `ari`** in the bundle identifier (`com.meetily.ai`) — deferred (changing it relocates the app-data dir, orphaning DB + downloaded models). Cosmetic strings (package.json name, README, Cargo repository) already done.
- **GitLab CI + updater port** — spec in `../reference/ci-and-release.md`. The updater endpoint still points at a GitHub URL and is non-functional until re-pointed; migrate the minisign key intact.
- **Dead-code removal** — ✅ **Done (2026-07-16):** `lib_old_complex.rs`, `audio/*-old.rs`, `*.backup`, `audio/stt.rs`, and `audio_v2/` have been deleted (all were confirmed dead — not declared in `lib.rs`, wired to no command). `frontend/src-tauri/CLEANUP_PLAN.md` still tracks the larger structural cleanups (module dedup, dependency audit).
