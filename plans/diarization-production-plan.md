# Diarization → Production: Findings & Plan

**Date:** 2026-07-15. Synthesis of a three-track deep dive: code audit, SOTA research, and empirical threshold sweeps on real recordings. Companion to `plans/diarization-build-reference.md`.

## Verdict

**Keep the sherpa-onnx stack.** The failures are configuration + missing pipeline hygiene + one critical file-handling bug — not model or architecture flaws. Empirical proof: the CAM++ embeddings on the real 1:1 recording separate the two voices near-perfectly (within-speaker centroid cosine up to **0.958**, cross-speaker ~**0.25**); it's sherpa's fast-clustering that fragments them. FluidAudio (Swift/CoreML, pyannote community-1, ~10.6% DER on AMI-SDM) is the strategic Phase-2 upgrade, piloted behind the same sidecar protocol.

## Empirical results (real recordings, mixed mono audio)

**File 1 — 1:1, ground truth 2 speakers (595s):**

| threshold (auto) | clusters | clusters holding 90% of speech |
|---|---|---|
| 0.5 (old default) | **44** ← bug repro | 10 |
| 0.7 | 22 | 4 |
| 0.9 | 11 | **2** |
| 0.95 | 7 | **2** |

Forced `num_speakers=2`: clean 73/27 split, centroid cosine 0.254.

**File 2 — 43-min team meeting:**

| threshold | clusters | clusters holding 90% of speech |
|---|---|---|
| 0.5 | **138** ← bug repro | 40 |
| 0.9 | 24 | **6** |
| 0.95 | 16 | 5 (post-merge over-merges here) |

**Validated recipe:** sidecar auto threshold **0.9** + app-side **centroid post-merge at cosine ≥0.7** (greedy, duration-weighted) + **drop/reassign clusters below ~2% of total speech**. Yields 2 speakers on the 1:1 and 5 dominant on the team meeting. Perf: ~29s per 10 min audio — fine offline.

Key insight: sherpa's threshold is a cosine-**distance** dendrogram cut (higher = fewer speakers, doc was right), but no single threshold converges alone — the post-merge + floor does the real work, using the per-cluster centroids the sidecar already returns.

## Root causes (three observed failures)

1. **1:1 → 44 / meeting → 138 speakers:** old hardcoded threshold 0.5 far too strict for real meeting audio; no minimum-cluster-duration floor, so noise blips became "speakers".
2. **Distinct people merged at 8:** calendar prior forced `cutree_k(8)` — invitee count ≠ speaker count, and on the mixed stream the owner is present so `attendees−1` is doubly wrong. Forced-K is fine only when the count is truly known (validated on the 1:1).
3. **CRITICAL BUG — `mic.m4a`/`system.m4a` never written:** all three savers share one `.checkpoints/` dir; the mixed saver finalizes FIRST and its `finalize()` does `remove_dir_all` on the shared dir (`incremental_saver.rs:170`), destroying the mic/system chunks before their merges run. Errors swallowed as warnings. Split-track recording has never worked. (`concat_list.txt` is also a shared-name race.)
4. **Latent stamping bug** (activates once #3 is fixed): owner enrollment inserts one whole-meeting segment; max-overlap stamping means the owner would win nearly every transcript line.
5. **Owner voiceprint quality** (latent): `embed` runs over the whole mic file with no VAD — silence/noise diluted in.

Cleared: threshold plumbing (runtime value reaches sidecar), matcher math (fold/greedy correct), 192-vs-512 dim (docs stale; logic dim-safe — model is 192-dim `campplus_sv_zh_en`).

## Design constraint (user-confirmed)

**Mixed single-stream audio is a first-class input** — imports/pre-recorded meetings (common for large meetings) never have split tracks. Clustering must be production-quality on mixed mono alone; split tracks are an enhancement (clean owner voiceprint), not a dependency. Owner identification for imports should come from voiceprint matching, not the mic track.

## Phased plan

### P0 — make speaker counts sane (implement now)
1. **Fix the checkpoint-dir bug**: per-stem cleanup in `IncrementalAudioSaver::finalize()` (delete only own `{stem}_chunk_*` + per-stem concat list), never `remove_dir_all` on the shared dir.
2. **Clustering post-process in Rust** (new pure module, unit-tested):
   - default `clusterThreshold` 0.7 → **0.9** (tuning.rs + sidecar fallback aligned);
   - greedy duration-weighted **centroid post-merge at cosine ≥0.7**;
   - **speech-time floor**: clusters < max(10s, 2% of speech) are dissolved; their segments reassigned to nearest surviving centroid if cosine ≥0.5, else left unlabeled.
3. **Idempotency guard**: `diarize_meeting` clears the meeting's prior segments/stamps/provisional speakers before re-running (makes the tuning loop and re-runs safe).
4. **Stamping fix**: prefer system-source segments; whole-span owner (microphone-source) segment only as fallback for lines with no system overlap.
5. Update `diarization-build-reference.md` (192-dim, new defaults, post-merge knobs).

### P1 — identity quality
- VAD-gate the owner embed (or average several speech windows).
- Calendar count as **upper bound/prior**, never forced K (keep explicit `speakerCount: N` for known cases).
- Threshold calibration harness: same/different-speaker centroid pairs from own recordings → plot distributions → set matcher thresholds empirically (current 0.70/0.55/0.08 are uncalibrated guesses; research suggests ~0.62/0.45/0.10 for CAM++ centroids).
- Owner-via-voiceprint for imported meetings (match owner centroid against clusters; no mic track needed).
- Voiceprint merge-to-canonical per person + retroactive relabel on assign.

### P2 — strategic
- **Pilot FluidAudio** (Swift/CoreML, pyannote community-1 segmentation, ANE-native) as an alternative sidecar behind the same NDJSON protocol; head-to-head DER eval vs tuned sherpa before switching. Re-enrollment required (different embedding space).
- Optional: swap CAM++ zh_en → 3D-Speaker ERes2NetV2 (drop-in 192-dim, better short utterances) — **deferred**: empirics show embeddings are not the bottleneck.
- Track pyannote community-1 ONNX availability for in-place sherpa upgrade.

## Reproduce the experiments
Scratchpad scripts (`diarize_client.py`, `run_sweep.py`, `centroid_analysis.py`, `postmerge.py`) drive the sidecar directly: transcode with `ffmpeg -ar 16000 -ac 1 -c:a pcm_s16le`, send `{"type":"diarize","wav_path":…,"num_speakers":null,"threshold":X}` NDJSON to `diarize-helper --segmentation … --embedding …`.
