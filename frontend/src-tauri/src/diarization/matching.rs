//! # Speaker voiceprint matching (pure)
//!
//! Ported from an older project's production-proven `speakers.py`. This module
//! is **pure**: no DB, no file I/O, no async, no Tauri. Every function is a
//! deterministic transform over `f32` slices, which makes it trivially
//! unit-testable. The app layer (a later phase) calls these functions and owns
//! all persistence.
//!
//! ## What it does
//!
//! Speaker identity is represented as a **voiceprint centroid** — a running
//! mean of the embeddings observed for that speaker. Matching a fresh embedding
//! against a set of enrolled speakers is **cosine similarity** ranked
//! descending, gated by:
//!
//! 1. an **absolute threshold** (is the top match good enough at all?), and
//! 2. a **margin over the runner-up** (is the top match *unambiguously* better
//!    than the second-best?).
//!
//! Only when both gates pass is a match `eligible` for auto-assignment without
//! user confirmation ("confirm-before-enroll"). Everything else is surfaced as
//! a *suggestion* the user must confirm, or left anonymous.
//!
//! ## Threshold provenance (RETUNE ON REAL RECORDINGS)
//!
//! The thresholds below are **starting values**, not final tuning. The old
//! project ran a different embedder and settled on `0.72` absolute + `0.08`
//! margin. Our embedder is **CAM++**, so we start slightly looser at `0.70`
//! auto / `0.55` suggest, keeping the same `0.08` margin. These MUST be
//! re-measured against real Ari recordings once the audio→embedding path is
//! wired; treat them as a first guess, not gospel.

/// Cosine similarity between two equal-length embeddings.
///
/// Returns a value in `[-1.0, 1.0]` where `1.0` is identical direction, `0.0`
/// orthogonal, and `-1.0` opposite. This is the raw comparison primitive the
/// whole matcher is built on.
///
/// ## Guards (ported semantics)
///
/// - **Length mismatch** → `0.0`. Embeddings of different dimension are not
///   comparable; rather than panic we treat them as "no similarity".
/// - **Zero-norm** (either side all-zeros, e.g. an empty/degenerate embedding)
///   → `0.0`. A zero vector has no direction, so cosine is undefined; `0.0` is
///   the safe, non-matching answer.
/// - **Empty slices** → `0.0` (a special case of both guards above).
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }

    let mut dot = 0.0f32;
    let mut norm_a = 0.0f32;
    let mut norm_b = 0.0f32;
    for i in 0..a.len() {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }

    if norm_a <= 0.0 || norm_b <= 0.0 {
        return 0.0;
    }

    dot / (norm_a.sqrt() * norm_b.sqrt())
}

/// Fold a new embedding into a stored centroid using a **running mean**.
///
/// Implements, element-wise:
///
/// ```text
/// new_centroid = (stored * n + emb) / (n + 1)
/// ```
///
/// where `n = stored_samples` is the number of embeddings already averaged into
/// `stored`. This is the "voice signature improves every meeting" core: each
/// confirmed segment nudges the centroid toward the true voice without storing
/// every embedding.
///
/// The caller is responsible for incrementing the persisted sample count to
/// `n + 1` separately (this function is pure and stateless).
///
/// ## Guards
///
/// - If `stored` is empty (a brand-new speaker with no centroid yet), the new
///   embedding **is** the centroid — returns a copy of `new_emb`.
/// - If `new_emb` is empty, returns a copy of `stored` unchanged.
/// - If lengths mismatch (and both are non-empty), returns a copy of `stored`
///   unchanged — we refuse to corrupt a good centroid with a mis-dimensioned
///   embedding.
pub fn fold_centroid(stored: &[f32], stored_samples: u32, new_emb: &[f32]) -> Vec<f32> {
    if stored.is_empty() {
        return new_emb.to_vec();
    }
    if new_emb.is_empty() || stored.len() != new_emb.len() {
        return stored.to_vec();
    }

    let n = stored_samples as f32;
    let denom = n + 1.0;
    stored
        .iter()
        .zip(new_emb.iter())
        .map(|(&s, &e)| (s * n + e) / denom)
        .collect()
}

/// Minimum speech (seconds) a cluster must hold before it may fold into a
/// voiceprint centroid (P1 quality gate). Shorter clusters are too noisy/uncertain
/// to trust as identity signal — the match is still kept, only the fold is skipped.
pub const MIN_FOLD_SPEECH_SECS: f64 = 5.0;

/// Cap (seconds) applied to a stored voiceprint's `total_speech_secs` **when used
/// as the fold weight `W`**. Once a voiceprint is "mature" (≥ this much folded
/// speech), each new fold has weight `w / (CAP + w)`, i.e. the centroid behaves as
/// an exponential moving average and stays adaptive instead of ossifying. The
/// *stored* `total_speech_secs` keeps accumulating past the cap — only its use as a
/// weight is capped.
pub const FOLD_WEIGHT_CAP_SECS: f64 = 600.0;

/// Duration-weighted fold of a new cluster centroid into a stored voiceprint.
///
/// Implements, element-wise, then re-L2-normalizes:
///
/// ```text
/// new = (stored * W + new_emb * w) / (W + w)      where W = min(stored_total_secs, CAP)
/// ```
///
/// `w` = the new cluster's total speech seconds; `W` = the stored voiceprint's
/// accumulated speech seconds **capped at [`FOLD_WEIGHT_CAP_SECS`]**. This makes a
/// long, confident cluster move the centroid more than a short one, and — via the
/// cap — turns a mature voiceprint into an EMA (see the cap docs). The result is
/// re-L2-normalized so cosine comparisons stay well-scaled.
///
/// The caller persists the new `total_speech_secs` (= `stored_total_secs + w`, the
/// UNcapped accumulation) and bumps `samples` separately — this function is pure.
///
/// ## Guards (mirror [`fold_centroid`])
/// - empty `stored` → returns L2-normalized `new_emb` (brand-new voiceprint);
/// - empty `new_emb`, or a length mismatch → returns `stored` unchanged (never
///   corrupt a good centroid with a bad embedding);
/// - non-positive total weight → falls back to an equal-weight mean.
pub fn fold_centroid_weighted(
    stored: &[f32],
    stored_total_secs: f64,
    new_emb: &[f32],
    new_secs: f64,
) -> Vec<f32> {
    if stored.is_empty() {
        return l2_normalize(new_emb.to_vec());
    }
    if new_emb.is_empty() || stored.len() != new_emb.len() {
        return stored.to_vec();
    }

    let big_w = stored_total_secs.clamp(0.0, FOLD_WEIGHT_CAP_SECS);
    let small_w = new_secs.max(0.0);
    let (big_w, small_w) = if big_w + small_w <= 0.0 {
        (1.0, 1.0) // both zero → equal weight
    } else {
        (big_w, small_w)
    };
    let denom = (big_w + small_w) as f32;
    let merged: Vec<f32> = stored
        .iter()
        .zip(new_emb.iter())
        .map(|(&s, &e)| (s * big_w as f32 + e * small_w as f32) / denom)
        .collect();
    l2_normalize(merged)
}

/// L2-normalize a vector (new owned vector). A zero-norm input is returned
/// unchanged so downstream cosine reads it as no-match.
fn l2_normalize(mut v: Vec<f32>) -> Vec<f32> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > f32::EPSILON {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
    v
}

/// Quality gate for a **duration-weighted fold** (P1): decide whether a matched
/// (or owner) cluster is trustworthy enough to update a stored voiceprint. When it
/// returns `Err(reason)` the caller keeps the match/assignment but SKIPS the fold
/// (and logs `reason`), so a noisy cluster never drifts a good voiceprint.
///
/// Gates:
/// - `cluster_speech_secs >= `[`MIN_FOLD_SPEECH_SECS`] (too-short clusters are noise);
/// - `new_emb` non-empty and not all-zero (a real centroid);
/// - if `stored_len != 0`, dimensions match `new_emb`;
/// - `match_score`, when `Some`, is `>= auto_threshold + margin` — i.e. only an
///   *unambiguously strong* auto-confirm folds; suggest-tier matches never fold.
///   Pass `None` for the owner path (owner enrollment is not a cross-speaker match).
pub fn should_fold(
    cluster_speech_secs: f64,
    new_emb: &[f32],
    stored_len: usize,
    match_score: Option<f32>,
    cfg: &MatchConfig,
) -> Result<(), &'static str> {
    if cluster_speech_secs < MIN_FOLD_SPEECH_SECS {
        return Err("cluster speech below fold minimum");
    }
    if new_emb.is_empty() || new_emb.iter().all(|&x| x == 0.0) {
        return Err("centroid empty or zero");
    }
    if stored_len != 0 && stored_len != new_emb.len() {
        return Err("centroid dimension mismatch");
    }
    if let Some(score) = match_score {
        if score < cfg.auto_threshold + cfg.margin {
            return Err("match score below auto+margin");
        }
    }
    Ok(())
}

/// Tunable thresholds for the dual-gate, three-tier matcher.
///
/// See the module docs for provenance: these are **CAM++ starting values** to
/// retune on real recordings, not final tuning.
#[derive(Debug, Clone, PartialEq)]
pub struct MatchConfig {
    /// Absolute cosine at/above which a top match may auto-confirm (given the
    /// margin gate also passes). Default `0.70`.
    pub auto_threshold: f32,
    /// Absolute cosine at/above which a top match is worth *suggesting* to the
    /// user. Below this, the speaker is left anonymous. Default `0.55`.
    pub suggest_threshold: f32,
    /// How far the best match must beat the runner-up to be considered
    /// **unambiguous**. If `best - runner_up < margin`, we never auto-confirm
    /// even when `best >= auto_threshold`. Default `0.08`.
    pub margin: f32,
    /// Minimum segment duration (seconds) before an embedding is clean/long
    /// enough to fold into a profile. Default `3.0`. See [`is_enrollable`].
    pub min_enroll_duration_s: f32,
    /// Minimum self-similarity (an embedding compared against its own cluster
    /// centroid) required before folding — the "suspect-cluster guard".
    /// Default `0.60`. See [`is_enrollable`].
    pub min_enroll_self_similarity: f32,
}

impl Default for MatchConfig {
    fn default() -> Self {
        Self {
            auto_threshold: 0.70,
            suggest_threshold: 0.55,
            margin: 0.08,
            min_enroll_duration_s: 3.0,
            min_enroll_self_similarity: 0.60,
        }
    }
}

/// An enrolled speaker candidate to match against.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    /// Stable speaker id (owned by the app/DB layer).
    pub id: String,
    /// Human-readable name for surfacing suggestions.
    pub name: String,
    /// The speaker's voiceprint centroid (running mean of embeddings).
    pub centroid: Vec<f32>,
}

/// Which confidence tier a match landed in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchTier {
    /// Best `>= auto_threshold` **and** beats runner-up by `>= margin`.
    /// Safe to auto-assign without user confirmation.
    AutoConfirm,
    /// Best in `[suggest_threshold, auto_threshold)`, **or** `>= auto_threshold`
    /// but the margin over the runner-up is too small (ambiguous). Surfaced to
    /// the user to confirm.
    Suggest,
    /// Best `< suggest_threshold` (or nothing to match against). Leave the
    /// speaker anonymous.
    Anonymous,
}

/// Why the matcher produced the tier/decision it did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchReason {
    /// A confident, unambiguous match at/above `auto_threshold`.
    Matched,
    /// Top match fell below `suggest_threshold`.
    BelowThreshold,
    /// Top match cleared a threshold but did not beat the runner-up by
    /// `margin` — ambiguous, so not auto-assigned.
    AmbiguousMargin,
    /// The query embedding was empty/zero-length (nothing to compare).
    NoEmbedding,
    /// There were no candidates to compare against.
    NoCandidates,
    /// Otherwise-eligible match was downgraded because the cluster's total
    /// speech was below [`MIN_AUTO_CONFIRM_SPEECH_SECS`] — too short/noisy to
    /// trust without user confirmation. See [`gate_auto_confirm_by_duration`].
    TooShortForAutoConfirm,
}

/// The result of matching one query embedding against a candidate set.
#[derive(Debug, Clone, PartialEq)]
pub struct MatchSuggestion {
    /// The matched speaker id, if any candidate was the top match. Present for
    /// all tiers where a best candidate exists (including `Suggest` and even
    /// `Anonymous` when a weak best exists), so callers can inspect it; only
    /// [`MatchSuggestion::eligible`] gates auto-assignment.
    pub speaker_id: Option<String>,
    /// The matched speaker name, mirroring `speaker_id`.
    pub name: Option<String>,
    /// Cosine of the best candidate (`0.0` when there was nothing to match).
    pub score: f32,
    /// Cosine of the second-best candidate, if one exists.
    pub runner_up: Option<f32>,
    /// Which confidence tier this landed in.
    pub tier: MatchTier,
    /// `true` **only** for `AutoConfirm` — i.e. safe to auto-assign without
    /// user confirmation. `Suggest`/`Anonymous` require confirm-before-enroll.
    pub eligible: bool,
    /// Why this decision was reached.
    pub reason: MatchReason,
}

impl MatchSuggestion {
    /// An empty/no-op result carrying a specific reason and score `0.0`.
    fn empty(reason: MatchReason) -> Self {
        Self {
            speaker_id: None,
            name: None,
            score: 0.0,
            runner_up: None,
            tier: MatchTier::Anonymous,
            reason,
            eligible: false,
        }
    }
}

/// Match a single query embedding against a set of enrolled candidates.
///
/// Computes cosine to every candidate, ranks descending, then applies the
/// dual-gate three-tier logic (see [`MatchTier`] / [`MatchConfig`]).
///
/// Pure and allocation-light; does not mutate any input.
pub fn match_embedding(
    query: &[f32],
    candidates: &[Candidate],
    cfg: &MatchConfig,
) -> MatchSuggestion {
    if query.is_empty() {
        return MatchSuggestion::empty(MatchReason::NoEmbedding);
    }
    if candidates.is_empty() {
        return MatchSuggestion::empty(MatchReason::NoCandidates);
    }

    // Score every candidate.
    let mut scored: Vec<(usize, f32)> = candidates
        .iter()
        .enumerate()
        .map(|(i, c)| (i, cosine_similarity(query, &c.centroid)))
        .collect();

    // Rank descending by score. Stable sort keeps input order on ties.
    scored.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let (best_idx, best_score) = scored[0];
    let runner_up = scored.get(1).map(|&(_, s)| s);
    let best = &candidates[best_idx];

    classify(
        Some((best.id.clone(), best.name.clone())),
        best_score,
        runner_up,
        cfg,
    )
}

/// Core tier classification shared by [`match_embedding`] and
/// [`assign_meeting_clusters`]. Given the best candidate's identity + score and
/// the runner-up score, decide the tier/reason/eligibility.
fn classify(
    best: Option<(String, String)>,
    best_score: f32,
    runner_up: Option<f32>,
    cfg: &MatchConfig,
) -> MatchSuggestion {
    let (speaker_id, name) = match best {
        Some((id, n)) => (Some(id), Some(n)),
        None => (None, None),
    };

    let margin_ok = match runner_up {
        Some(r) => (best_score - r) >= cfg.margin,
        // No runner-up means nothing to be ambiguous against → margin passes.
        None => true,
    };

    let (tier, reason, eligible) = if best_score < cfg.suggest_threshold {
        (MatchTier::Anonymous, MatchReason::BelowThreshold, false)
    } else if best_score >= cfg.auto_threshold && margin_ok {
        (MatchTier::AutoConfirm, MatchReason::Matched, true)
    } else if best_score >= cfg.auto_threshold {
        // Cleared the absolute bar but too close to the runner-up.
        (MatchTier::Suggest, MatchReason::AmbiguousMargin, false)
    } else {
        // In [suggest_threshold, auto_threshold): worth suggesting.
        (MatchTier::Suggest, MatchReason::Matched, false)
    };

    MatchSuggestion {
        speaker_id,
        name,
        score: best_score,
        runner_up,
        tier,
        eligible,
        reason,
    }
}

/// Minimum total cluster speech (seconds) required before an `AutoConfirm`
/// match may be trusted without user confirmation.
///
/// Auto-confirm eligibility (`classify`) is pure cosine + margin — it has no
/// duration or noise gate, so a short/noisy cluster can score `>= auto_threshold`
/// against an enrolled voiceprint by chance. This risk is sharpest for the
/// **owner's own voiceprint**, which is deliberately matched against every
/// meeting (including imported/random audio) with no competing candidate to
/// create margin ambiguity. [`gate_auto_confirm_by_duration`] downgrades such
/// matches to `Suggest` so a human confirms them instead of silently enrolling.
pub const MIN_AUTO_CONFIRM_SPEECH_SECS: f64 = 5.0;

/// Apply the duration gate to an already-computed [`MatchSuggestion`].
///
/// If `suggestion` is `eligible` (`AutoConfirm`) but `cluster_speech_secs` is
/// below [`MIN_AUTO_CONFIRM_SPEECH_SECS`], downgrade it to `Suggest` —
/// the match may still be correct, it just isn't safe to auto-assign without
/// confirmation. Non-eligible suggestions pass through unchanged.
pub fn gate_auto_confirm_by_duration(
    suggestion: MatchSuggestion,
    cluster_speech_secs: f64,
) -> MatchSuggestion {
    if suggestion.eligible && cluster_speech_secs < MIN_AUTO_CONFIRM_SPEECH_SECS {
        return MatchSuggestion {
            tier: MatchTier::Suggest,
            eligible: false,
            reason: MatchReason::TooShortForAutoConfirm,
            ..suggestion
        };
    }
    suggestion
}

/// Greedily assign enrolled speakers to this meeting's voice clusters, ensuring
/// **one name per meeting**: the same enrolled speaker is never auto-assigned to
/// two different clusters in a single meeting.
///
/// `clusters` is a list of `(cluster_id, cluster_centroid)` — the distinct
/// voices detected in one meeting. For each cluster we compute the best enrolled
/// candidate; then we resolve conflicts greedily by descending score:
///
/// - The **highest-scoring** cluster for a given enrolled speaker wins that
///   name (if it would otherwise auto-confirm).
/// - Any other cluster that also matched the same speaker best is **demoted**:
///   it can no longer auto-confirm to that taken name and instead falls to
///   `Suggest` (if it still clears `suggest_threshold`) or `Anonymous`.
///
/// The returned `Vec` is **index-aligned with `clusters`** (result `i`
/// corresponds to `clusters[i]`). Pure; no mutation of inputs.
///
/// This is deliberately conservative: it only prevents **auto-confirm**
/// collisions. Weaker suggestions can still point at the same person, because
/// the user resolves those anyway (confirm-before-enroll).
pub fn assign_meeting_clusters(
    clusters: &[(String, Vec<f32>)],
    candidates: &[Candidate],
    cfg: &MatchConfig,
) -> Vec<MatchSuggestion> {
    // First pass: independent best-match per cluster.
    let mut suggestions: Vec<MatchSuggestion> = clusters
        .iter()
        .map(|(_, centroid)| match_embedding(centroid, candidates, cfg))
        .collect();

    // Resolve auto-confirm collisions: for each enrolled speaker id, keep only
    // the single highest-scoring auto-confirmed cluster; demote the rest.
    //
    // Build (cluster_index, score) lists per taken speaker id, but only for
    // clusters that are currently eligible (AutoConfirm).
    use std::collections::HashMap;
    let mut by_speaker: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, s) in suggestions.iter().enumerate() {
        if s.eligible {
            if let Some(id) = &s.speaker_id {
                by_speaker.entry(id.clone()).or_default().push(i);
            }
        }
    }

    for (_id, mut idxs) in by_speaker {
        if idxs.len() <= 1 {
            continue; // no collision
        }
        // Winner = highest score among the colliding clusters.
        idxs.sort_by(|&a, &b| {
            suggestions[b]
                .score
                .partial_cmp(&suggestions[a].score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        // Skip the winner (idxs[0]); demote the rest.
        for &loser in idxs.iter().skip(1) {
            let s = &suggestions[loser];
            // Re-classify the loser as if it could not take this name: it drops
            // to Suggest (still worth confirming) or Anonymous by threshold.
            let demoted = if s.score >= cfg.suggest_threshold {
                MatchSuggestion {
                    tier: MatchTier::Suggest,
                    eligible: false,
                    reason: MatchReason::AmbiguousMargin,
                    ..s.clone()
                }
            } else {
                MatchSuggestion {
                    tier: MatchTier::Anonymous,
                    eligible: false,
                    reason: MatchReason::BelowThreshold,
                    ..s.clone()
                }
            };
            suggestions[loser] = demoted;
        }
    }

    suggestions
}

/// Quality gate: should this embedding be folded into a profile centroid?
///
/// This is the "suspect-cluster guard" — we only let an embedding improve a
/// stored voiceprint when the segment is **long enough** and **clean enough**,
/// so noisy or cross-talk-contaminated snippets don't drift the centroid.
///
/// Current signals (both tunable via [`MatchConfig`]):
/// - `segment_duration_s >= cfg.min_enroll_duration_s` (default `3.0s`)
/// - `similarity_to_self >= cfg.min_enroll_self_similarity` (default `0.60`)
///
/// `similarity_to_self` is the cosine of this embedding against the cluster's
/// own centroid — a low value means the segment is an outlier within its own
/// cluster (likely overlap/noise) and should not be enrolled.
///
/// NOTE: real audio-quality signals (SNR, VAD confidence, overlap detection)
/// get wired in a later phase; today this is a simple, honest, tunable stub.
pub fn is_enrollable(similarity_to_self: f32, segment_duration_s: f32, cfg: &MatchConfig) -> bool {
    segment_duration_s >= cfg.min_enroll_duration_s
        && similarity_to_self >= cfg.min_enroll_self_similarity
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-5
    }

    // ---- cosine_similarity ---------------------------------------------

    #[test]
    fn cosine_identical_is_one() {
        let v = vec![1.0, 2.0, 3.0, 4.0];
        assert!(approx(cosine_similarity(&v, &v), 1.0));
    }

    #[test]
    fn cosine_orthogonal_is_zero() {
        let a = vec![1.0, 0.0];
        let b = vec![0.0, 1.0];
        assert!(approx(cosine_similarity(&a, &b), 0.0));
    }

    #[test]
    fn cosine_opposite_is_minus_one() {
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![-1.0, -2.0, -3.0];
        assert!(approx(cosine_similarity(&a, &b), -1.0));
    }

    #[test]
    fn cosine_length_mismatch_guard() {
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![1.0, 2.0];
        assert_eq!(cosine_similarity(&a, &b), 0.0);
    }

    #[test]
    fn cosine_zero_norm_guard() {
        let a = vec![0.0, 0.0, 0.0];
        let b = vec![1.0, 2.0, 3.0];
        assert_eq!(cosine_similarity(&a, &b), 0.0);
        assert_eq!(cosine_similarity(&b, &a), 0.0);
    }

    #[test]
    fn cosine_empty_guard() {
        let a: Vec<f32> = vec![];
        let b: Vec<f32> = vec![];
        assert_eq!(cosine_similarity(&a, &b), 0.0);
    }

    // ---- fold_centroid --------------------------------------------------

    #[test]
    fn fold_centroid_known_example() {
        // stored = [2, 4], n = 3, emb = [10, 0]
        // new = (stored*3 + emb) / 4 = ([6,12]+[10,0])/4 = [16,12]/4 = [4, 3]
        let stored = vec![2.0, 4.0];
        let emb = vec![10.0, 0.0];
        let out = fold_centroid(&stored, 3, &emb);
        assert!(approx(out[0], 4.0));
        assert!(approx(out[1], 3.0));
    }

    #[test]
    fn fold_centroid_first_sample() {
        // n = 0: new = (stored*0 + emb) / 1 = emb
        let stored = vec![9.0, 9.0];
        let emb = vec![1.0, 2.0];
        let out = fold_centroid(&stored, 0, &emb);
        assert!(approx(out[0], 1.0));
        assert!(approx(out[1], 2.0));
    }

    #[test]
    fn fold_centroid_empty_stored_takes_emb() {
        let out = fold_centroid(&[], 0, &[1.0, 2.0, 3.0]);
        assert_eq!(out, vec![1.0, 2.0, 3.0]);
    }

    #[test]
    fn fold_centroid_empty_emb_keeps_stored() {
        let stored = vec![1.0, 2.0];
        let out = fold_centroid(&stored, 5, &[]);
        assert_eq!(out, stored);
    }

    #[test]
    fn fold_centroid_length_mismatch_keeps_stored() {
        let stored = vec![1.0, 2.0, 3.0];
        let out = fold_centroid(&stored, 5, &[1.0, 2.0]);
        assert_eq!(out, stored);
    }

    // ---- fold_centroid_weighted ----------------------------------------

    fn norm(v: &[f32]) -> f32 {
        v.iter().map(|x| x * x).sum::<f32>().sqrt()
    }

    #[test]
    fn weighted_fold_empty_stored_takes_normalized_emb() {
        let out = fold_centroid_weighted(&[], 0.0, &[3.0, 4.0], 10.0);
        // normalized [3,4] = [0.6, 0.8]
        assert!(approx(out[0], 0.6));
        assert!(approx(out[1], 0.8));
    }

    #[test]
    fn weighted_fold_empty_emb_keeps_stored() {
        let stored = vec![1.0, 2.0];
        assert_eq!(fold_centroid_weighted(&stored, 100.0, &[], 5.0), stored);
    }

    #[test]
    fn weighted_fold_length_mismatch_keeps_stored() {
        let stored = vec![1.0, 2.0, 3.0];
        assert_eq!(fold_centroid_weighted(&stored, 100.0, &[1.0, 2.0], 5.0), stored);
    }

    #[test]
    fn weighted_fold_is_duration_weighted_and_unit() {
        // stored [1,0] weight 30s, new [0,1] weight 10s → ([30,0]+[0,10])/40 =
        // [0.75, 0.25] → normalized. Result is unit-length and closer to [1,0].
        let out = fold_centroid_weighted(&[1.0, 0.0], 30.0, &[0.0, 1.0], 10.0);
        assert!(approx(norm(&out), 1.0));
        assert!(out[0] > out[1], "weighted toward the longer stored side");
        assert!(approx(out[0], 0.94868));
        assert!(approx(out[1], 0.31623));
    }

    #[test]
    fn weighted_fold_caps_stored_weight_for_ema() {
        // A very mature voiceprint (10000s stored) should still move noticeably for
        // a 200s new cluster because W is capped at 600. With cap: weights 600 vs
        // 200 → new gets 25%. Without a cap it'd be ~2%.
        let out = fold_centroid_weighted(&[1.0, 0.0], 10_000.0, &[0.0, 1.0], 200.0);
        // y-component = 200/800 = 0.25 before normalize; strictly > the uncapped
        // 200/10200 ≈ 0.0196.
        assert!(out[1] > 0.2, "cap keeps a mature voiceprint adaptive, got {out:?}");
    }

    // ---- should_fold gate ----------------------------------------------

    #[test]
    fn should_fold_rejects_short_clusters() {
        let cfg = MatchConfig::default();
        assert!(should_fold(4.0, &[1.0, 0.0], 2, Some(0.9), &cfg).is_err());
        assert!(should_fold(5.0, &[1.0, 0.0], 2, Some(0.9), &cfg).is_ok());
    }

    #[test]
    fn should_fold_rejects_zero_or_empty_centroid() {
        let cfg = MatchConfig::default();
        assert!(should_fold(30.0, &[], 0, None, &cfg).is_err());
        assert!(should_fold(30.0, &[0.0, 0.0], 2, None, &cfg).is_err());
    }

    #[test]
    fn should_fold_rejects_dim_mismatch() {
        let cfg = MatchConfig::default();
        assert!(should_fold(30.0, &[1.0, 0.0], 3, None, &cfg).is_err());
        // stored_len 0 (brand-new) is allowed.
        assert!(should_fold(30.0, &[1.0, 0.0], 0, None, &cfg).is_ok());
    }

    #[test]
    fn should_fold_requires_auto_plus_margin_for_matches() {
        let cfg = MatchConfig::default(); // auto 0.70 + margin 0.08 = 0.78
        // A bare auto-confirm (0.72) is NOT strong enough to fold.
        assert!(should_fold(30.0, &[1.0, 0.0], 2, Some(0.72), &cfg).is_err());
        // 0.80 clears the bar.
        assert!(should_fold(30.0, &[1.0, 0.0], 2, Some(0.80), &cfg).is_ok());
        // Owner path (None) ignores the score gate.
        assert!(should_fold(30.0, &[1.0, 0.0], 2, None, &cfg).is_ok());
    }

    // ---- match_embedding tiers -----------------------------------------

    fn cand(id: &str, centroid: Vec<f32>) -> Candidate {
        Candidate {
            id: id.to_string(),
            name: format!("name-{id}"),
            centroid,
        }
    }

    /// Build a candidate whose cosine to `query` is exactly `target` by
    /// constructing a 2-D vector at the right angle. query is [1,0].
    fn cand_at_cosine(id: &str, target: f32) -> Candidate {
        // cosine([1,0],[x,y]) = x / sqrt(x^2+y^2). Choose x=target, then
        // y = sqrt(1-target^2) gives a unit vector with that cosine.
        let x = target;
        let y = (1.0 - target * target).max(0.0).sqrt();
        cand(id, vec![x, y])
    }

    #[test]
    fn match_empty_query_is_no_embedding() {
        let cands = vec![cand("a", vec![1.0, 0.0])];
        let r = match_embedding(&[], &cands, &MatchConfig::default());
        assert_eq!(r.reason, MatchReason::NoEmbedding);
        assert_eq!(r.tier, MatchTier::Anonymous);
        assert!(!r.eligible);
    }

    #[test]
    fn match_no_candidates_is_no_candidates() {
        let r = match_embedding(&[1.0, 0.0], &[], &MatchConfig::default());
        assert_eq!(r.reason, MatchReason::NoCandidates);
        assert!(!r.eligible);
    }

    #[test]
    fn match_auto_confirm_above_threshold_with_margin() {
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        // best ~0.80 (>= 0.70), runner-up ~0.50 → margin 0.30 >= 0.08.
        let cands = vec![
            cand_at_cosine("hi", 0.80),
            cand_at_cosine("lo", 0.50),
        ];
        let r = match_embedding(&query, &cands, &cfg);
        assert_eq!(r.tier, MatchTier::AutoConfirm);
        assert_eq!(r.reason, MatchReason::Matched);
        assert!(r.eligible);
        assert_eq!(r.speaker_id.as_deref(), Some("hi"));
        assert!(r.score > 0.79 && r.score < 0.81);
    }

    #[test]
    fn match_just_below_auto_threshold_is_suggest() {
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        // best 0.69 (< 0.70, >= 0.55) → Suggest/Matched, not eligible.
        let cands = vec![cand_at_cosine("a", 0.69)];
        let r = match_embedding(&query, &cands, &cfg);
        assert_eq!(r.tier, MatchTier::Suggest);
        assert_eq!(r.reason, MatchReason::Matched);
        assert!(!r.eligible);
    }

    #[test]
    fn match_just_above_auto_threshold_is_auto() {
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        // single candidate at 0.71, no runner-up → margin passes.
        let cands = vec![cand_at_cosine("a", 0.71)];
        let r = match_embedding(&query, &cands, &cfg);
        assert_eq!(r.tier, MatchTier::AutoConfirm);
        assert!(r.eligible);
    }

    #[test]
    fn match_above_threshold_but_ambiguous_margin_is_suggest() {
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        // best 0.75, runner-up 0.72 → margin 0.03 < 0.08 → ambiguous.
        let cands = vec![
            cand_at_cosine("a", 0.75),
            cand_at_cosine("b", 0.72),
        ];
        let r = match_embedding(&query, &cands, &cfg);
        assert_eq!(r.tier, MatchTier::Suggest);
        assert_eq!(r.reason, MatchReason::AmbiguousMargin);
        assert!(!r.eligible);
    }

    #[test]
    fn match_all_below_suggest_is_anonymous() {
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        let cands = vec![
            cand_at_cosine("a", 0.40),
            cand_at_cosine("b", 0.30),
        ];
        let r = match_embedding(&query, &cands, &cfg);
        assert_eq!(r.tier, MatchTier::Anonymous);
        assert_eq!(r.reason, MatchReason::BelowThreshold);
        assert!(!r.eligible);
    }

    #[test]
    fn match_exactly_at_auto_threshold_is_auto() {
        // Boundary: best == auto_threshold should auto-confirm (>=).
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        let cands = vec![cand_at_cosine("a", 0.70)];
        let r = match_embedding(&query, &cands, &cfg);
        assert_eq!(r.tier, MatchTier::AutoConfirm);
        assert!(r.eligible);
    }

    #[test]
    fn match_exactly_at_suggest_threshold_is_suggest() {
        // Boundary: best == suggest_threshold should suggest (>=), not anon.
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        let cands = vec![cand_at_cosine("a", 0.55)];
        let r = match_embedding(&query, &cands, &cfg);
        assert_eq!(r.tier, MatchTier::Suggest);
        assert!(!r.eligible);
    }

    // ---- assign_meeting_clusters ---------------------------------------

    #[test]
    fn assign_no_double_assign_demotes_weaker_cluster() {
        let cfg = MatchConfig::default();
        // One enrolled speaker "alice" at [1,0].
        let cands = vec![cand("alice", vec![1.0, 0.0])];
        // Two clusters both best-match alice, but with different strengths:
        //  - cluster0 cosine 0.95 (strong)
        //  - cluster1 cosine 0.85 (also auto-worthy alone)
        let clusters = vec![
            ("c0".to_string(), vec![0.95, (1.0f32 - 0.95 * 0.95).sqrt()]),
            ("c1".to_string(), vec![0.85, (1.0f32 - 0.85 * 0.85).sqrt()]),
        ];
        let out = assign_meeting_clusters(&clusters, &cands, &cfg);
        assert_eq!(out.len(), 2);
        // Winner: the stronger cluster keeps the auto-confirm.
        assert_eq!(out[0].tier, MatchTier::AutoConfirm);
        assert!(out[0].eligible);
        assert_eq!(out[0].speaker_id.as_deref(), Some("alice"));
        // Loser: demoted, no longer eligible, still points at alice as suggest.
        assert_eq!(out[1].tier, MatchTier::Suggest);
        assert!(!out[1].eligible);
        assert_eq!(out[1].reason, MatchReason::AmbiguousMargin);
    }

    #[test]
    fn assign_distinct_speakers_both_auto_confirm() {
        let cfg = MatchConfig::default();
        let cands = vec![
            cand("alice", vec![1.0, 0.0]),
            cand("bob", vec![0.0, 1.0]),
        ];
        let clusters = vec![
            ("c0".to_string(), vec![1.0, 0.0]),
            ("c1".to_string(), vec![0.0, 1.0]),
        ];
        let out = assign_meeting_clusters(&clusters, &cands, &cfg);
        assert_eq!(out[0].speaker_id.as_deref(), Some("alice"));
        assert!(out[0].eligible);
        assert_eq!(out[1].speaker_id.as_deref(), Some("bob"));
        assert!(out[1].eligible);
    }

    #[test]
    fn assign_index_aligned_with_clusters() {
        let cfg = MatchConfig::default();
        let cands = vec![cand("alice", vec![1.0, 0.0])];
        let clusters = vec![
            ("c0".to_string(), vec![0.1, 0.99]), // weak → anonymous
            ("c1".to_string(), vec![1.0, 0.0]),  // strong → auto
        ];
        let out = assign_meeting_clusters(&clusters, &cands, &cfg);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].tier, MatchTier::Anonymous);
        assert_eq!(out[1].tier, MatchTier::AutoConfirm);
    }

    // ---- gate_auto_confirm_by_duration -----------------------------------

    #[test]
    fn duration_gate_downgrades_short_auto_confirm() {
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        let cands = vec![cand_at_cosine("owner", 0.90)];
        let r = match_embedding(&query, &cands, &cfg);
        assert!(r.eligible); // would auto-confirm on score alone

        let gated = gate_auto_confirm_by_duration(r.clone(), 2.0);
        assert!(!gated.eligible);
        assert_eq!(gated.tier, MatchTier::Suggest);
        assert_eq!(gated.reason, MatchReason::TooShortForAutoConfirm);
        // Identity is preserved so the UI can still surface it as a suggestion.
        assert_eq!(gated.speaker_id.as_deref(), Some("owner"));
        assert_eq!(gated.score, r.score);
    }

    #[test]
    fn duration_gate_passes_long_auto_confirm() {
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        let cands = vec![cand_at_cosine("owner", 0.90)];
        let r = match_embedding(&query, &cands, &cfg);
        let gated = gate_auto_confirm_by_duration(r.clone(), MIN_AUTO_CONFIRM_SPEECH_SECS);
        assert_eq!(gated, r);
    }

    #[test]
    fn duration_gate_leaves_non_eligible_unchanged() {
        let cfg = MatchConfig::default();
        let query = vec![1.0, 0.0];
        let cands = vec![cand_at_cosine("a", 0.60)]; // Suggest tier, not eligible
        let r = match_embedding(&query, &cands, &cfg);
        assert!(!r.eligible);
        let gated = gate_auto_confirm_by_duration(r.clone(), 0.5);
        assert_eq!(gated, r);
    }

    // ---- is_enrollable --------------------------------------------------

    #[test]
    fn enrollable_requires_duration_and_quality() {
        let cfg = MatchConfig::default();
        // Both gates pass.
        assert!(is_enrollable(0.75, 4.0, &cfg));
        // Too short.
        assert!(!is_enrollable(0.75, 2.0, &cfg));
        // Too noisy (low self-similarity).
        assert!(!is_enrollable(0.40, 4.0, &cfg));
        // Boundary: exactly at both thresholds passes.
        assert!(is_enrollable(0.60, 3.0, &cfg));
    }
}
