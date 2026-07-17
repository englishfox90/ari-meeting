//! # Diarization orchestration + Tauri command surface (F1)
//!
//! This is the **app layer** that ties together the pure matcher
//! ([`crate::diarization::matching`]) and the sidecar/model plumbing
//! ([`crate::diarization::engine`]) and owns **all** DB writes (via
//! `database/repositories/`, per the repositories-only rule).
//!
//! It runs entirely **offline / off the hot path**: [`diarize_meeting`] is invoked
//! on a *finished* meeting (on-demand from the UI, and — see the auto-trigger note
//! at the bottom of this file — intended to be fired by the frontend right after a
//! recording is saved). Nothing here touches the live recording pipeline.
//!
//! ## What one `diarize_meeting` run does
//!
//! 1. Resolve the meeting's audio folder (`mic.m4a` / `system.m4a`, older meetings
//!    fall back to `audio.mp4`).
//! 2. **Owner enrollment (free win):** embed the clean `mic.m4a` track and fold it
//!    into the owner's persistent voiceprint. The mic track is single-speaker by
//!    construction (it's the local user), so no diarization is needed there.
//! 3. **Remote diarization:** diarize the mixed `system.m4a` stream into per-meeting
//!    voice clusters, match each cluster against stored enrolled voiceprints with the
//!    **pure** matcher, and persist attributions. Only *AutoConfirm* matches are
//!    auto-assigned (confirm-before-enroll); everything else stays provisional for
//!    the user to confirm later.
//! 4. **Stamp** each transcript row with the speaker whose segment it most overlaps.
//!
//! All numbers in the returned [`DiarizeMeetingSummary`] are honest counts of what
//! actually happened — no invented metrics.

use std::path::{Path, PathBuf};

use serde::Serialize;
use tauri::AppHandle;

use crate::database::repositories::meeting::MeetingsRepository;
use crate::database::repositories::person::PersonRepository;
use crate::database::repositories::speaker::SpeakerRepository;
use crate::diarization::tuning::{self, SpeakerCountMode};
use crate::diarization::{engine, labeling, matching, postprocess};
use crate::engine::Engine;

/// One resolved per-line speaker label: which transcript row maps to which speaker
/// name. Rows whose speaker is unknown are simply absent from the list (no fabricated
/// names). The frontend maps `transcriptId → speakerName` to prefix summary lines.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptSpeakerLabel {
    pub transcript_id: String,
    pub speaker_name: String,
}

/// Read command (G1): resolve per-transcript speaker names for a finished meeting.
/// Wraps [`labeling::resolve_meeting_speaker_labels`]. Honest — returns entries only
/// for transcript rows whose `speaker_id` resolves to a real name; unlabeled rows are
/// omitted. Names are resolved once per meeting (no per-line DB fan-out).
pub async fn meeting_speaker_labels_impl(
    engine: &Engine,
    meeting_id: String,
) -> Result<Vec<TranscriptSpeakerLabel>, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let pairs = labeling::resolve_meeting_speaker_labels(pool, &meeting_id)
        .await
        .map_err(|e| format!("failed to resolve speaker labels for meeting {meeting_id}: {e}"))?;
    Ok(pairs
        .into_iter()
        .map(|(transcript_id, speaker_name)| TranscriptSpeakerLabel {
            transcript_id,
            speaker_name,
        })
        .collect())
}

#[tauri::command]
pub async fn meeting_speaker_labels(
    meeting_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<TranscriptSpeakerLabel>, String> {
    meeting_speaker_labels_impl(&engine, meeting_id).await
}

/// Honest summary of a single [`diarize_meeting`] run. Every field is a real count
/// of what the run did; nothing is fabricated.
#[derive(Debug, Clone, Serialize)]
pub struct DiarizeMeetingSummary {
    /// Distinct voice clusters the diarizer found in the system/remote stream.
    pub clusters_found: usize,
    /// Clusters auto-assigned to an already-enrolled speaker (AutoConfirm tier).
    pub auto_assigned: usize,
    /// Clusters that became new provisional speakers awaiting user confirmation.
    pub provisional_created: usize,
    /// Whether the owner's voiceprint was enrolled/updated from the mic track.
    pub owner_enrolled: bool,
    /// Transcript rows stamped with a resolved `speaker_id`.
    pub transcripts_stamped: usize,
}

/// One row of [`speaker_list_for_meeting`] — a speaker that appears in the meeting,
/// with its enrollment status and how many segments it owns there.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingSpeakerRow {
    pub speaker_id: String,
    pub person_id: Option<String>,
    /// Display name of the linked person (resolved from `person_id`), if any.
    pub person_name: Option<String>,
    pub label: Option<String>,
    pub enrollment_state: String,
    pub segment_count: usize,
}

/// Diarize a finished meeting: enroll the owner from the clean mic track, cluster +
/// match the remote/system stream against stored voiceprints, persist speaker
/// attributions, and stamp transcript rows. **Idempotent**: each run first clears
/// the meeting's prior diarization (un-stamps transcripts, deletes its
/// speaker_segments, reaps orphaned provisional speakers) so re-runs and the tuning
/// loop are safe. Owner/confirmed voiceprints are preserved (their folded centroids
/// can't be un-folded), so re-running still re-folds the owner sample.
///
/// Off the hot path; safe to spawn fire-and-forget. Returns an honest summary.
pub async fn diarize_meeting_impl(
    engine: &Engine,
    meeting_id: String,
    app: AppHandle,
) -> Result<DiarizeMeetingSummary, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    // 1. Resolve the meeting folder.
    let meeting = MeetingsRepository::get_meeting_metadata(pool, &meeting_id)
        .await
        .map_err(|e| format!("failed to load meeting {meeting_id}: {e}"))?
        .ok_or_else(|| format!("meeting {meeting_id} not found"))?;
    let folder = meeting
        .folder_path
        .as_deref()
        .map(PathBuf::from)
        .filter(|p| p.exists())
        .ok_or_else(|| format!("meeting {meeting_id} has no audio folder on disk"))?;

    // 2. Ensure the diarization models exist (downloads on first use).
    let (seg_model, emb_model) = engine::ensure_models(engine)
        .await
        .map_err(|e| format!("failed to provision diarization models: {e}"))?;
    let emb_model_str = model_id_from_path(&emb_model);

    // 3. Resolve tracks + a scratch dir for transcoded WAVs.
    let mic_path = folder.join("mic.m4a");
    let system_path = folder.join("system.m4a");
    let fallback_path = folder.join("audio.mp4");

    let scratch = app
        .path_temp_dir()
        .join(format!("ari-diarize-{}-{}", short_id(&meeting_id), std::process::id()));
    if let Err(e) = tokio::fs::create_dir_all(&scratch).await {
        return Err(format!("failed to create scratch dir {}: {e}", scratch.display()));
    }
    // Everything below is best-effort; make sure we always clean up the scratch dir.
    let result = run_diarization(
        pool,
        engine,
        &app,
        &meeting_id,
        &mic_path,
        &system_path,
        &fallback_path,
        &scratch,
        &seg_model,
        &emb_model,
        &emb_model_str,
    )
    .await;

    let _ = tokio::fs::remove_dir_all(&scratch).await;

    result
}

#[tauri::command]
pub async fn diarize_meeting(
    meeting_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    app: AppHandle,
) -> Result<DiarizeMeetingSummary, String> {
    diarize_meeting_impl(&engine, meeting_id, app).await
}

/// Inner body so the scratch dir is always cleaned up regardless of outcome.
#[allow(clippy::too_many_arguments)]
async fn run_diarization(
    pool: &sqlx::SqlitePool,
    engine: &Engine,
    app: &AppHandle,
    meeting_id: &str,
    mic_path: &Path,
    system_path: &Path,
    fallback_path: &Path,
    scratch: &Path,
    seg_model: &Path,
    emb_model: &Path,
    emb_model_str: &str,
) -> Result<DiarizeMeetingSummary, String> {
    let cfg = matching::MatchConfig::default();
    let mut owner_enrolled = false;
    let mut clusters_found = 0usize;
    let mut auto_assigned = 0usize;
    let mut provisional_created = 0usize;

    // ---- 3b. Idempotency guard: clear this meeting's prior diarization ----
    // Un-stamp transcripts, drop old speaker_segments, and reap now-orphaned
    // provisional speakers, so a re-run (or the tuning loop) starts clean instead
    // of double-folding centroids and appending duplicate segments. Owner/confirmed
    // voiceprints are preserved. Best-effort: a failure here is logged, not fatal.
    match SpeakerRepository::clear_meeting_diarization(pool, meeting_id).await {
        Ok((t, s, o)) => log::info!(
            "🎙️ diarize: cleared prior diarization for {meeting_id} (transcripts={t}, segments={s}, orphan_speakers={o})"
        ),
        Err(e) => log::warn!("🎙️ diarize: failed to clear prior diarization (continuing): {e}"),
    }

    // ---- 4. Mic track: owner enrollment + in-room speakers (only if mic exists) ----
    // The mic is auto-diarized for multiple speakers now (in-person meetings put everyone
    // on it); the owner cluster folds into the owner voiceprint, other clusters become
    // in-room speakers. Counts accumulate with the system-stream counts below.
    if mic_path.exists() {
        match process_mic_track(pool, engine, app, meeting_id, mic_path, scratch, seg_model, emb_model, emb_model_str).await
        {
            Ok((enrolled, mic_auto, mic_prov, mic_clusters)) => {
                owner_enrolled = enrolled;
                auto_assigned += mic_auto;
                provisional_created += mic_prov;
                clusters_found += mic_clusters;
                if !enrolled {
                    log::info!("🎙️ diarize: no owner person set — skipping owner enrollment");
                }
            }
            Err(e) => log::warn!("🎙️ diarize: mic processing failed (continuing): {e}"),
        }
    } else {
        log::info!("🎙️ diarize: no mic.m4a — skipping mic processing");
    }

    // ---- 5. Remote diarization (system track, or older audio.mp4 fallback) ----
    let remote_src: Option<&Path> = if system_path.exists() {
        Some(system_path)
    } else if fallback_path.exists() {
        Some(fallback_path)
    } else {
        None
    };

    if let Some(src) = remote_src {
        let wav = scratch.join("system.wav");
        engine::transcode_to_16k_mono_wav(src, &wav)
            .await
            .map_err(|e| format!("failed to transcode {} for diarization: {e}", src.display()))?;
        let wav_str = wav.to_string_lossy().to_string();

        // Runtime tuning (editable JSON, no recompile): decides how the speaker
        // count is chosen and — in auto mode — the clustering threshold + the
        // app-side post-merge/floor knobs. DEFAULT (no config file) is Auto +
        // threshold 0.9: the calendar prior is NO LONGER forced by default (it
        // over-forced small meetings), and auto clustering merges much harder than
        // the sidecar's legacy 0.5 (which over-split — a 1:1 reported 44 speakers).
        // The heavy lifting is the post-process stage (§5b) that follows. Higher
        // threshold = FEWER clusters.
        let tuning = tuning::load(engine).await;
        // `max_clusters` = an app-side UPPER BOUND on surviving clusters applied in
        // postprocess (P1). Only Calendar mode sets it; auto/fixed leave it None.
        let (num_speakers, threshold, max_clusters): (Option<i64>, Option<f32>, Option<usize>) = match tuning.speaker_count {
            SpeakerCountMode::Auto => {
                log::info!(
                    "🎙️ diarize: speakerCount=auto — ignoring calendar prior; auto clustering @ threshold={}",
                    tuning.cluster_threshold
                );
                (None, Some(tuning.cluster_threshold), None)
            }
            SpeakerCountMode::Calendar => {
                // Calendar as a CAP, not a forced K (P1): we no longer pin the sidecar
                // to a cluster count. Auto-cluster + post-merge as usual, then cap the
                // surviving clusters at the attendee count in postprocess. The cap is
                // the FULL attendee count (NOT attendees−1): on the mixed stream the
                // owner is present in the audio too. Best-effort: only cap with ≥2
                // known participants; otherwise plain auto.
                match PersonRepository::count_participants(pool, meeting_id).await {
                    Ok(n) if n >= 2 => {
                        let cap = (n as usize).clamp(1, 12);
                        log::info!(
                            "🎙️ diarize: speakerCount=calendar — {n} participants → max_clusters cap={cap} (auto cluster @ threshold={})",
                            tuning.cluster_threshold
                        );
                        (None, Some(tuning.cluster_threshold), Some(cap))
                    }
                    Ok(n) => {
                        log::info!("🎙️ diarize: speakerCount=calendar but only {n} known participant(s) — auto @ threshold={}", tuning.cluster_threshold);
                        (None, Some(tuning.cluster_threshold), None)
                    }
                    Err(e) => {
                        log::warn!("🎙️ diarize: speakerCount=calendar but count failed ({e}) — auto @ threshold={}", tuning.cluster_threshold);
                        (None, Some(tuning.cluster_threshold), None)
                    }
                }
            }
            SpeakerCountMode::Fixed(n) => {
                log::info!("🎙️ diarize: speakerCount={n} (fixed) — forcing exact cluster count");
                (Some(n), None, None)
            }
        };

        let diar = engine::diarize(app, &wav_str, num_speakers, threshold, &seg_model.to_string_lossy(), &emb_model.to_string_lossy())
            .await
            .map_err(|e| format!("diarization failed: {e}"))?;

        // ---- 5b. Post-process the raw clusters (pure) ----
        // sherpa's fast-clustering over-fragments real meeting audio; the app-side
        // greedy centroid post-merge + speech-time floor collapses it to sane
        // counts (empirically validated). The post-merge only runs in AUTO mode
        // (num_speakers=None); forced-K mode (Fixed/Calendar) already pins a count,
        // so we skip the merge but still apply the floor. Runs BEFORE matching,
        // enrollment, and segment insertion.
        let apply_merge = num_speakers.is_none();
        let mut pp_cfg = tuning.postprocess_config();
        pp_cfg.max_clusters = max_clusters;
        let raw_clusters = diar.clusters.len();
        let pp_in_segments: Vec<postprocess::Seg> = diar
            .segments
            .iter()
            .map(|s| postprocess::Seg { start: s.start, end: s.end, speaker: s.speaker.clone() })
            .collect();
        let pp_in_clusters: Vec<postprocess::ClusterIn> = diar
            .clusters
            .iter()
            .map(|c| postprocess::ClusterIn { speaker: c.speaker.clone(), centroid: c.centroid.clone() })
            .collect();
        let pp = postprocess::postprocess(&pp_in_segments, &pp_in_clusters, &pp_cfg, apply_merge);
        log::info!(
            "🎙️ diarize: postprocess {} → {} clusters (merge={}, threshold={}, floor=max({}s, {}×speech), cap={:?})",
            raw_clusters,
            pp.clusters.len(),
            apply_merge,
            pp_cfg.merge_threshold,
            pp_cfg.floor_abs_secs,
            pp_cfg.floor_frac,
            pp_cfg.max_clusters,
        );
        let diar = engine::DiarizeResult {
            segments: pp
                .segments
                .iter()
                .map(|s| engine::DiarSegment { start: s.start, end: s.end, speaker: s.speaker.clone() })
                .collect(),
            clusters: pp
                .clusters
                .iter()
                .map(|c| engine::DiarCluster { speaker: c.speaker.clone(), dim: c.dim, centroid: c.centroid.clone() })
                .collect(),
        };

        clusters_found += diar.clusters.len();
        if diar.segments.is_empty() || diar.clusters.is_empty() {
            log::info!("🎙️ diarize: system stream produced no clusters/segments");
        } else {
            let (auto, prov) =
                persist_clusters(pool, meeting_id, &diar, &cfg, emb_model_str, "system", None).await?;
            auto_assigned += auto;
            provisional_created += prov;
        }
    } else {
        log::info!("🎙️ diarize: no system.m4a / audio.mp4 — skipping remote diarization");
    }

    // ---- 6. Stamp transcripts by greatest segment overlap ----
    let transcripts_stamped = stamp_transcripts(pool, meeting_id).await?;

    Ok(DiarizeMeetingSummary {
        clusters_found,
        auto_assigned,
        provisional_created,
        owner_enrolled,
        transcripts_stamped,
    })
}

/// Process the owner's mic track: diarize it for **multiple** speakers, identify which
/// cluster(s) are the owner by matching the prior owner voiceprint, fold ONLY the owner
/// cluster into that voiceprint, and persist any other in-room speakers found on the mic
/// as their own speakers. Returns
/// `(owner_enrolled, mic_auto_assigned, mic_provisional_created, mic_clusters_found)`.
///
/// **Why not force one speaker?** The mic is the owner's device but is NOT single-speaker
/// when people share a room (in-person meetings put everyone on the mic). Forcing
/// `num_speakers = Some(1)` folded a second person's voice into the owner voiceprint and
/// attributed everyone to the owner. We now auto-cluster the mic (same pipeline as the
/// system stream) and split owner vs. in-room by voiceprint match:
/// - **Every** mic cluster matching the prior owner centroid at `>= auto_threshold` is the
///   owner (so a remote call's over-split owner just re-merges into the owner — no phantom
///   speakers), folded into the owner voiceprint.
/// - **Bootstrap** (no prior owner voiceprint, or nothing matches): the dominant (most-
///   speech) cluster is taken as the owner — the near-field assumption on the owner's own
///   mic.
/// - Other clusters become in-room speakers via [`persist_clusters`] (`source = microphone`,
///   owner excluded from the candidate pool).
///
/// Falls back to a whole-file owner embed if diarization yields nothing.
#[allow(clippy::too_many_arguments)]
async fn process_mic_track(
    pool: &sqlx::SqlitePool,
    engine: &Engine,
    app: &AppHandle,
    meeting_id: &str,
    mic_path: &Path,
    scratch: &Path,
    seg_model: &Path,
    emb_model: &Path,
    emb_model_str: &str,
) -> Result<(bool, usize, usize, usize), String> {
    let owner = match PersonRepository::get_owner(pool)
        .await
        .map_err(|e| format!("failed to load owner: {e}"))?
    {
        Some(o) => o,
        None => return Ok((false, 0, 0, 0)),
    };

    let wav = scratch.join("mic.wav");
    engine::transcode_to_16k_mono_wav(mic_path, &wav)
        .await
        .map_err(|e| format!("failed to transcode mic track: {e}"))?;
    let wav_str = wav.to_string_lossy().to_string();

    let cfg = matching::MatchConfig::default();

    // ---- Auto-diarize the mic (multi-speaker) + postprocess, mirroring the system
    // stream. Forcing one speaker is exactly what mis-attributed in-person meetings. ----
    let tuning = tuning::load(engine).await;
    let diar_res = engine::diarize(
        app,
        &wav_str,
        None,
        Some(tuning.cluster_threshold),
        &seg_model.to_string_lossy(),
        &emb_model.to_string_lossy(),
    )
    .await;

    let diar: engine::DiarizeResult = match diar_res {
        Ok(d) if !d.clusters.is_empty() => {
            let pp_cfg = tuning.postprocess_config();
            let pp_in_segments: Vec<postprocess::Seg> = d
                .segments
                .iter()
                .map(|s| postprocess::Seg { start: s.start, end: s.end, speaker: s.speaker.clone() })
                .collect();
            let pp_in_clusters: Vec<postprocess::ClusterIn> = d
                .clusters
                .iter()
                .map(|c| postprocess::ClusterIn { speaker: c.speaker.clone(), centroid: c.centroid.clone() })
                .collect();
            let pp = postprocess::postprocess(&pp_in_segments, &pp_in_clusters, &pp_cfg, true);
            log::info!(
                "🎙️ diarize: mic postprocess {} → {} clusters",
                d.clusters.len(),
                pp.clusters.len()
            );
            engine::DiarizeResult {
                segments: pp
                    .segments
                    .iter()
                    .map(|s| engine::DiarSegment { start: s.start, end: s.end, speaker: s.speaker.clone() })
                    .collect(),
                clusters: pp
                    .clusters
                    .iter()
                    .map(|c| engine::DiarCluster { speaker: c.speaker.clone(), dim: c.dim, centroid: c.centroid.clone() })
                    .collect(),
            }
        }
        other => {
            match &other {
                Err(e) => log::warn!("🎙️ diarize: mic diarize failed ({e}) — whole-file owner embed"),
                Ok(_) => log::info!("🎙️ diarize: mic diarize produced no clusters — whole-file owner embed"),
            }
            // Legacy safety fallback: embed the whole mic as one owner cluster/span.
            let centroid = engine::embed(app, &wav_str, &emb_model.to_string_lossy())
                .await
                .map_err(|e| format!("failed to embed mic track: {e}"))?;
            if centroid.is_empty() {
                return Err("mic embedding was empty".to_string());
            }
            let dur = wav_duration_secs(&wav);
            let dim = centroid.len() as i64;
            engine::DiarizeResult {
                segments: vec![engine::DiarSegment { start: 0.0, end: dur, speaker: "spk_owner".to_string() }],
                clusters: vec![engine::DiarCluster { speaker: "spk_owner".to_string(), dim, centroid }],
            }
        }
    };

    let mic_clusters_found = diar.clusters.len();

    // Per-cluster total speech seconds (immutable borrow of `diar`, used read-only).
    let speech_of = |key: &str| -> f64 {
        diar.segments
            .iter()
            .filter(|s| s.speaker == key)
            .map(|s| (s.end - s.start).max(0.0))
            .sum()
    };

    // ---- Decide which cluster(s) are the owner ----
    let prior_owner = SpeakerRepository::get_owner_speaker(pool, &owner.id)
        .await
        .map_err(|e| format!("failed to load owner speaker: {e}"))?;
    let prior_centroid: Vec<f32> = prior_owner
        .as_ref()
        .map(|s| engine::bytes_to_centroid(&s.centroid))
        .unwrap_or_default();

    let mut owner_keys: Vec<String> = Vec::new();
    if !prior_centroid.is_empty() {
        for c in &diar.clusters {
            if matching::cosine_similarity(&c.centroid, &prior_centroid) >= cfg.auto_threshold {
                owner_keys.push(c.speaker.clone());
            }
        }
    }
    let mut bootstrapped = false;
    if owner_keys.is_empty() {
        // Bootstrap: dominant cluster by speech is the owner (near-field on own mic).
        bootstrapped = true;
        if let Some(dom) = diar.clusters.iter().max_by(|a, b| {
            speech_of(&a.speaker)
                .partial_cmp(&speech_of(&b.speaker))
                .unwrap_or(std::cmp::Ordering::Equal)
        }) {
            log::info!(
                "🎙️ diarize: mic owner cluster chosen by dominance (no voiceprint match) — {}",
                dom.speaker
            );
            owner_keys.push(dom.speaker.clone());
        }
    } else {
        log::info!("🎙️ diarize: mic owner cluster(s) matched by voiceprint — {owner_keys:?}");
    }
    // When we had to bootstrap (no owner voiceprint to match) AND >1 mic cluster
    // survived, the extra clusters MIGHT be over-split fragments of the owner's own
    // voice rather than distinct in-room people — they'll surface as provisional
    // speakers. Once a clean owner voiceprint exists, later runs re-merge them by match.
    if bootstrapped && diar.clusters.len() > owner_keys.len() {
        log::warn!(
            "🎙️ diarize: mic bootstrap with {} clusters — {} non-owner mic cluster(s) may be owner over-split; verify or reset+re-identify once an owner voiceprint exists",
            diar.clusters.len(),
            diar.clusters.len() - owner_keys.len()
        );
    }

    if owner_keys.is_empty() {
        // No clusters at all — nothing to enroll.
        return Ok((false, 0, 0, mic_clusters_found));
    }

    // ---- Enroll/fold the owner from the owner cluster(s) ----
    let owner_speech_secs: f64 = owner_keys.iter().map(|k| speech_of(k)).sum();
    // Representative centroid = the owner cluster with the most speech (cleanest sample).
    let owner_centroid = diar
        .clusters
        .iter()
        .filter(|c| owner_keys.contains(&c.speaker))
        .max_by(|a, b| {
            speech_of(&a.speaker)
                .partial_cmp(&speech_of(&b.speaker))
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|c| c.centroid.clone())
        .unwrap_or_default();
    let centroid_bytes = engine::centroid_to_bytes(&owner_centroid);
    let dim = owner_centroid.len() as i64;

    let (owner_speaker_id, existed) = SpeakerRepository::upsert_owner_speaker(
        pool,
        &owner.id,
        &centroid_bytes,
        emb_model_str,
        dim,
        owner_speech_secs,
    )
    .await
    .map_err(|e| format!("failed to upsert owner speaker: {e}"))?;

    // If the owner voiceprint already existed, DURATION-WEIGHTED fold the owner cluster
    // into it — gated so short/noisy samples never drift it.
    if existed {
        if let Some(sp) = SpeakerRepository::get(pool, &owner_speaker_id)
            .await
            .map_err(|e| format!("failed to reload owner speaker: {e}"))?
        {
            let stored = engine::bytes_to_centroid(&sp.centroid);
            match matching::should_fold(owner_speech_secs, &owner_centroid, stored.len(), None, &cfg) {
                Ok(()) => {
                    let folded = matching::fold_centroid_weighted(
                        &stored,
                        sp.total_speech_secs,
                        &owner_centroid,
                        owner_speech_secs,
                    );
                    if let Err(e) = SpeakerRepository::fold_centroid(
                        pool,
                        &owner_speaker_id,
                        &engine::centroid_to_bytes(&folded),
                        sp.samples + 1,
                        sp.total_speech_secs + owner_speech_secs,
                    )
                    .await
                    {
                        log::warn!("🎙️ diarize: failed to fold owner centroid (continuing): {e}");
                    }
                }
                Err(reason) => log::info!(
                    "🎙️ diarize: owner fold skipped ({reason}) — keeping prior voiceprint (speech={owner_speech_secs:.1}s)"
                ),
            }
        }
    }

    // Record the owner's speech segments (source 'microphone'), embedding on the first.
    let mut owner_segs: Vec<&engine::DiarSegment> = diar
        .segments
        .iter()
        .filter(|s| owner_keys.contains(&s.speaker))
        .collect();
    owner_segs.sort_by(|a, b| a.start.partial_cmp(&b.start).unwrap_or(std::cmp::Ordering::Equal));
    for (i, seg) in owner_segs.iter().enumerate() {
        let emb = if i == 0 { Some(centroid_bytes.as_slice()) } else { None };
        if let Err(e) = SpeakerRepository::insert_segment(
            pool,
            meeting_id,
            &owner_speaker_id,
            "owner",
            "microphone",
            seg.start,
            seg.end,
            emb,
        )
        .await
        {
            log::warn!("🎙️ diarize: failed to record owner segment (continuing): {e}");
        }
    }

    // Link the owner as a participant of this meeting (idempotent).
    if let Err(e) = PersonRepository::link_participant(pool, meeting_id, &owner.id, "speaker").await {
        log::warn!("🎙️ diarize: failed to link owner participant (continuing): {e}");
    }

    // ---- Persist any NON-owner in-room speakers found on the mic ----
    let other_clusters: Vec<engine::DiarCluster> = diar
        .clusters
        .iter()
        .filter(|c| !owner_keys.contains(&c.speaker))
        .cloned()
        .collect();
    let (mic_auto, mic_prov) = if other_clusters.is_empty() {
        (0, 0)
    } else {
        let other_keys: std::collections::HashSet<String> =
            other_clusters.iter().map(|c| c.speaker.clone()).collect();
        let other_segments: Vec<engine::DiarSegment> = diar
            .segments
            .iter()
            .filter(|s| other_keys.contains(&s.speaker))
            .cloned()
            .collect();
        let diar_other = engine::DiarizeResult { segments: other_segments, clusters: other_clusters };
        log::info!(
            "🎙️ diarize: {} in-room (non-owner) mic cluster(s) to persist",
            diar_other.clusters.len()
        );
        persist_clusters(pool, meeting_id, &diar_other, &cfg, emb_model_str, "microphone", Some(&owner_speaker_id)).await?
    };

    Ok((true, mic_auto, mic_prov, mic_clusters_found))
}

/// Persist per-cluster attributions. Returns `(auto_assigned, provisional_created)`.
///
/// Matched + eligible (AutoConfirm) clusters REUSE the enrolled speaker: fold the
/// cluster centroid into it and write all its segments referencing that speaker.
/// Everything else becomes a fresh provisional speaker awaiting user confirmation.
///
/// `source` tags every persisted segment (`"system"` for the remote/loopback stream,
/// `"microphone"` for in-room speakers found on the owner's mic track). `exclude_speaker_id`
/// drops one enrolled voiceprint from the candidate pool — used by the mic path to keep
/// the owner (already claimed by [`process_mic_track`]) out of the in-room match.
#[allow(clippy::too_many_arguments)]
async fn persist_clusters(
    pool: &sqlx::SqlitePool,
    meeting_id: &str,
    diar: &engine::DiarizeResult,
    cfg: &matching::MatchConfig,
    emb_model_str: &str,
    source: &str,
    exclude_speaker_id: Option<&str>,
) -> Result<(usize, usize), String> {
    // Enrolled voiceprints to match against (optionally excluding the owner).
    let enrolled = SpeakerRepository::list_all_enrolled(pool)
        .await
        .map_err(|e| format!("failed to load enrolled speakers: {e}"))?;
    let candidates: Vec<matching::Candidate> = enrolled
        .iter()
        .filter(|s| exclude_speaker_id != Some(s.id.as_str()))
        .map(|s| matching::Candidate {
            id: s.id.clone(),
            name: s.label.clone().unwrap_or_else(|| s.id.clone()),
            centroid: engine::bytes_to_centroid(&s.centroid),
        })
        .collect();

    // Index-aligned clusters for the matcher.
    let clusters: Vec<(String, Vec<f32>)> = diar
        .clusters
        .iter()
        .map(|c| (c.speaker.clone(), c.centroid.clone()))
        .collect();
    let suggestions = matching::assign_meeting_clusters(&clusters, &candidates, cfg);

    let mut auto_assigned = 0usize;
    let mut provisional_created = 0usize;

    for (i, cluster) in diar.clusters.iter().enumerate() {
        // Segments belonging to this cluster label, in time order.
        let mut segs: Vec<&engine::DiarSegment> = diar
            .segments
            .iter()
            .filter(|s| s.speaker == cluster.speaker)
            .collect();
        segs.sort_by(|a, b| a.start.partial_cmp(&b.start).unwrap_or(std::cmp::Ordering::Equal));
        if segs.is_empty() {
            log::info!("🎙️ diarize: cluster {} has no segments — skipping", cluster.speaker);
            continue;
        }

        // Total speech this cluster holds — the duration-weight `w` for folding and
        // the `total_speech_secs` seed for a new provisional speaker.
        let cluster_secs: f64 = segs.iter().map(|s| (s.end - s.start).max(0.0)).sum();

        let centroid_bytes = engine::centroid_to_bytes(&cluster.centroid);
        // Gate auto-confirm by cluster duration: a short/noisy cluster that
        // scores >= auto_threshold by chance (esp. against the owner's own
        // voiceprint, which is matched against every meeting) is downgraded to
        // a provisional speaker awaiting manual confirmation rather than
        // silently auto-assigned.
        let suggestion = matching::gate_auto_confirm_by_duration(suggestions[i].clone(), cluster_secs);
        if !suggestion.eligible && suggestions[i].eligible {
            log::info!(
                "🎙️ diarize: downgraded auto-confirm for cluster {} (speech={cluster_secs:.1}s < {}s floor, would-be speaker={:?}) — needs manual confirmation",
                cluster.speaker,
                matching::MIN_AUTO_CONFIRM_SPEECH_SECS,
                suggestions[i].speaker_id
            );
        }

        if suggestion.eligible {
            // ---- Matched + AutoConfirm: reuse the enrolled speaker ----
            let matched_id = match &suggestion.speaker_id {
                Some(id) => id.clone(),
                None => {
                    log::warn!("🎙️ diarize: eligible suggestion without speaker_id — treating as provisional");
                    provisional_created +=
                        insert_provisional_cluster(pool, meeting_id, cluster, &segs, &centroid_bytes, emb_model_str, cluster_secs, source)
                            .await?;
                    continue;
                }
            };

            // DURATION-WEIGHTED, quality-gated fold of the cluster centroid into the
            // enrolled speaker (matcher owns the math). A short/ambiguous cluster is
            // NOT folded (the match still stands) so a good voiceprint never drifts.
            match SpeakerRepository::get(pool, &matched_id).await {
                Ok(Some(sp)) => {
                    let stored = engine::bytes_to_centroid(&sp.centroid);
                    match matching::should_fold(
                        cluster_secs,
                        &cluster.centroid,
                        stored.len(),
                        Some(suggestion.score),
                        cfg,
                    ) {
                        Ok(()) => {
                            let folded = matching::fold_centroid_weighted(
                                &stored,
                                sp.total_speech_secs,
                                &cluster.centroid,
                                cluster_secs,
                            );
                            if let Err(e) = SpeakerRepository::fold_centroid(
                                pool,
                                &matched_id,
                                &engine::centroid_to_bytes(&folded),
                                sp.samples + 1,
                                sp.total_speech_secs + cluster_secs,
                            )
                            .await
                            {
                                log::warn!("🎙️ diarize: failed to fold matched centroid (continuing): {e}");
                            }
                        }
                        Err(reason) => log::info!(
                            "🎙️ diarize: matched fold skipped for {matched_id} ({reason}, score={:.3}, speech={cluster_secs:.1}s) — match kept",
                            suggestion.score
                        ),
                    }
                    if let Some(person_id) = sp.person_id {
                        if let Err(e) =
                            PersonRepository::link_participant(pool, meeting_id, &person_id, "speaker").await
                        {
                            log::warn!("🎙️ diarize: failed to link matched participant (continuing): {e}");
                        }
                    }
                }
                Ok(None) => log::warn!("🎙️ diarize: matched speaker {matched_id} vanished — writing segments anyway"),
                Err(e) => log::warn!("🎙️ diarize: failed to load matched speaker (continuing): {e}"),
            }

            // Write every segment referencing the matched speaker (embedding on the first).
            for (j, seg) in segs.iter().enumerate() {
                let emb = if j == 0 { Some(centroid_bytes.as_slice()) } else { None };
                if let Err(e) = SpeakerRepository::insert_segment(
                    pool,
                    meeting_id,
                    &matched_id,
                    &cluster.speaker,
                    source,
                    seg.start,
                    seg.end,
                    emb,
                )
                .await
                {
                    log::warn!("🎙️ diarize: failed to insert matched segment (continuing): {e}");
                }
            }
            auto_assigned += 1;
        } else {
            // ---- Not eligible (Suggest/Anonymous): new provisional speaker ----
            provisional_created +=
                insert_provisional_cluster(pool, meeting_id, cluster, &segs, &centroid_bytes, emb_model_str, cluster_secs, source)
                    .await?;
        }
    }

    Ok((auto_assigned, provisional_created))
}

/// Create a new provisional speaker for a cluster (first segment) plus its remaining
/// segments. Returns `1` on success, `0` if the provisional insert failed (logged).
#[allow(clippy::too_many_arguments)]
async fn insert_provisional_cluster(
    pool: &sqlx::SqlitePool,
    meeting_id: &str,
    cluster: &engine::DiarCluster,
    segs: &[&engine::DiarSegment],
    centroid_bytes: &[u8],
    emb_model_str: &str,
    total_speech_secs: f64,
    source: &str,
) -> Result<usize, String> {
    let first = segs[0];
    let speaker_id = match SpeakerRepository::insert_provisional(
        pool,
        meeting_id,
        &cluster.speaker,
        source,
        centroid_bytes,
        emb_model_str,
        cluster.dim,
        first.start,
        first.end,
        total_speech_secs,
    )
    .await
    {
        Ok(id) => id,
        Err(e) => {
            log::warn!("🎙️ diarize: failed to create provisional speaker (skipping cluster): {e}");
            return Ok(0);
        }
    };

    for seg in segs.iter().skip(1) {
        if let Err(e) = SpeakerRepository::insert_segment(
            pool,
            meeting_id,
            &speaker_id,
            &cluster.speaker,
            source,
            seg.start,
            seg.end,
            None,
        )
        .await
        {
            log::warn!("🎙️ diarize: failed to insert provisional segment (continuing): {e}");
        }
    }
    Ok(1)
}

/// Stamp each transcript row with the resolved speaker whose segment it most
/// overlaps in time. Both tracks now yield **precise per-speaker spans** — the system
/// stream from remote-cluster diarization, and the mic from [`process_mic_track`]
/// (owner + any in-room speakers). We still **prefer a system-source match**: when a
/// line overlaps both a system and a microphone segment (e.g. faint local pickup of a
/// remote voice), the remote cluster is the more reliable attribution. Only when there
/// is **zero** system overlap do we fall back to the best-overlapping microphone
/// segment (owner or in-room). Within each source, ties break toward the *more
/// specific* (shorter) segment. Rows with no overlapping segment at all are left
/// untouched. Returns the count of rows stamped.
async fn stamp_transcripts(pool: &sqlx::SqlitePool, meeting_id: &str) -> Result<usize, String> {
    let segments = SpeakerRepository::list_segments_for_meeting(pool, meeting_id)
        .await
        .map_err(|e| format!("failed to load speaker segments: {e}"))?;
    if segments.is_empty() {
        return Ok(0);
    }

    // Read all transcript rows (with ids + audio times) for the meeting.
    let (transcripts, _total) =
        MeetingsRepository::get_meeting_transcripts_paginated(pool, meeting_id, i64::MAX, 0)
            .await
            .map_err(|e| format!("failed to load transcripts: {e}"))?;

    let mut stamped = 0usize;
    for t in &transcripts {
        let (Some(ts), Some(te)) = (t.audio_start_time, t.audio_end_time) else {
            continue;
        };

        // Track the best overlap separately for system-source and non-system
        // (microphone / owner) segments. System wins whenever it overlaps at all.
        let mut best_system: Option<(&str, f64, f64)> = None; // (speaker_id, overlap, seg_dur)
        let mut best_fallback: Option<(&str, f64, f64)> = None;
        for seg in &segments {
            let Some(sid) = seg.speaker_id.as_deref() else {
                continue;
            };
            let overlap = te.min(seg.end_time) - ts.max(seg.start_time);
            if overlap <= 0.0 {
                continue;
            }
            let seg_dur = (seg.end_time - seg.start_time).max(0.0);
            let slot = if seg.source == "system" {
                &mut best_system
            } else {
                &mut best_fallback
            };
            let take = match *slot {
                None => true,
                Some((_, best_overlap, best_dur)) => {
                    overlap > best_overlap
                        || (approx_eq(overlap, best_overlap) && seg_dur < best_dur)
                }
            };
            if take {
                *slot = Some((sid, overlap, seg_dur));
            }
        }

        // Prefer a system-source match; fall back to the owner/microphone span.
        if let Some((sid, _, _)) = best_system.or(best_fallback) {
            match SpeakerRepository::set_transcript_speaker(pool, &t.id, sid).await {
                Ok(()) => stamped += 1,
                Err(e) => log::warn!("🎙️ diarize: failed to stamp transcript {} (continuing): {e}", t.id),
            }
        }
    }

    Ok(stamped)
}

/// Honest counts of what a [`speaker_reset_owner_voiceprint`] run cleared.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetOwnerVoiceprintResult {
    pub transcripts_unstamped: u64,
    pub segments_deleted: u64,
    pub voiceprints_deleted: u64,
}

/// Reset the owner's persistent voiceprint — the recovery path when an in-person meeting
/// folded another person's voice into it. Deletes the owner voiceprint (and its segments /
/// transcript stamps); the next time diarization runs on a meeting, a fresh owner voiceprint
/// is rebuilt from that meeting's mic. For the cleanest rebuild, re-identify speakers on a
/// recording where the owner is the main speaker. No-op (all zeros) if no owner voiceprint
/// exists yet.
pub async fn speaker_reset_owner_voiceprint_impl(
    engine: &Engine,
) -> Result<ResetOwnerVoiceprintResult, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let owner = PersonRepository::get_owner(pool)
        .await
        .map_err(|e| format!("failed to load owner: {e}"))?
        .ok_or_else(|| "no owner profile is configured".to_string())?;
    let (transcripts_unstamped, segments_deleted, voiceprints_deleted) =
        SpeakerRepository::reset_owner_voiceprint(pool, &owner.id)
            .await
            .map_err(|e| format!("failed to reset owner voiceprint: {e}"))?;
    log::info!(
        "🎙️ diarize: reset owner voiceprint — transcripts_unstamped={transcripts_unstamped}, segments_deleted={segments_deleted}, voiceprints_deleted={voiceprints_deleted}"
    );
    Ok(ResetOwnerVoiceprintResult {
        transcripts_unstamped,
        segments_deleted,
        voiceprints_deleted,
    })
}

#[tauri::command]
pub async fn speaker_reset_owner_voiceprint(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<ResetOwnerVoiceprintResult, String> {
    speaker_reset_owner_voiceprint_impl(&engine).await
}

/// Read command: speakers appearing in a meeting, with enrollment status + segment
/// counts. Feeds the later "who spoke" chips UI. Honest counts only.
pub async fn speaker_list_for_meeting_impl(
    engine: &Engine,
    meeting_id: String,
) -> Result<Vec<MeetingSpeakerRow>, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    let speakers = SpeakerRepository::list_for_meeting(pool, &meeting_id)
        .await
        .map_err(|e| format!("failed to list speakers for meeting: {e}"))?;
    let segments = SpeakerRepository::list_segments_for_meeting(pool, &meeting_id)
        .await
        .map_err(|e| format!("failed to list speaker segments: {e}"))?;

    let mut rows = Vec::with_capacity(speakers.len());
    for s in speakers {
        let segment_count = segments
            .iter()
            .filter(|seg| seg.speaker_id.as_deref() == Some(s.id.as_str()))
            .count();

        // Resolve the linked person's display name (best-effort; None if unlinked or gone).
        let person_name = match &s.person_id {
            Some(pid) => match PersonRepository::get(pool, pid).await {
                Ok(Some(p)) => Some(p.display_name),
                Ok(None) => None,
                Err(e) => {
                    log::warn!("🎙️ speaker_list: failed to resolve person {pid} (continuing): {e}");
                    None
                }
            },
            None => None,
        };

        rows.push(MeetingSpeakerRow {
            speaker_id: s.id,
            person_id: s.person_id,
            person_name,
            label: s.label,
            enrollment_state: s.enrollment_state,
            segment_count,
        });
    }

    Ok(rows)
}

#[tauri::command]
pub async fn speaker_list_for_meeting(
    meeting_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<MeetingSpeakerRow>, String> {
    speaker_list_for_meeting_impl(&engine, meeting_id).await
}

/// Manually reassign one transcript line's speaker (user-driven correction, e.g. a
/// merged/mis-attributed line, or a diarized cluster that got the wrong identity).
/// This is the per-LINE counterpart to [`speaker_assign_to_person`] (which relabels
/// a whole cluster/identity): it only touches this single transcript row's resolved
/// `speaker_id` — no centroid, segment, or other transcript row is affected. Pass
/// `speaker_id: None` to clear a line back to unattributed ("Unknown").
///
/// `speaker_id`, when present, must reference a speaker that exists (any enrollment
/// state — provisional/confirmed/owner) so a typo'd id can't silently no-op.
pub async fn speaker_reassign_transcript_line_impl(
    engine: &Engine,
    meeting_id: String,
    transcript_id: String,
    speaker_id: Option<String>,
) -> Result<bool, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    if let Some(id) = &speaker_id {
        match SpeakerRepository::get(pool, id).await {
            Ok(Some(_)) => {}
            Ok(None) => return Err(format!("speaker {id} not found")),
            Err(e) => return Err(format!("failed to look up speaker {id}: {e}")),
        }
    }

    SpeakerRepository::reassign_transcript_speaker(
        pool,
        &meeting_id,
        &transcript_id,
        speaker_id.as_deref(),
    )
    .await
    .map_err(|e| format!("failed to reassign transcript {transcript_id}: {e}"))
}

#[tauri::command]
pub async fn speaker_reassign_transcript_line(
    meeting_id: String,
    transcript_id: String,
    speaker_id: Option<String>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<bool, String> {
    speaker_reassign_transcript_line_impl(&engine, meeting_id, transcript_id, speaker_id).await
}

/// Cap on how many historical provisional speakers a single assign may retroactively
/// relabel — a runaway guard (P1 task 3).
const RETRO_RELABEL_LIMIT: i64 = 200;

/// Confirm an assignment: link a provisional/anonymous speaker's voiceprint to a known
/// person (confirm-before-enroll). Once assigned, the voice is enrolled and future
/// meetings auto-match it.
///
/// **P1 — merge-to-canonical + retroactive relabel:**
/// - If the person already has an enrolled voiceprint in the same embedding space (the
///   CANONICAL row), the assigned speaker's centroid is DURATION-WEIGHTED folded into
///   it, its segments + transcript stamps are repointed to the canonical, and the now-
///   empty provisional row is deleted. This stops one person from fragmenting across
///   many voiceprint rows (which weakened the improvement signal). The response's
///   `speakerId` is the canonical row.
/// - Otherwise the assigned row itself becomes the canonical (`confirmed`, person
///   linked) — the prior behavior.
/// - Either way, we then scan OTHER meetings' provisional speakers (same embedding
///   space, not sharing a meeting with the canonical) and auto-merge any that match
///   the strengthened canonical at the AutoConfirm tier — back-filling identity across
///   history. The count is returned in `retroRelabeled`.
///
/// Also links the person as a participant of every meeting the (canonical) voice
/// appears in (best-effort: a single link failure is logged, not fatal).
pub async fn speaker_assign_to_person_impl(
    engine: &Engine,
    speaker_id: String,
    person_id: String,
) -> Result<SpeakerAssignResult, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let cfg = matching::MatchConfig::default();

    let subject = SpeakerRepository::get(pool, &speaker_id)
        .await
        .map_err(|e| format!("failed to load speaker {speaker_id}: {e}"))?
        .ok_or_else(|| format!("speaker {speaker_id} not found"))?;
    let model = subject.embedding_model.clone();

    // Does this person already have a canonical voiceprint in the same vector space?
    let canonical = SpeakerRepository::find_canonical_for_person(pool, &person_id, &model, &speaker_id)
        .await
        .map_err(|e| format!("failed to look up canonical speaker for person {person_id}: {e}"))?;

    let canonical_id = match canonical {
        Some(canon) => {
            // Merge the assigned (provisional) row into the existing canonical.
            merge_speaker_into(pool, &subject, &canon, &cfg).await?;
            log::info!(
                "🎙️ speaker_assign: merged speaker {speaker_id} into canonical {} for person {person_id}",
                canon.id
            );
            canon.id
        }
        None => {
            // No canonical yet → this row becomes it.
            SpeakerRepository::assign_to_person(pool, &speaker_id, &person_id)
                .await
                .map_err(|e| format!("failed to assign speaker {speaker_id} to person {person_id}: {e}"))?;
            speaker_id.clone()
        }
    };

    // Retroactively relabel matching historical provisional speakers onto the canonical.
    let retro_relabeled = retroactive_relabel(pool, &canonical_id, &person_id, &model, &cfg).await;
    if retro_relabeled > 0 {
        log::info!(
            "🎙️ speaker_assign: retro-relabel merged {retro_relabeled} historical provisional speaker(s) into canonical {canonical_id}"
        );
    }

    // Link the person to every meeting the canonical voice was heard in (best-effort;
    // idempotent). After merges this covers all repointed meetings too.
    match SpeakerRepository::list_meeting_ids_for_speaker(pool, &canonical_id).await {
        Ok(meeting_ids) => {
            for meeting_id in meeting_ids {
                if let Err(e) =
                    PersonRepository::link_participant(pool, &meeting_id, &person_id, "speaker").await
                {
                    log::warn!(
                        "🎙️ speaker_assign: failed to link person {person_id} to meeting {meeting_id} (continuing): {e}"
                    );
                }
            }
        }
        Err(e) => log::warn!(
            "🎙️ speaker_assign: failed to list meetings for canonical {canonical_id} (assignment still applied): {e}"
        ),
    }

    Ok(SpeakerAssignResult {
        speaker_id: canonical_id,
        retro_relabeled,
    })
}

#[tauri::command]
pub async fn speaker_assign_to_person(
    speaker_id: String,
    person_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<SpeakerAssignResult, String> {
    speaker_assign_to_person_impl(&engine, speaker_id, person_id).await
}

/// Fold one speaker's voiceprint into another and repoint all its references, then
/// delete it (P1 merge-to-canonical). Duration-weighted, quality-gated fold (the fold
/// is skipped — but the merge still proceeds — for a too-short/degenerate source, so a
/// user-confirmed identity is never lost while a noisy centroid can't drift a good
/// one). Not fatal on individual step failures beyond the repoint/delete itself.
async fn merge_speaker_into(
    pool: &sqlx::SqlitePool,
    from: &crate::database::models::Speaker,
    into: &crate::database::models::Speaker,
    cfg: &matching::MatchConfig,
) -> Result<(), String> {
    // The source's speech weight: its stored total, or (older rows) the sum of its
    // segment durations.
    let from_secs = if from.total_speech_secs > 0.0 {
        from.total_speech_secs
    } else {
        SpeakerRepository::total_segment_secs(pool, &from.id)
            .await
            .unwrap_or(0.0)
    };

    let from_centroid = engine::bytes_to_centroid(&from.centroid);
    let into_centroid = engine::bytes_to_centroid(&into.centroid);

    match matching::should_fold(from_secs, &from_centroid, into_centroid.len(), None, cfg) {
        Ok(()) => {
            let folded = matching::fold_centroid_weighted(
                &into_centroid,
                into.total_speech_secs,
                &from_centroid,
                from_secs,
            );
            if let Err(e) = SpeakerRepository::fold_centroid(
                pool,
                &into.id,
                &engine::centroid_to_bytes(&folded),
                into.samples + 1,
                into.total_speech_secs + from_secs,
            )
            .await
            {
                log::warn!("🎙️ speaker_assign: failed to fold merged centroid (continuing): {e}");
            }
        }
        Err(reason) => log::info!(
            "🎙️ speaker_assign: merge fold skipped ({reason}, speech={from_secs:.1}s) — repointing references only"
        ),
    }

    // Repoint segments + transcript stamps to the canonical, then delete the row.
    SpeakerRepository::repoint_and_delete_speaker(pool, &from.id, &into.id)
        .await
        .map_err(|e| format!("failed to merge speaker {} into {}: {e}", from.id, into.id))?;
    Ok(())
}

/// Scan OTHER meetings' provisional speakers (same embedding space, not co-present in
/// any of the canonical's meetings) and auto-merge any that match the canonical at the
/// AutoConfirm tier. Returns how many were merged. Best-effort throughout: a single
/// failure is logged and skipped, never fatal. Bounded by [`RETRO_RELABEL_LIMIT`].
async fn retroactive_relabel(
    pool: &sqlx::SqlitePool,
    canonical_id: &str,
    person_id: &str,
    embedding_model: &str,
    cfg: &matching::MatchConfig,
) -> usize {
    let provisionals = match SpeakerRepository::list_provisional_for_relabel(
        pool,
        embedding_model,
        canonical_id,
        RETRO_RELABEL_LIMIT,
    )
    .await
    {
        Ok(v) => v,
        Err(e) => {
            log::warn!("🎙️ diarize: retro-relabel candidate query failed (skipping): {e}");
            return 0;
        }
    };
    if provisionals.is_empty() {
        return 0;
    }

    // Guard against merging two DISTINCT co-present voices: once we claim a meeting via
    // one merge, skip any later provisional that also appears in that meeting.
    use std::collections::HashSet;
    let mut claimed_meetings: HashSet<String> = HashSet::new();
    let mut merged = 0usize;

    for prov in provisionals {
        // Reload the canonical fresh so its evolving (post-merge) centroid + weight
        // drive both the match decision and the next fold.
        let canon = match SpeakerRepository::get(pool, canonical_id).await {
            Ok(Some(c)) => c,
            Ok(None) => {
                log::warn!("🎙️ diarize: retro-relabel canonical {canonical_id} vanished — stopping");
                break;
            }
            Err(e) => {
                log::warn!("🎙️ diarize: retro-relabel failed to reload canonical (stopping): {e}");
                break;
            }
        };
        let canon_centroid = engine::bytes_to_centroid(&canon.centroid);
        if canon_centroid.is_empty() {
            break;
        }
        let candidates = [matching::Candidate {
            id: canon.id.clone(),
            name: person_id.to_string(),
            centroid: canon_centroid,
        }];

        // Skip if this provisional shares a meeting we've already claimed.
        let prov_meetings = SpeakerRepository::list_meeting_ids_for_speaker(pool, &prov.id)
            .await
            .unwrap_or_default();
        if prov_meetings.iter().any(|m| claimed_meetings.contains(m)) {
            log::info!(
                "🎙️ diarize: retro-relabel skipping {} — co-present in an already-claimed meeting",
                prov.id
            );
            continue;
        }

        let prov_centroid = engine::bytes_to_centroid(&prov.centroid);
        let m = matching::match_embedding(&prov_centroid, &candidates, cfg);
        // AutoConfirm tier (≥ auto_threshold; single candidate → margin trivially ok).
        if !m.eligible {
            continue;
        }

        if let Err(e) = merge_speaker_into(pool, &prov, &canon, cfg).await {
            log::warn!("🎙️ diarize: retro-relabel merge failed for {} (skipping): {e}", prov.id);
            continue;
        }
        // Link the person to the merged provisional's meetings (idempotent).
        for meeting_id in &prov_meetings {
            let _ = PersonRepository::link_participant(pool, meeting_id, person_id, "speaker").await;
            claimed_meetings.insert(meeting_id.clone());
        }
        log::info!(
            "🎙️ diarize: retro-relabel merged provisional {} into canonical {canonical_id} (score={:.3})",
            prov.id,
            m.score
        );
        merged += 1;
    }

    merged
}

/// Result of [`speaker_assign_to_person`] (P1). Reports the CANONICAL speaker the
/// person's voiceprint now lives on (may differ from the requested `speakerId` when
/// the assigned row was merged into a pre-existing canonical), plus how many other
/// historical provisional speakers were retroactively relabeled onto it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeakerAssignResult {
    /// The canonical speaker id the person's voiceprint is consolidated on.
    pub speaker_id: String,
    /// How many other meetings' provisional speakers were auto-merged into the
    /// canonical by retroactive relabel (0 when none matched confidently).
    pub retro_relabeled: usize,
}

/// One enrolled-person suggestion for the "assign this voice" dialog.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeakerMatchSuggestion {
    pub person_id: String,
    pub person_name: String,
    pub score: f32,
    pub tier: String,
}

/// Rank the enrolled people whose voiceprints most resemble the given (usually
/// provisional) speaker — the candidate list for the assign dialog. Honest: never
/// fabricates entries. Returns an empty vec when there are no enrolled candidates.
///
/// One person may own several enrolled speaker rows; results are deduped by person,
/// keeping each person's best score. Weak matches (score < 0.3) are dropped as noise,
/// but the single best candidate is always kept if any exist. Top ~5 returned, sorted
/// by descending similarity.
pub async fn speaker_match_suggestions_impl(
    engine: &Engine,
    speaker_id: String,
) -> Result<Vec<SpeakerMatchSuggestion>, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let cfg = matching::MatchConfig::default();

    // Subject speaker + its centroid.
    let subject = SpeakerRepository::get(pool, &speaker_id)
        .await
        .map_err(|e| format!("failed to load speaker {speaker_id}: {e}"))?
        .ok_or_else(|| format!("speaker {speaker_id} not found"))?;
    let query = engine::bytes_to_centroid(&subject.centroid);
    if query.is_empty() {
        return Ok(Vec::new());
    }

    // Enrolled candidates: exclude the subject itself and any speaker with no person link.
    let enrolled = SpeakerRepository::list_all_enrolled(pool)
        .await
        .map_err(|e| format!("failed to load enrolled speakers: {e}"))?;

    // Best score per person (dedupe multiple voiceprints of the same person).
    use std::collections::HashMap;
    let mut best_by_person: HashMap<String, (String, f32)> = HashMap::new(); // person_id -> (name, score)
    for cand in &enrolled {
        if cand.id == speaker_id {
            continue;
        }
        let Some(person_id) = cand.person_id.as_deref() else {
            continue;
        };
        let centroid = engine::bytes_to_centroid(&cand.centroid);
        let score = matching::cosine_similarity(&query, &centroid);

        // Resolve the person's display name (skip if the person row is gone).
        let name = match PersonRepository::get(pool, person_id).await {
            Ok(Some(p)) => p.display_name,
            Ok(None) => continue,
            Err(e) => {
                log::warn!("🎙️ match_suggestions: failed to resolve person {person_id} (skipping): {e}");
                continue;
            }
        };

        best_by_person
            .entry(person_id.to_string())
            .and_modify(|entry| {
                if score > entry.1 {
                    *entry = (name.clone(), score);
                }
            })
            .or_insert((name, score));
    }

    // Sort people by descending best score.
    let mut ranked: Vec<(String, String, f32)> = best_by_person
        .into_iter()
        .map(|(pid, (name, score))| (pid, name, score))
        .collect();
    ranked.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));

    // Drop noise (< 0.3) but always keep at least the top candidate if any exist.
    let mut suggestions: Vec<SpeakerMatchSuggestion> = ranked
        .into_iter()
        .enumerate()
        .filter(|(i, (_, _, score))| *i == 0 || *score >= 0.3)
        .take(5)
        .map(|(_, (person_id, person_name, score))| SpeakerMatchSuggestion {
            person_id,
            person_name,
            tier: tier_for_score(score, &cfg).to_string(),
            score,
        })
        .collect();

    // If the top candidate itself is pure noise, surface nothing rather than a junk row.
    if suggestions.len() == 1 && suggestions[0].score < 0.3 {
        suggestions.clear();
    }

    Ok(suggestions)
}

#[tauri::command]
pub async fn speaker_match_suggestions(
    speaker_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<SpeakerMatchSuggestion>, String> {
    speaker_match_suggestions_impl(&engine, speaker_id).await
}

/// Classify a raw cosine into the matcher's tier labels using the shared thresholds.
/// Per-candidate (no runner-up margin) — margin gating is a meeting-level concern; here we
/// just report how strong each individual person match is for the assign dialog.
fn tier_for_score(score: f32, cfg: &matching::MatchConfig) -> &'static str {
    if score >= cfg.auto_threshold {
        "auto"
    } else if score >= cfg.suggest_threshold {
        "suggest"
    } else {
        "anonymous"
    }
}

// ============================================================================
// Small helpers (pure / infallible)
// ============================================================================

/// Duration in seconds of a 16 kHz mono `pcm_s16le` WAV (as produced by
/// [`engine::transcode_to_16k_mono_wav`]), computed from file size. Header is 44
/// bytes; payload is 2 bytes/sample at 16000 samples/sec. Returns `0.0` if the file
/// is unreadable or shorter than a header.
fn wav_duration_secs(path: &Path) -> f64 {
    match std::fs::metadata(path) {
        Ok(m) => {
            let len = m.len();
            if len <= 44 {
                0.0
            } else {
                (len - 44) as f64 / (16_000.0 * 2.0)
            }
        }
        Err(_) => 0.0,
    }
}

/// Derive a stable embedding-model id string from the model file path (its stem).
fn model_id_from_path(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| "campplus".to_string())
}

/// A short, filesystem-safe fragment of a meeting id for scratch-dir naming.
fn short_id(meeting_id: &str) -> String {
    meeting_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(8)
        .collect()
}

fn approx_eq(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-6
}

/// Resolve the OS temp dir without a hard dependency on `tauri::Manager` being in
/// scope at the call site. Kept tiny and infallible-ish (falls back to
/// `std::env::temp_dir`).
trait TempDirExt {
    fn path_temp_dir(&self) -> PathBuf;
}

impl TempDirExt for AppHandle {
    fn path_temp_dir(&self) -> PathBuf {
        use tauri::Manager;
        self.path()
            .temp_dir()
            .unwrap_or_else(|_| std::env::temp_dir())
    }
}
