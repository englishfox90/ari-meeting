# Diarization — Build & Tuning Reference

**Purpose:** everything you need to debug and tweak speaker diarization / re-ID. Companion to the design doc `plans/speaker-diarization-and-reid.md`. Written 2026-07-14.

> **Status:** Phases A–G code-complete (engine, schema, recording fork, orchestration, calendar prior, UX, summary attribution). P0 (post-process + idempotency) and **P1 (voiceprint lifecycle — duration-weighted gated folding, merge-to-canonical, retroactive relabel, speech-gated owner enrollment, owner-via-voiceprint for imports, calendar-count-as-cap)** landed. Everything below is live unless marked TODO.

---

## 0. TUNE HERE FIRST — the runtime config (no rebuild)

Diarization clustering is now tunable at runtime via a JSON file — **edit it, re-run "Identify speakers", done.** No recompile.

**File:** `~/Library/Application Support/com.meetily.ai/diarization-tuning.json` (create it if absent).
```json
{
  "clusterThreshold": 0.9,
  "mergeThreshold": 0.9,
  "minClusterSecs": 10.0,
  "minClusterFrac": 0.005,
  "speakerCount": "auto"
}
```
All keys are optional; a missing key uses its default (so an empty `{}` = full defaults).

> **This is the empirically-validated config as of 2026-07-15**, not the raw code defaults (which are `mergeThreshold` 0.7 / `minClusterFrac` 0.02). It was calibrated against two real recordings — a 45-min 4-person remote meeting (**Metro2**) and a ~10-min 1:1 (**Adhoc with Nia**) — and yields **Metro2 → 4** and **Nia → 2** where the raw defaults gave **2 / 2**. See "Empirical calibration" below for the method and the key insight (the fractional floor, not `mergeThreshold`, was the real blocker).

- **`clusterThreshold`** (default **0.9**) — the sidecar's fast-clustering dendrogram cut, used in auto mode. **HIGHER = FEWER speakers** (more merging); LOWER = more speakers (more splitting). No single threshold converges alone — the real work is the app-side **post-merge + floor** below.
- **`mergeThreshold`** (default **0.7**) — app-side greedy centroid **post-merge** cutoff. After the sidecar returns clusters, pairs whose per-cluster CAM++ centroid cosine is `≥ this` are merged (duration-weighted mean, re-L2-normalized), repeatedly, until no pair qualifies. Auto mode only. Lower = more aggressive merging.
- **`minClusterSecs`** (default **10.0**) / **`minClusterFrac`** (default **0.02**) — the **speech-time floor**. A cluster survives only if its total speech ≥ `max(minClusterSecs, minClusterFrac × total speech)`. Clusters below the floor are dissolved: their segments are reassigned to the nearest surviving cluster if its centroid cosine ≥ 0.5, else dropped (left unlabeled — never invent identity). A guard always keeps at least the largest cluster if any speech exists.
- **`speakerCount`** (default **`"auto"`**):
  - `"auto"` — ignore the calendar; let clustering + post-merge/floor decide. **This is the default now.**
  - `"calendar"` — use the calendar attendee count as an **upper-bound CAP, not a forced K** (P1). Auto-clustering + post-merge/floor run exactly as in auto mode; then, if more clusters survive than the attendee count, postprocess greedily merges the closest centroid pairs (ignoring `mergeThreshold`) until `≤ cap`. The cap is the **FULL attendee count** (clamped 1–12), **NOT** `attendees − 1` — on the mixed system stream the owner is present in the audio too. Opt-in; harmless when the attendee list is sparse (cap only bites when it's exceeded).
  - an integer, e.g. `2` — force exactly N speakers (great for testing a known 1:1 → set `2`, or `1` for the remote side of a 1:1). Post-merge skipped (forced-K pins the sidecar); floor still runs.

**Why the old results were bad:**
- The 1:1 → 44 speakers = auto clustering with the OLD hardcoded threshold `0.5`, which massively over-split. The validated fix is `clusterThreshold` 0.9 **plus** the app-side post-merge (≥0.7) + floor, which yields the correct counts (2 on the real 1:1, 5 on a 43-min team meeting).
- The 8-speaker meeting = the calendar prior *forcing* 8 clusters. That prior is **no longer forced by default** (`"auto"`). Set `"calendar"` only if you want it back.

**Empirical calibration (2026-07-15) — why the recommended config differs from the code defaults:**

Calibrated by driving the real `diarize-helper` sidecar on two recordings, then replaying the exact `postprocess` logic offline to sweep the knobs (harness reproduced production 1:1 — raw defaults give Metro2=2, Nia=2, matching the DB). Findings:

- **The fractional floor (`minClusterFrac`), not `mergeThreshold`, was the dominant blocker.** Metro2 has ~2147s of speech, so `minClusterFrac` 0.02 sets the floor at **42.9s** — which dissolved Metro2's real 3rd/4th speakers (16s and 13s of speech). *Even with no post-merge at all*, that floor caps Metro2 at 3. Lowering `minClusterFrac` to **0.005** lets them survive.
- **`minClusterSecs` 10.0 is the natural guard between the two meetings.** Nia's spurious clusters are all ≤8.5s; Metro2's real smaller speakers are ≥13s. The 10s absolute floor sits cleanly in that gap, so lowering `minClusterFrac` does not inflate Nia.
- **`mergeThreshold` 0.7 → 0.9 is the secondary lever.** At 0.7, Metro2's two smaller speakers (centroid cosine ~0.84 to the dominant voice) got absorbed into it; 0.9 keeps them separate while still folding a true duplicate fragment (cosine 0.93) back in. Higher = fewer merges = more speakers preserved.

⚠️ **Mixed-stream ceiling — read before trusting a high count.** Metro2 is a remote meeting captured as ONE mixed mono stream (the Core Audio system-audio tap; all remote participants share a channel — see the F1 remote-diarization ceiling in `open-questions.md` Q3). Its cluster centroids bunch at cosine **0.6–0.93** instead of the clean ~0.25 cross-speaker separation CAM++ gives on in-person mic audio. So Metro2's 13s/16s clusters *may* be fragments of the dominant speaker rather than 4 distinct humans — the config produces the count 4 reliably, but confirm by listening. This is the mixed-stream limit, not a tuning bug.

**Per-meeting override (wanted, not yet built):** the tuning file is **global**, so `speakerCount: N` (forced-K) is unusable as a shared setting — it would force *every* meeting to N. A lopsided remote meeting like Metro2 is exactly the case where a **per-meeting `speakerCount` / knob override** would be the clean fix (set "4" on this one meeting, leave others on auto). Tracked as a future feature; today the global auto config above is the right default.

**Tuning loop:** edit the JSON → hit "Identify speakers" → check the count → adjust. Re-running is now **idempotent** — `diarize_meeting` clears the meeting's prior diarization first (§9 item 2), so no manual SQL cleanup is needed. The chosen mode/threshold + post-process before→after counts are logged each run: `grep "🎙️ diarize" ~/Library/Logs/com.meetily.ai/ari.log`.

> Only the matcher/enrollment thresholds (§3B) and the embedding model still require an edit+rebuild. Cluster count + threshold are runtime.

---

## 1. What it does (end-to-end flow)

```
recording stops
  → 3 audio files written to the meeting folder:
      audio.mp4   (mixed, unchanged legacy path)
      mic.m4a     (owner mic only — clean, single speaker)     ← Phase C
      system.m4a  (all remote participants, one mixed stream)  ← Phase C
  → frontend fires diarize_meeting(meetingId) after save (fire-and-forget)   ← auto-trigger
        (also a manual "Identify speakers" button when a meeting has 0 speakers)

diarize_meeting (Rust, offline, off the hot path):
  1. ensure_models()  → downloads 2 ONNX models on first use
  2. OWNER: transcode mic.m4a → 16kHz wav → embed → owner voiceprint (upsert + fold)
  3. REMOTE: transcode system.m4a → 16kHz wav → sidecar diarize(num_speakers)
        → segments [{start,end,spk_i}] + per-cluster CAM++ centroid
  4. MATCH each cluster centroid vs enrolled voiceprints (pure matcher)
        - AutoConfirm (≥0.70 & margin) → reuse enrolled speaker, fold centroid, link person
        - else → new PROVISIONAL speaker (person_id = NULL), user assigns later
  5. STAMP each transcript row with the speaker whose segment it most overlaps
  6. write speakers + speaker_segments; transcripts.speaker_id set

UI:
  - transcript lines show speaker chips
  - "Review speakers" → per-speaker cards: sample lines + ▶ play clip + Assign
  - assigning enrolls that voiceprint → auto-matches in FUTURE meetings
```

**Key idea:** the sidecar's `spk_0/1/2…` labels are **per-file only** — they are NOT identities. Cross-meeting identity is done by comparing **CAM++ centroids** (cosine similarity) against stored voiceprints.

---

## 2. Component map (where everything lives)

### Rust backend — `frontend/src-tauri/src/`
| File | Role |
|------|------|
| `diarization/matching.rs` | **PURE matcher** — cosine, running-mean centroid fold, dual-gate 3-tier matching, greedy no-double-assign, quality gate. No DB/IO. **All thresholds live here.** 24 unit tests. |
| `diarization/engine.rs` | Sidecar client (spawn + NDJSON), ffmpeg 48k→16k transcode, model download (`ensure_models`), f32↔BLOB helpers (`centroid_to_bytes`/`bytes_to_centroid`). |
| `diarization/commands.rs` | Orchestration + Tauri commands. `diarize_meeting`, `speaker_list_for_meeting`, `speaker_assign_to_person`, `speaker_match_suggestions`. Owner enrollment, cluster matching, transcript stamping. |
| `diarization/labeling.rs` | `resolve_meeting_speaker_labels` / `build_labeled_transcript_text` — speaker_id→name resolution for chips + summary + extraction. Command `meeting_speaker_labels`. |
| `database/repositories/speaker.rs` | `SpeakerRepository` — all speaker/segment DB access. |
| `audio/pipeline.rs:~830` | **The recording fork** — clones pre-mix mic/system windows to two extra savers (the one approved in-place upstream edit). |
| `audio/recording_saver.rs` / `incremental_saver.rs` | Write `mic.m4a` / `system.m4a` (prefix mechanism; `audio.mp4` byte-identical). |
| `api/api.rs` + `database/repositories/meeting.rs` | `MeetingTranscript` DTO now carries `speaker_id` (2 build sites) so chips render. |
| `persons/commands.rs` / `persons/extraction.rs` | F3 "Speakers present" block + speaker-grounded fact extraction (Phase G). |

### Sidecar — `diarize-helper/` (its OWN cargo workspace, repo root)
| File | Role |
|------|------|
| `diarize-helper/src/main.rs` | sherpa-onnx driver. NDJSON stdin/stdout. `diarize` + `embed` + `--probe`. **Clustering config lives here.** |
| `diarize-helper/Cargo.toml` | Isolated (empty `[workspace]`). `sherpa-onnx = "1.13.4"`, static. Built separately. |
| `diarize-helper/SPIKE_NOTES.md` | The engine spike notes — confirmed API, model URLs, build facts. |

### Frontend — `frontend/src/`
| File | Role |
|------|------|
| `services/speakerService.ts` | Wraps all 5 diarization commands. |
| `hooks/meeting-details/useMeetingSpeakers.ts` | Fetches speakers, derives "Speaker N" display names. |
| `components/MeetingDetails/SpeakerReviewPanel.tsx` | The "Review speakers" modal. |
| `components/MeetingDetails/SpeakerAssignDialog.tsx` | Assign one speaker: samples + ▶ play + suggestions + person picker + create-new + "already assigned" guard. |
| `components/MeetingDetails/SpeakerSampleList.tsx` + `lib/speaker-samples.ts` | Per-speaker sample lines + clip playback. |
| `components/MeetingDetails/SpeakerChip.tsx` | Per-transcript-line chip. |
| `contexts/AudioPlaybackContext.tsx` | Meeting audio player (`seekAndPlay(sec)` powers clip playback). |
| `hooks/useRecordingStop.ts` | Fires `diarizeMeeting` after save. |

---

## 3. Tuning knobs (all HARDCODED → edit + rebuild; there is no settings UI yet)

### A. Cluster count / how many speakers (biggest lever) — RUNTIME, no rebuild
Tune via `diarization-tuning.json` — see **§0**. `clusterThreshold` (higher = fewer speakers) + `mergeThreshold` + `minClusterSecs`/`minClusterFrac` + `speakerCount` (`auto`/`calendar`/N). Code for reference:
- `frontend/src-tauri/src/diarization/tuning.rs` — the config loader + defaults (Auto, clusterThreshold **0.9**, mergeThreshold 0.7, minClusterSecs 10.0, minClusterFrac 0.02). `DiarTuning::postprocess_config()` maps these into the post-process config.
- `frontend/src-tauri/src/diarization/postprocess.rs` — **pure, unit-tested** post-merge + floor stage (the real lever). Greedy duration-weighted centroid merge at `mergeThreshold`, then the speech-time floor. Runs BEFORE matching/enrollment/stamping. Post-merge is auto-mode only; the floor always runs.
- `frontend/src-tauri/src/diarization/commands.rs` — reads tuning, computes `(num_speakers, threshold)` per mode, runs `postprocess` on the sidecar result (`apply_merge = num_speakers.is_none()`).
- `diarize-helper/src/main.rs` `diarization_config` — auto arm uses the request `threshold` (fallback **0.9**; the app always sends one in auto mode). Positive `num_speakers` → exact `num_clusters=N` (threshold ignored). `min_duration_on`/`min_duration_off` (short-turn gating) are still hardcoded here — edit + rebuild the sidecar to change them.

### B. Match / enrollment thresholds — `frontend/src-tauri/src/diarization/matching.rs` (`MatchConfig::default`)
```rust
auto_threshold:            0.70   // ≥ this AND margin → auto-assign to an enrolled speaker
suggest_threshold:         0.55   // ≥ this → shown as a suggestion (user confirms); below → anonymous
margin:                    0.08   // best must beat runner-up by this to auto-confirm
min_enroll_duration_s:     3.0    // a segment must be ≥ this to fold into a voiceprint
min_enroll_self_similarity:0.60   // suspect-cluster guard
```
These are **CAM++ starting guesses, not measured.** Raise `auto_threshold` if wrong people get auto-merged; lower it if the same person never re-matches across meetings. Used via `MatchConfig::default()` in `commands.rs`.

**Folding semantics (P1 — "voiceprint improves over time").** When a cluster is folded into a stored voiceprint, the fold is **duration-weighted + quality-gated**, not a naive running mean:
- `fold_centroid_weighted(stored, W, new, w)` computes `new = (stored·W + emb·w)/(W + w)` then re-L2-normalizes. `w` = the new cluster's total speech seconds; `W` = the voiceprint's stored `total_speech_secs` **capped at `FOLD_WEIGHT_CAP_SECS` (600s)** as the weight. So a long/confident cluster moves the centroid more than a short one, and once a voiceprint is mature (≥600s folded) it behaves as an **exponential moving average** (each new fold weighs `w/(600+w)`) — it keeps adapting instead of ossifying. The stored `total_speech_secs` keeps accumulating past 600 (only its use as a *weight* is capped).
- `should_fold(cluster_secs, emb, stored_len, match_score, cfg)` gates the fold: skips (keeps the match, logs why) when cluster speech `< MIN_FOLD_SPEECH_SECS` (5s), the centroid is empty/zero/dim-mismatched, or (for cross-speaker matches) `match_score < auto_threshold + margin` (**suggest-tier matches never fold** — only unambiguous auto-confirms do). The owner path passes `match_score = None` (owner enrollment isn't a cross-speaker match).
Both live in `matching.rs` (pure, unit-tested). The owner enrollment and matched-cluster folds in `commands.rs`, plus the merge-to-canonical and retro-relabel folds, all go through them.

### C. Embedding model — `frontend/src-tauri/src/diarization/engine.rs:~56-61`
CAM++ **192-dim** (`3dspeaker_speech_campplus_sv_zh_en...onnx`) + pyannote-segmentation-3.0. (Earlier docs said 512-dim — that was stale; the actual dim is reported by the extractor and stored in the `dim` column, and the code is dim-agnostic.) To swap the embedder you must also re-enroll (voiceprints are only comparable within one model's vector space — the `embedding_model` column guards this).

### D. Sidecar timeouts — `engine.rs:~79-81`: diarize 600s, embed 120s.

> After editing any Rust/sidecar file you must **rebuild** (§7). The sidecar and the app build separately.

---

## 4. The sidecar (diarize-helper)

- **Engine:** sherpa-onnx 1.13.4, static. ONNX Runtime is statically bundled and isolated from the app's `ort` (no conflict). It's its own cargo workspace so the main `cargo build` never compiles it.
- **Build + stage:** `cd diarize-helper && cargo build --release` then copy `target/release/diarize-helper` → `frontend/src-tauri/binaries/diarize-helper-aarch64-apple-darwin`. `frontend/scripts/run-local.sh` does this automatically **but only if the staged binary is missing** (`if [ ! -f ]`), so after editing the sidecar you must delete/overwrite the staged binary or it won't re-stage.
- **Binary resolution (engine.rs):** `ARI_DIARIZE_HELPER_BIN` env override → exe-adjacent (`binaries/…` in the bundle) → `target/{release,debug}`. Under plain `tauri dev` it may not resolve — use the signed `app:local` bundle.
- **Protocol (NDJSON, one JSON object per line):**
  - `{"type":"embed","wav_path":"…"}` → `{"type":"embedding","dim":512,"vector":[…]}`
  - `{"type":"diarize","wav_path":"…","num_speakers":N|null}` → `{"type":"segments","segments":[{"start","end","speaker":"spk_0"}],"clusters":[{"speaker":"spk_0","dim":512,"centroid":[…]}]}`
  - `--probe` → `{"type":"probe_result","runtime_ok":true,…}`
- **Models** download at runtime to `~/Library/Application Support/com.meetily.ai/models/diarization/` (~45 MB). URLs are `const` in `engine.rs`.

### Test the sidecar in isolation (no app)
```bash
cd diarize-helper
SEG=~/Library/Application\ Support/com.meetily.ai/models/diarization/segmentation.onnx   # or wherever ensure_models put it
EMB=~/Library/Application\ Support/com.meetily.ai/models/diarization/*campplus*.onnx
./target/release/diarize-helper --probe --segmentation "$SEG" --embedding "$EMB"
# diarize a 16kHz mono wav (auto count):
echo '{"type":"diarize","wav_path":"/abs/test-16k.wav","num_speakers":null}' \
  | ./target/release/diarize-helper --segmentation "$SEG" --embedding "$EMB"
```
(To make a 16k mono wav from a track: `ffmpeg -i system.m4a -ar 16000 -ac 1 -c:a pcm_s16le /tmp/s.wav`.)

---

## 5. Data model (SQLite: `~/Library/Application Support/com.meetily.ai/meeting_minutes.sqlite`)

```sql
speakers(
  id, person_id (→persons, NULL until assigned), label,
  centroid BLOB (f32[dim], little-endian), embedding_model, dim, samples,
  enrollment_state,       -- 'provisional' | 'confirmed' | 'owner'
  total_speech_secs REAL, -- P1: accumulated speech seconds folded in (fold weight, capped 600s), migration 20260714180000
  created_at, updated_at)

speaker_segments(
  id, meeting_id (→meetings), speaker_id (→speakers), cluster_key ('spk_0'…),
  start_time, end_time, source ('microphone'|'system'), embedding BLOB, created_at)

transcripts.speaker_id   -- added column; the resolved speaker per line (NULL until stamped)
```
- **Enrolled voiceprints** = `speakers` with `person_id IS NOT NULL` (these are the match candidates for future meetings).
- Migrations: `frontend/src-tauri/migrations/20260714140000_add_speaker_diarization.sql` (base) + `20260714180000_add_speaker_total_speech.sql` (P1 `total_speech_secs`).

---

## 6. Commands (Tauri, camelCase args)

| Command | Does |
|---------|------|
| `diarize_meeting(meetingId)` | The whole offline pass. Returns `{clustersFound, autoAssigned, provisionalCreated, ownerEnrolled, transcriptsStamped}`. |
| `speaker_list_for_meeting(meetingId)` | Speakers in a meeting `[{speakerId, personId, personName, label, enrollmentState, segmentCount}]`. |
| `speaker_assign_to_person(speakerId, personId)` | Confirm-before-enroll assignment. P1: merges to the person's canonical voiceprint + retro-relabels history. Returns `{speakerId (canonical), retroRelabeled}`. |
| `speaker_match_suggestions(speakerId)` | Ranked `[{personId, personName, score, tier}]`. |
| `meeting_speaker_labels(meetingId)` | `[{transcriptId, speakerName}]` for summary/chips. |

---

## 7. Rebuild after any change

```bash
cd frontend && pnpm run app:local      # builds+stages sidecar, builds signed .app, relaunches
```
- Frontend-only tweaks can use `pnpm run tauri:dev` (HMR) BUT the sidecar won't resolve well there — for real diarization always use `app:local`.
- After editing `diarize-helper/`: delete `frontend/src-tauri/binaries/diarize-helper-aarch64-apple-darwin` first so `run-local.sh` re-stages it (or rebuild+copy manually).
- Reset a stuck permission: `tccutil reset Microphone com.meetily.ai` (or `ScreenCapture`).

---

## 8. Debugging playbook

### Logs
- File: `~/Library/Logs/com.meetily.ai/ari.log` (rolling, 5-day). All diarization logs use the `🎙️ diarize:` prefix.
```bash
grep "🎙️ diarize" ~/Library/Logs/com.meetily.ai/ari.log | tail -50
```
Look for: which tracks were found (mic/system/fallback), the `calendar prior` line (num_speakers chosen), owner enrollment result, and any transcode/sidecar errors.

### Inspect DB state for a meeting
```bash
DB=~/Library/Application\ Support/com.meetily.ai/meeting_minutes.sqlite
MID='meeting-XXXX'
# speakers in the meeting + how they were resolved:
sqlite3 -header -column "$DB" "
SELECT s.enrollment_state, p.display_name AS person, s.samples,
       (SELECT COUNT(*) FROM speaker_segments ss WHERE ss.speaker_id=s.id) AS segs
FROM speakers s LEFT JOIN persons p ON p.id=s.person_id
WHERE s.id IN (SELECT DISTINCT speaker_id FROM speaker_segments WHERE meeting_id='$MID');"
# enrolled voiceprints (the cross-meeting match pool):
sqlite3 -header -column "$DB" "SELECT id, person_id, embedding_model, samples, enrollment_state FROM speakers WHERE person_id IS NOT NULL;"
```

### Re-run diarization on a meeting (✅ idempotent — see §9 item 2)
Just re-run it. `diarize_meeting` clears the meeting's prior diarization at the start of every run (un-stamps transcripts, deletes its `speaker_segments`, reaps orphaned provisional speakers), so re-runs no longer duplicate segments. **No manual SQL cleanup is needed.** Reopen the meeting and hit "Identify speakers" (only shows when 0 speakers), or call the command from devtools:
```js
await window.__TAURI_INTERNALS__.invoke('diarize_meeting', { meetingId: 'meeting-XXXX' })
```
(Confirmed/owner voiceprints keep their folded centroids — those can't be un-folded — so re-running re-folds the owner sample. The manual reset below is only needed to also scrub confirmed/owner rows.)

### Un-assign everything you tagged in a meeting (redo tagging)
```sql
UPDATE speakers SET person_id=NULL, enrollment_state='provisional'
WHERE enrollment_state='confirmed'
  AND id IN (SELECT DISTINCT speaker_id FROM speaker_segments WHERE meeting_id='$MID');
```

---

## 9. Known issues & limitations (Phase H backlog)

1. **Cluster count / over-splitting** — ✅ largely RESOLVED by the P0 post-process (§0): auto @ clusterThreshold 0.9 + app-side greedy centroid post-merge (≥0.7) + speech-time floor (dissolve/reassign/drop) yields correct counts on real recordings (2 on a 1:1, 5 on a 43-min meeting). All knobs are RUNTIME-tunable (§0); no longer forces the calendar count by default. Sidecar `min_duration_on/off` remain hardcoded (edit + rebuild).
2. **Not idempotent** — ✅ RESOLVED. `diarize_meeting` now clears the meeting's prior diarization at the start of every run (`SpeakerRepository::clear_meeting_diarization`): un-stamps transcripts, deletes the meeting's `speaker_segments`, and reaps now-orphaned provisional speakers (`person_id IS NULL`, `enrollment_state='provisional'`, no remaining segments). Owner/confirmed voiceprints are preserved (folded centroids can't be un-folded, so re-runs still re-fold the owner sample). Re-runs and the tuning loop are safe — no manual SQL cleanup needed.
3. **Thresholds are unmeasured guesses** (§3B) — tune on your real recordings.
4. **Multiple voiceprints per person** — ✅ RESOLVED (P1). `speaker_assign_to_person` now **merges to a canonical row**: if the person already has an enrolled voiceprint in the same embedding space, the assigned cluster's centroid is duration-weighted folded into it, its `speaker_segments`/`transcripts` stamps are repointed to the canonical, and the empty provisional row is deleted (one transaction, `SpeakerRepository::repoint_and_delete_speaker`). The assign response returns the canonical `speakerId`. So a person owns exactly one voiceprint per model and every future meeting strengthens that one signal. Owner enrollment for imports (no mic track) is covered because the owner voiceprint is `person_id`-linked and thus already in the match-candidate pool.
5. **Mixed remote stream ceiling** — all remote participants arrive as ONE mixed mono stream (system.m4a). Overlapping remote speech can't be separated; the diarizer clusters by voice embedding, which is imperfect on cross-talk. Owner (mic) is always clean.
6. **Owner enrollment needs `mic.m4a`** — imported/old meetings without a separate mic track skip owner enrollment and diarize the mixed `audio.mp4` fallback. P1 mitigates identification: the owner's enrolled voiceprint (`person_id`-linked) is in the match-candidate pool, so the owner's cluster in the mixed stream gets identified like anyone else (no mic track needed). `labeling.rs` also falls back to the owner's display name / "You" for an owner-state row whose person link doesn't resolve. Owner *bleed* still hurts clustering on the mixed stream (unchanged). Owner enrollment itself, when a mic track IS present, is now **speech-gated** (single-speaker diarize over the mic wav → centroid over just the speech, actual speech segments recorded) rather than a whole-file embed.
7. **Auto-trigger timing** — fires after save; if the mic/system tracks aren't fully finalized yet, diarize degrades (manual button is the fallback).
8. **Retroactive relabel** — ✅ RESOLVED (P1). After an assign establishes/strengthens a canonical voiceprint, `retroactive_relabel` scans OTHER meetings' provisional speakers (same embedding space, bounded at 200) and auto-merges any that match the canonical at the **AutoConfirm** tier into it (same transactional fold+repoint+delete flow as merge-to-canonical), logging `🎙️ diarize: retro-relabel …`. Between the suggest and auto thresholds the provisional is left as-is (the suggestions UI still surfaces it). Guards: excludes provisionals co-present in any of the canonical's meetings, and never claims two provisionals from the same meeting (avoids merging distinct co-present voices). The merged count is returned in the assign response (`retroRelabeled`). **Note:** retro-relabel runs on explicit *assign* only, NOT on auto-confirm during `diarize_meeting` — deferred deliberately to avoid merging in-progress same-meeting clusters mid-pass.

---

## 10. Quick reference — files to open first when debugging

- Bad speaker count → `commands.rs:~221` (prior) + `diarize-helper/src/main.rs:~280` (clustering).
- Wrong/again-anonymous identities → `matching.rs` `MatchConfig::default`.
- Chips missing → check `transcripts.speaker_id` is populated (stamping) and the `MeetingTranscript` DTO carries it (`api/api.rs` + `meeting.rs`).
- Sidecar not running → `ari.log` for "diarize-helper …", test with `--probe` (§4), check the staged binary exists.
- Models missing → `~/Library/Application Support/com.meetily.ai/models/diarization/`.
