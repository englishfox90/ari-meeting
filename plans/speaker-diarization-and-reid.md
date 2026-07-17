# Plan: Persistent Speaker Diarization & Cross-Meeting Re-ID (F1 → F2)

**Status:** Proposal · **Date:** 2026-07-14 · **Owner:** Paul
**North star:** `meeting-intelligence-prd.md` §F1/F2 · **Discipline:** additive-only (`.claude/rules/additive-only.md`)

> Goal: know *who* said each thing, tie each identified voice to a **person record** (F2) once its
> voice signature is recognized, let the user **listen back to a speaker's segments and assign them**
> to a person, and have that voice signature **improve every meeting**.

This plan synthesizes three investigations: (1) the older `meeting-notetaker` project's speaker-ID
implementation, (2) the exact seams in this codebase, and (3) the 2025–2026 on-device diarization
landscape. Evidence is cited with `file:line` anchors and external URLs.

---

## 1. Executive summary

- **Adopt an offline (post-recording) diarization pass**, not live hot-path diarization. Audio is
  already captured and summarized post-hoc, so we run segmentation + embedding + clustering on the
  finished recording. This sidesteps the biggest risk in the existing re-ID contract (blocking the
  audio/STT loop) and yields higher accuracy than streaming.
- **Engine: `sherpa-onnx` offline diarization, driven from Rust.** It bundles pyannote-segmentation-3.0
  + a speaker-embedding model + clustering + a *named-speaker matcher*, all in C/ONNX with real Rust
  bindings — no Python, no PyTorch. It composes with our existing `ort`/Parakeet stack. This is the
  exact stack the open-source **OpenWhispr** app shipped for the identical problem (local Whisper/Parakeet
  + persistent SQLite voiceprints).
- **Port the *logic*, not the model, from `meeting-notetaker`.** Its crown jewel — cosine + dual-gate
  matching, running-average enrollment, the "suspect cluster" guard, and the listen-back/assign UX —
  is pure, portable, and battle-tested. Its embeddings come from `senko` (a CoreML pipeline) and are
  **not** vector-space-compatible with a Rust embedder, so we re-implement the matcher in Rust against
  a new embedder and re-enroll from scratch.
- **Two free wins unique to our capture architecture:**
  1. The **owner's mic is a clean, single-speaker stream** → hard-enroll the owner with high confidence;
     local speaker attribution becomes essentially free and always correct.
  2. **Calendar attendees (F4) constrain clustering.** Feeding the known speaker count / identities into
     the diarizer is the single biggest accuracy lever on the mixed far-end stream.
- **One real gap to close first:** we currently persist only the **mixed** `audio.mp4`. For both good
  diarization *and* isolated listen-back, we should also persist the **separate mic + system tracks**
  (the old project already did this as `me.wav` / `them.wav`). This is an additive recording fork.

---

## 2. Where we are today (current state)

### F2 is built; F1 is the missing half
Person profiles (F2) and owner-context injection (F3) exist and are keyed on **email, seeded from
calendar attendees** — deliberately *not* voice (see `f2-person-profiles` memory). The DB, `persons/`
module, and repositories are ready to receive a voice-based link:

- `meeting_participants.link_source` already reserves the value **`'speaker'`** for F1
  (`migrations/20260714130000_add_person_profiles.sql:41`).
- `PersonRepository::link_participant(meeting_id, person_id, "speaker")` is the exact hook
  (`database/repositories/person.rs:321`) — `INSERT OR IGNORE`, free-string `link_source`, works today.
- `PersonRepository::upsert_stub_from_attendee` (`person.rs:281`) creates a minimal person from an
  unknown voice.
- There is **no** speaker/voiceprint table, repository, or command yet — that is the net-new F1 surface.

### The audio seams (verified)
- **Only clean per-source tap:** inside `AudioPipeline::run()`, the `if let Some((mic_window, sys_window))`
  block at `audio/pipeline.rs:824`, *before* `mix_window()` at `:826`. Both are 48 kHz mono f32. One line
  later they are mixed irreversibly. The fire-and-forget fork pattern to copy is
  `recording_sender_for_mixed` (`pipeline.rs:869-877`): `.clone()` the buffer, `let _ = sender.send(...)`
  on an unbounded mpsc, never block.
- **Per-segment speaker_id attach point:** `audio/transcription/worker.rs:208-220` (where
  `TranscriptUpdate` is built). But note the segment PCM is **not** carried in `TranscriptUpdate` and the
  audio the worker sees is **mixed 16 kHz** — so live per-segment embedding is awkward. This reinforces
  the offline approach.
- **Recorded audio on disk:** `IncrementalAudioSaver` writes 30 s AAC/mp4 checkpoints and concats to a
  single **`{meetings.folder_path}/audio.mp4`** (`audio/incremental_saver.rs:304`). This is the **mixed**
  stream only — there is no per-speaker or per-source audio on disk today. Every transcript row carries
  `audio_start_time`/`audio_end_time`/`duration` (recording-relative seconds), so segments are seekable.
- **Dead `transcripts.speaker` column** (`migrations/20251110000001_add_speaker_field.sql`) — never read or
  written; do **not** reuse it. F1 needs a distinct `speaker_id`.

### Listen-back is 90% built but orphaned
- `frontend/src/hooks/useAudioPlayer.ts` is a complete Web Audio player (`play/pause/seek/currentTime`),
  loads via `invoke('read_audio_file', {filePath})`, decodes, and `seek(time)` jumps to any offset —
  **but nothing imports it.**
- `read_audio_file` command exists (`lib.rs:233`, registered `:586`).
- `MeetingDetails/TranscriptPanel.tsx` already receives `meetingFolderPath` and renders per-segment
  timestamps — but no `<audio>` element / player. Wiring is small.

---

## 3. What `meeting-notetaker` gives us (port map)

The old project is Python (CLI + FastAPI/Vue) and gets its embeddings from **`senko`** (a WeSpeaker-style
CoreML VAD→embedding→UMAP+HDBSCAN pipeline). The ML is **not** portable to our Rust stack, but the
**persistent-speaker intelligence around it is pure and ports directly** — reimplement in Rust.

| Piece to port | Source (old project) | Portability | Our target |
|---|---|---|---|
| **Cosine + dual-gate matching** — absolute threshold **0.72** *and* a **0.08 margin** over the runner-up, else "ambiguous, not auto-assigned"; greedy 1-name-per-meeting | `notetaker/speakers.py:67-116` | **Pure logic — port as-is** (retune thresholds for the new embedder) | Rust `speaker_matching.rs` |
| **Running-average enrollment** — `emb = (emb·n + new)/(n+1)`, `samples = n+1`; this is "improves over time" | `speakers.py:38-54` | **Pure — port** | `SpeakerRepository::fold_centroid` |
| **Suspect-cluster guard** — never enroll a profile from a cluster that failed verification ("a profile built from it matches everyone — learned the hard way") | `cli.py:272-277`, `verify.py` | **Concept ports** (verification API is senko-specific) | quality gate before enroll |
| **Match-suggestion reporting** — per-speaker `{name, score, runner_up, eligible, reason}` with reasons `below_threshold`/`ambiguous_margin`/`no_embedding` | `ui/server/notes_repo.py:274-316` | **Pure logic — port** | `speaker_match_suggestions` command |
| **Sidecar-enables-later-naming** — persist per-meeting per-cluster centroids so the user can name a speaker *after the fact* and back-save the profile | `cli.py:152-159` | **Design pattern — adopt** | `speaker_segments` rows keep the cluster embedding |
| **Listen-back + assign UX** — Range-streamed audio, per-utterance click-to-seek, speaker chip → rename dialog showing "Looks like **Sarah** (0.84)" | `ui/web/src/features/notes/*.vue`, `notes.py` | **Pattern — adopt** (we have `useAudioPlayer` already) | wire into `TranscriptPanel` |
| **Two-track capture** (`me.wav` mic / `them.wav` system) | `capture/*.swift`, `record.py` | **Validates our proposed separate-tracks fork** | new recording fork |

**Key takeaway:** the old project independently arrived at exactly the design the PRD and the external
research recommend — running-mean centroids, cosine matching with a confirm band, and post-hoc naming
backed by stored per-meeting embeddings. We inherit a proven blueprint; we just re-home it in Rust with
a Rust-runnable embedder.

---

## 4. Recommended technical approach

### 4.1 Offline, post-recording diarization
Run the diarization pass **when recording stops** (or on demand for imported/old meetings), on the
finished audio. Rationale: no hot-path risk, higher accuracy than streaming, and it matches how the old
project worked. The re-ID integration contract's "emit `speaker_id: None`, patch later" concern
disappears — we assign speakers in a clean batch step and write them once.

### 4.2 Engine: `sherpa-onnx` (recommended) — with a helper-sidecar option
The `sherpa-onnx` Rust crate exposes the whole pipeline: `OfflineSpeakerDiarization`,
`OfflineSpeakerSegmentationPyannoteModelConfig`, `FastClusteringConfig`, `SpeakerEmbeddingExtractor`, and
a `SpeakerEmbeddingManager` (an index of *named* embeddings) + `SpeakerEmbeddingMatch`. You can set
`num_speakers` (the calendar prior) or a clustering threshold.

- **Embedding model:** **CAM++ (512-dim, Apache-2.0)** — fastest, ~0.66% EER, ANE/CPU-friendly,
  the model OpenWhispr uses. Fallbacks: WeSpeaker ResNet34 (max accuracy) or ERes2NetV2 (tuned for short
  turns). Models download at runtime like our Parakeet/GGUF weights (~45 MB total).
- **Isolation decision (open — see §9):** `sherpa-onnx` runs ONNX Runtime in-process, and we already link
  `ort` for Parakeet. To avoid ONNX-Runtime version/link conflicts and to sandbox model crashes/RAM the
  way we already do for llama.cpp, the **cleanest fit is a `diarize-helper` sidecar** (mirror
  `llama-helper/`: standalone crate, stdin/stdout JSON, staged into `binaries/`). If in-process linking
  proves clean, skip the sidecar. This is the first thing to de-risk with a spike.

**Runner-up: FluidAudio (Swift/CoreML, Apache-2.0).** ANE-accelerated (~0.017 RTF on M1), pairs with a
Swift sidecar (we already ship one for the notch). It gives diarization + embeddings but **no persistent
enrollment** — we'd build all of §4.4 ourselves anyway. Choose this only if ANE speed matters more than
the turnkey Rust API.

**Explicitly not now:** pyannote-as-runtime (Python/PyTorch), NeMo Sortformer (GPU/Python, 4-spk cap),
diart, Resemblyzer. **Watch:** ReDimNet2 once a clean ONNX export lands.

### 4.3 The mixed-far-end problem & the two free wins
- All remote participants arrive as **one mixed mono system stream** (Core Audio process tap,
  `capture/core_audio.rs:91`). Individual remote speakers **cannot** be source-separated at capture —
  overlapped remote speech is an irreducible DER ceiling. Mitigate, don't fight it.
- **Win 1 — owner from mic:** the mic stream is clean and single-speaker. Enroll the owner's centroid
  from it with high confidence and hard-label all owner turns. Free, always correct.
- **Win 2 — calendar prior:** set the diarizer's `num_speakers ≈ (attendees − 1)` (minus owner), clamped
  to a sane min/max, and pre-seed the label space with attendee identities. Research is consistent that
  supplying the known speaker count materially improves clustering (auto-count under-represents quiet
  speakers). Unmatched clusters become "unknown attendee N," candidates for confirm-before-enroll.

### 4.4 Persistent re-identification (the "improves over time" core)
Copy OpenWhispr's proven design (which matches the old project and the PRD):
- **Storage:** one centroid `float32` vector per person as a SQLite **BLOB** (~2 KB), tagged with the
  `embedding_model` + `dim` (voiceprints are only comparable within one model's vector space — store the
  model id so a future model swap forces a clean re-enroll rather than silent mismatches).
- **Three-tier cosine matching** (better UX than a single threshold; honors confirm-before-enroll):
  - **≥ 0.70** → auto-confirm, label instantly.
  - **0.55–0.70** → suggest ("Is this Alice?"), require confirm.
  - **< 0.55** → stay anonymous until named.
  (Start here; **retune on real recordings** — the old project used 0.72 + a 0.08 margin for its embedder.)
- **Quality-weighted running-mean update** on confirm: `new = (stored·n + emb)/(n+1)`, but only fold in
  embeddings from VAD-clean, sufficiently-long, high-similarity segments so noisy/overlapped audio can't
  corrupt a profile. This is the signature improving each meeting.
- **Retroactive relabeling:** when a user names a speaker, walk historical unnamed cluster embeddings,
  match, and back-fill — never overwriting user-locked assignments.
- **Confirm-before-enroll ownership:** keep the matcher a **pure function** (embedding in → match +
  proposed centroid out); the app layer owns the confirm dialog and all DB writes via repositories
  (per the repositories-only rule). Never auto-enroll below the high threshold.

---

## 5. Architecture & data model (all additive)

### New Rust module: `diarization/`
- `diarization/mod.rs`, `engine.rs` (sherpa-onnx driver or sidecar client), `matching.rs` (ported pure
  matcher), `commands.rs`. Declared in `lib.rs` at the module + `generate_handler!` registration points
  only — no edits to upstream logic.
- Optional new crate `diarize-helper/` (if we sidecar the engine), staged into `binaries/` like
  `llama-helper`.

### New migration (via the `migration-writer` agent)
```sql
-- speakers: one voiceprint per known person (+ transient per-meeting clusters)
CREATE TABLE speakers (
  id              TEXT PRIMARY KEY,
  person_id       TEXT REFERENCES persons(id) ON DELETE SET NULL,  -- NULL until assigned
  label           TEXT,               -- "Speaker 1" fallback display
  centroid        BLOB NOT NULL,      -- float32[dim]
  embedding_model TEXT NOT NULL,      -- e.g. 'campplus-512'  (vector-space guard)
  dim             INTEGER NOT NULL,
  samples         INTEGER NOT NULL DEFAULT 1,
  enrollment_state TEXT NOT NULL DEFAULT 'provisional', -- provisional|confirmed|owner
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);

-- speaker_segments: per-meeting diarized turns + the cluster embedding (enables post-hoc naming)
CREATE TABLE speaker_segments (
  id          TEXT PRIMARY KEY,
  meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  speaker_id  TEXT REFERENCES speakers(id) ON DELETE SET NULL,
  cluster_key TEXT NOT NULL,          -- per-meeting anonymous cluster label
  start_time  REAL NOT NULL, end_time REAL NOT NULL,
  source      TEXT NOT NULL,          -- 'mic' (owner) | 'system' (remote)
  embedding   BLOB,                   -- this cluster's centroid, for back-fill/relabel
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_speaker_segments_meeting ON speaker_segments(meeting_id);
```
Plus a per-transcript link so summaries/UI can show who said each line. Prefer a **new**
`transcripts.speaker_id TEXT REFERENCES speakers(id)` column (a fresh migration) over the dead `speaker`
column, per the re-ID contract.

### New repository: `SpeakerRepository`
`insert_provisional`, `list_for_meeting`, `assign_to_person`, `fold_centroid` (running-mean update),
`match_candidates` (returns scored persons for a cluster), `backfill_relabel`. All writes app-side;
matcher stays pure.

### New commands (Tauri, camelCase args)
- `diarize_meeting(meetingId)` → runs the offline pass, writes `speaker_segments` + provisional speakers.
- `speaker_list_for_meeting(meetingId)` → clusters + current assignment + best match suggestion.
- `speaker_match_suggestions(meetingId, clusterKey)` → `{name, score, runnerUp, eligible, reason}` (ported).
- `speaker_assign_to_person(speakerId, personId)` → links, folds centroid, `link_participant(…, "speaker")`,
  triggers retroactive relabel.
- `speaker_segment_audio(meetingId, startTime, endTime[, source])` → bytes/URL for listen-back.

### Flow
```
recording stops
  → finalize audio (mixed + [new] separate mic/system tracks)
  → diarize_meeting: mic track → owner cluster; system track → segment+embed+cluster
      (num_speakers from calendar attendees)
  → match each cluster centroid vs enrolled speakers (three-tier cosine)
  → write speaker_segments + provisional speakers; auto-assign ≥0.70; mark 0.55–0.70 as "suggested"
  → summary prompt & UI now know who said what
user opens meeting
  → transcript shows speaker chips; ambiguous ones prompt
  → user listens back to a cluster's segments, assigns to a person
  → fold_centroid (signature improves) + backfill_relabel history
```

---

## 6. The separate-tracks gap (recommended, additive)

Today only the mixed `audio.mp4` is on disk, which hurts both diarization quality and listen-back
(playing a "remote" segment also plays the owner's mic bleed). The old project solved this by recording
`me.wav` (mic) and `them.wav` (system) separately.

**Recommendation:** add a **second recording fork** that also persists the mic and system tracks
separately (e.g. `mic.m4a` / `system.m4a` alongside `audio.mp4`). Tap at the same
`pipeline.rs:824` window where they're still separate, mirroring `recording_sender_for_mixed`. This is
purely additive (new sinks, new files) and unlocks:
- **Owner isolation for free** (mic track = owner only → clean owner enrollment).
- **Better remote diarization** (cluster on the system-only track, no owner bleed).
- **Cleaner listen-back** (play the source track for a segment).

If disk/complexity is a concern, a lighter first step is to persist only the **mic** track separately
(owner isolation is the highest-value, lowest-cost win) and keep clustering the mixed system portion.

---

## 7. Listen-back & assign UX (mostly wiring)

We already have `useAudioPlayer` (orphaned) + `read_audio_file` + per-segment timestamps. Build:

1. **Wire `useAudioPlayer` into `MeetingDetails/TranscriptPanel.tsx`**, deriving the audio path from
   `meetingFolderPath` (mixed `audio.mp4`, or per-source track once §6 lands).
2. **Speaker chips per transcript line** (from `transcripts.speaker_id` / `speaker_segments`), styled per
   Signal Desk (amber only for the *active/selected* speaker, ≤8% rule; No-Fake-State — show real match
   scores, never invented ones).
3. **Click a timestamp → `seek(segment.audio_start_time)` and play** (old project's per-utterance seek).
4. **Speaker chip → assign dialog** showing ranked suggestions: "Looks like **Sarah** (0.84) — Use Sarah",
   a mid-confidence "closest profile… Use anyway", or a free-text/attendee picker (pre-filled from
   calendar attendees). On confirm → `speaker_assign_to_person`.
5. **A "Review speakers" affordance** for meetings with unassigned/ambiguous clusters (mirrors the
   existing pending-fact review on `/people`).

---

## 8. Phased implementation plan

Front-loads de-risking (engine spike) and the free win (owner mic), defers the hardest part
(remote clustering quality) — consistent with the PRD's phasing philosophy.

- **Phase A — Engine spike & decision (de-risk first).** Prove sherpa-onnx offline diarization runs on
  Apple Silicon from Rust; decide **in-process vs `diarize-helper` sidecar** (ONNX-Runtime coexistence
  with `ort`); confirm CAM++ embeddings + clustering on a sample two-track recording. Output: a working
  `embed(wav) → Vec<f32>` + `diarize(wav) → segments`. *No product wiring yet.*
- **Phase B — Data model & pure matcher.** New migration (`speakers`, `speaker_segments`,
  `transcripts.speaker_id`), `SpeakerRepository`, and the **ported pure matcher** (cosine + dual-gate +
  running-mean) with unit tests translated from `speakers.py`.
- **Phase C — Separate-tracks recording fork** (§6). At minimum the mic track; ideally mic + system.
- **Phase D — Offline diarization pass + owner enrollment.** `diarize_meeting` command run on stop and
  on-demand; hard-enroll owner from the mic track; write `speaker_segments`; auto-assign ≥0.70.
- **Phase E — Calendar-prior clustering.** Feed attendee count/identities into the diarizer and pre-seed
  match candidates from meeting attendees (F4 already provides them).
- **Phase F — Listen-back & assign UX** (§7): wire `useAudioPlayer`, speaker chips, assign dialog with
  suggestions, retroactive relabel on assign.
- **Phase G — Summary integration.** Inject speaker-attributed transcript into the `SummaryContext`
  assembler so summaries say "Sarah proposed…"; enrich F2 fact extraction with speaker attribution
  (replaces today's coarse name/email matching — see `f2-person-profiles` deferred item).
- **Phase H — Quality & drift.** Quality-weighted centroid updates, suspect-cluster guard, threshold
  tuning on real recordings, a profile-management surface (view/forget voiceprints), and metrics.

---

## 9. Open decisions for you

1. **Engine execution model:** in-process `sherpa-onnx` crate vs a `diarize-helper` sidecar. (Recommend:
   spike both in Phase A; default to sidecar if `ort`/ONNX-Runtime linking conflicts. **Your call on
   appetite for a second helper crate.**)
2. **Separate audio tracks:** full mic+system, mic-only, or stay mixed? (Recommend mic+system; mic-only
   is the acceptable minimum.) This affects disk usage and recording code surface.
3. **When to diarize:** automatically on every recording stop, or on-demand when the user opens a meeting?
   (Recommend: auto on stop for new meetings, on-demand for imported/old ones.)
4. **Embedding model:** CAM++ (speed) vs WeSpeaker ResNet34 (accuracy). (Recommend CAM++ to start.)
5. **Scope of retroactive relabel:** all history, or only recent/opt-in? (Privacy/perf trade-off.)
6. **Old `voices.json` profiles:** discard (re-enroll from scratch — required, since the vector space
   differs) — confirm you're fine losing the old project's enrolled voices.

---

## 10. References

**This codebase:** `audio/pipeline.rs:824` (PCM tap), `audio/transcription/worker.rs:208-220`
(speaker_id attach), `audio/incremental_saver.rs:304` (audio.mp4), `frontend/src/hooks/useAudioPlayer.ts`
(orphaned player), `database/repositories/person.rs:281,321` (stub + link hooks),
`migrations/20260714130000_add_person_profiles.sql` (F2 schema),
`.claude/reference/reid-integration-contract.md`, `.claude/context/open-questions.md` (Q1–Q5).

**Old project (`meeting-notetaker`):** `notetaker/speakers.py:38-116` (enrollment + matching),
`notetaker/diarize.py` (senko), `notetaker/verify.py` (suspect guard),
`ui/server/routers/notes.py` + `ui/web/src/features/notes/*.vue` (listen-back/assign UX),
`capture/*.swift` (two-track capture).

**External:**
- OpenWhispr — Local Speaker Diarization (closest reference impl): https://openwhispr.com/blog/local-speaker-diarization
- sherpa-onnx Rust crate (offline diarization + SpeakerEmbeddingManager): https://docs.rs/sherpa-onnx/latest/sherpa_onnx/
- FluidAudio (Swift/CoreML diarization, runner-up): https://github.com/FluidInference/FluidAudio
- CAM++ (3D-Speaker): https://arxiv.org/html/2303.00332v3 · ONNX: https://huggingface.co/csukuangfj/speaker-embedding-models
- WeSpeaker: https://github.com/wenet-e2e/wespeaker
- pyannote segmentation-3.0 (model source, not runtime): https://huggingface.co/pyannote/speaker-diarization-3.1
- Apple SpeechAnalyzer (no native diarization): https://developer.apple.com/documentation/speech/speechanalyzer
- Oracle-speaker-count improves clustering: https://arxiv.org/html/2505.10879v1
- Hyprnote (Tauri mic+system reference): https://news.ycombinator.com/item?id=44725306
