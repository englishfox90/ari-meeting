# Speaker Re-ID Integration Contract (F1/F2)

Reference for when the ported voice re-identification module is integrated. Derived from a read-only code investigation (2026-07-14) — verify `file:line` anchors still hold at integration time. Summary lives in `../context/open-questions.md` (Q2/Q3/Q4); this is the detail.

## The audio the module consumes

`AudioChunk` (`frontend/src-tauri/src/audio/recording_state.rs:19-25`):
```rust
pub struct AudioChunk {
    pub data: Vec<f32>,          // mono, [-1.0, 1.0]
    pub sample_rate: u32,
    pub timestamp: f64,          // seconds from recording start
    pub chunk_id: u64,
    pub device_type: DeviceType, // Microphone | System
}
```

Two candidate inputs — this is the biggest design fork, settle it first with the module authors:

| Option | Where | Format | Trade-off |
|--------|-------|--------|-----------|
| **A. Pre-mix, per-device** | `audio/pipeline.rs:824` after `extract_window()` → `(mic_window, sys_window)` | 48 kHz mono f32, ~600 ms windows, **mic & system separate** | Real source separation (local vs remote), but you must run your own VAD/segmentation |
| **B. Post-VAD, mixed** | `audio/transcription/worker.rs` per-chunk (`chunk.data`) | 16 kHz mono f32, VAD-segmented, **mic+system already mixed** | Time-aligned to transcript segments for free, but no source separation |

System audio is a single **mixed** stream (Core Audio process tap, `capture/core_audio.rs:91`) — individual remote participants can't be separated from PCM; plan on embedding-clustering + calendar attendee priors (F4).

## Where speaker_id attaches

Attach at `audio/transcription/worker.rs:208-220` (where `TranscriptUpdate` is built — the segment PCM `chunk.data` is in scope). Plumb a new `speaker_id` through the 4 layered segment structs:

`TranscriptUpdate` (`worker.rs:26-39`) → `recording_saver::TranscriptSegment` (`recording_saver.rs:16-25`) → `api::TranscriptSegment` (`api/api.rs:418-429`) → `database::models::Transcript` (`database/models.rs:26-38`) → INSERT in `repositories/transcript.rs:49-59`.

New migration: `ALTER TABLE transcripts ADD COLUMN speaker_id TEXT REFERENCES speakers(id)`.

⚠️ **Do NOT reuse the existing `speaker` column** (`migrations/20251110000001_add_speaker_field.sql`). It's dead — never read or written anywhere — and was meant for mic/system source labels. F1 needs a *distinct* `speaker_id`.

ℹ️ `audio/stt.rs` (a pyannote/screenpipe prototype, never compiled) has been **deleted** (2026-07-16). It was never live speaker-ID infra — don't expect to find it.

## Timing / correlation

Segments carry `audio_start_time` / `audio_end_time` / `duration` in recording-relative seconds. The VAD segment PCM == the transcription PCM == the transcript's time range, so at the worker the embedding↔segment correlation is free — no separate alignment logic needed (Option B). Under Option A you'd align your own windows back to VAD timestamps by overlap.

## Threading (must not block STT/capture)

Pipeline is tokio-async; `AudioPipeline::run` and the transcription worker are separate spawned tasks (transcription is deliberately serial, `NUM_WORKERS=1`, to preserve chronological order). Run re-ID as a **decoupled `tokio::spawn`** (or `spawn_blocking` if the embedding model is CPU-bound — mirror the bounded `run_blocking_audio_setup` pattern in `stream.rs:22-35`).

**Recommended contract:** emit the transcript immediately with `speaker_id: None`, run re-ID off the hot path, and **patch the DB row** (new repository update method) when the match resolves. Keep the ported module a **pure function** — PCM in → `speaker_id` + updated centroid out — and let the app-side integration layer own all `speakers`/`profile_facts` writes via repositories (per the repositories-only rule). A synchronous attach-before-emit is only acceptable if match latency is proven to be sub-tens-of-ms.

## F2 data model (additive)

New tables via new timestamped migrations, new repositories registered in `database/repositories/mod.rs` (all additive — no edits to existing tables beyond the `speaker_id` column):
- **`speakers`** — id, voice embedding/centroid (fixed-length BLOB or JSON array), enrollment_state, person_id FK, timestamps.
- **`persons` / `owner_profile`** — id, name, role, organization, domain (owner profile may live in settings).
- **`profile_facts`** — id, person_id FK, fact_text, source_meeting_id, source_segment_id, timestamp, self_reported (bool), confidence, superseded_by (self-FK). Provenance + supersession per PRD §7.

Use the `migration-writer` agent to scaffold these in sync.

## Open contract questions for the module authors

1. Embedding input: Option A (pre-mix per-device) or B (post-VAD mixed)?
2. Push (app hands PCM windows) vs pull (module taps audio itself — no entry point exists today)?
3. Embedding dimension / model (affects centroid storage; don't conflate with F7's text-embedding index).
4. Per-segment latency budget (decides sync-attach vs async-patch).
5. Confirm-before-enroll gate: module-internal threshold only, or does it need read access to enrollment state?
6. Where centroid state persists: module-internal store, or the `speakers` table (preferred: app owns writes, module is pure).
