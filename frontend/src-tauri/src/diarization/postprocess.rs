//! # Diarization cluster post-processing (pure)
//!
//! A **pure**, unit-tested cleanup stage that runs on the sidecar's raw
//! diarization output *before* matching / enrollment / segment insertion. Like
//! [`crate::diarization::matching`] it has **no DB, no I/O, no async, no Tauri**
//! — it is a deterministic transform over segments + per-cluster centroids, so
//! it is trivially testable.
//!
//! ## Why this exists (empirical basis)
//!
//! sherpa-onnx's fast-clustering fragments real meeting audio badly: a real 1:1
//! reported **44** clusters at threshold 0.5 and **11** even at 0.9; a 43-minute
//! team meeting reported **138**. The CAM++ embeddings themselves separate the
//! voices near-perfectly (within-speaker centroid cosine up to **0.958**,
//! cross-speaker ~**0.25**) — so the fix is app-side, not a model swap.
//!
//! The validated recipe (correct counts on real recordings: 2 on the 1:1, 5 on
//! the team meeting) is:
//!
//! 1. **Greedy post-merge** — repeatedly merge the pair of clusters with the
//!    highest centroid cosine ≥ `merge_threshold` (default `0.7`), combining
//!    their centroids as a **speech-duration-weighted mean** (re-L2-normalized).
//!    Segments follow their cluster.
//! 2. **Speech-time floor** — dissolve clusters whose total speech is below
//!    `max(floor_abs_secs=10, floor_frac=0.02 × total speech)`. Each dissolved
//!    cluster's segments are reassigned to the nearest surviving cluster if the
//!    centroid cosine ≥ `reassign_min_cosine` (0.5), else dropped (left
//!    unlabeled — we never invent identity).
//!
//! The post-merge is skipped in forced-K mode (Fixed / Calendar speaker counts),
//! where the caller already pinned an exact cluster count; the floor still runs.

use std::collections::HashMap;

use super::matching::cosine_similarity;

/// Tunable knobs for [`postprocess`]. Defaults are the empirically-validated
/// recipe; `merge_threshold` / `floor_abs_secs` / `floor_frac` are overridable
/// from the runtime tuning file (see [`crate::diarization::tuning`]).
#[derive(Debug, Clone, PartialEq)]
pub struct PostProcessConfig {
    /// Greedy post-merge cutoff: two clusters merge while their centroid cosine
    /// is `>= this`. Higher = fewer merges. Default `0.7`.
    pub merge_threshold: f32,
    /// Absolute floor (seconds) of speech a cluster must hold to survive.
    /// Default `10.0`.
    pub floor_abs_secs: f64,
    /// Fractional floor: a cluster must also hold `>= this × total speech`.
    /// The effective floor is `max(floor_abs_secs, floor_frac × total)`.
    /// Default `0.02`.
    pub floor_frac: f64,
    /// A dissolved cluster's segments are reassigned to the nearest surviving
    /// cluster only if the centroid cosine is `>= this`; otherwise they are
    /// dropped (left unlabeled). Default `0.5`.
    pub reassign_min_cosine: f32,
    /// Optional hard cap on the number of surviving clusters (P1 — the calendar
    /// attendee count used as an **upper bound**, not a forced K). After the
    /// threshold post-merge + floor, if more than this many clusters survive, the
    /// closest centroid pairs are greedily merged (ignoring `merge_threshold`)
    /// until at most this many remain. `None` = no cap. The cap is the FULL
    /// attendee count (the owner is present in the mixed stream), never
    /// `attendees − 1`.
    pub max_clusters: Option<usize>,
}

impl Default for PostProcessConfig {
    fn default() -> Self {
        Self {
            merge_threshold: 0.7,
            floor_abs_secs: 10.0,
            floor_frac: 0.02,
            reassign_min_cosine: 0.5,
            max_clusters: None,
        }
    }
}

/// One diarized span (input). `speaker` is the sidecar's per-file cluster key
/// (e.g. `"spk_0"`).
#[derive(Debug, Clone, PartialEq)]
pub struct Seg {
    pub start: f64,
    pub end: f64,
    pub speaker: String,
}

/// A per-cluster centroid (input): the sidecar's L2-normalized mean CAM++
/// embedding for one cluster key.
#[derive(Debug, Clone, PartialEq)]
pub struct ClusterIn {
    pub speaker: String,
    pub centroid: Vec<f32>,
}

/// A surviving cluster (output): its canonical key + merged centroid + dim.
#[derive(Debug, Clone, PartialEq)]
pub struct ClusterOut {
    pub speaker: String,
    pub dim: i64,
    pub centroid: Vec<f32>,
}

/// The result of post-processing: surviving clusters (merged centroids) plus the
/// segments that belong to them, with `speaker` keys remapped to the canonical
/// surviving key. Dropped segments are absent.
#[derive(Debug, Clone, PartialEq)]
pub struct PostProcessResult {
    pub segments: Vec<Seg>,
    pub clusters: Vec<ClusterOut>,
}

/// Internal working cluster: accumulates the merged centroid, total speech
/// duration, and the set of original cluster keys folded into it.
#[derive(Debug, Clone)]
struct Working {
    /// Canonical key surfaced downstream (kept from the highest-duration member).
    rep: String,
    centroid: Vec<f32>,
    duration: f64,
    members: Vec<String>,
}

/// Run the post-process pipeline. `apply_merge` gates step 1 (the greedy
/// post-merge): pass `true` in auto mode, `false` in forced-K mode (where the
/// count is already pinned). The floor (step 2) always runs.
///
/// Pure: does not mutate its inputs. Segments whose cluster is dropped are
/// omitted from the result; all others are returned with their `speaker` key
/// remapped to the canonical surviving cluster key.
pub fn postprocess(
    segments: &[Seg],
    clusters: &[ClusterIn],
    cfg: &PostProcessConfig,
    apply_merge: bool,
) -> PostProcessResult {
    if clusters.is_empty() {
        // Nothing to cluster against; return segments untouched (they carry keys
        // with no matching cluster — the caller skips those).
        return PostProcessResult {
            segments: segments.to_vec(),
            clusters: Vec::new(),
        };
    }

    // Per-cluster total speech duration (sum of its segment lengths).
    let mut duration_by_key: HashMap<String, f64> = HashMap::new();
    for s in segments {
        let d = (s.end - s.start).max(0.0);
        *duration_by_key.entry(s.speaker.clone()).or_insert(0.0) += d;
    }

    // Seed one working cluster per input cluster.
    let mut working: Vec<Working> = clusters
        .iter()
        .map(|c| Working {
            rep: c.speaker.clone(),
            centroid: c.centroid.clone(),
            duration: *duration_by_key.get(&c.speaker).unwrap_or(&0.0),
            members: vec![c.speaker.clone()],
        })
        .collect();

    // ---- Step 1: greedy duration-weighted post-merge ----
    if apply_merge {
        greedy_merge(&mut working, cfg.merge_threshold);
    }

    // ---- Step 2: speech-time floor + reassign/drop ----
    let total_speech: f64 = working.iter().map(|w| w.duration).sum();
    let floor = cfg.floor_abs_secs.max(cfg.floor_frac * total_speech);

    let (survivors, dissolved): (Vec<Working>, Vec<Working>) =
        working.into_iter().partition(|w| w.duration >= floor);

    // Guard: never dissolve *every* cluster. If there is speech but nothing
    // clears the floor, keep the single largest cluster so at least one speaker
    // survives (honest — there is real speech).
    let (mut survivors, dissolved) = if survivors.is_empty() && !dissolved.is_empty() {
        let mut d = dissolved;
        // Move the max-duration dissolved cluster into survivors.
        let idx = max_duration_index(&d);
        let promoted = d.remove(idx);
        (vec![promoted], d)
    } else {
        (survivors, dissolved)
    };

    // ---- Step 3 (optional): cap the surviving cluster count ----
    // The calendar attendee count is an UPPER BOUND, not a forced K: only if more
    // clusters survived than the cap do we keep greedily merging the closest pairs
    // (ignoring `merge_threshold`) until we're at/under the cap. Runs after the
    // floor so tiny clusters are already gone, and before key_map is built so the
    // extra merges' members are picked up. Reassignment of dissolved clusters
    // (below) then targets the final capped survivors.
    if let Some(cap) = cfg.max_clusters {
        let cap = cap.max(1);
        merge_to_cap(&mut survivors, cap);
    }

    // Map every original cluster key → its final canonical surviving key (or
    // None = dropped). Start with the survivors' own members.
    let mut key_map: HashMap<String, Option<String>> = HashMap::new();
    for w in &survivors {
        for m in &w.members {
            key_map.insert(m.clone(), Some(w.rep.clone()));
        }
    }

    // Reassign each dissolved cluster to the nearest surviving centroid (if close
    // enough), else drop it.
    for d in &dissolved {
        let target = nearest_surviving(&d.centroid, &survivors, cfg.reassign_min_cosine);
        let mapped = target.map(|i| survivors[i].rep.clone());
        for m in &d.members {
            key_map.insert(m.clone(), mapped.clone());
        }
    }

    // Remap + filter segments.
    let out_segments: Vec<Seg> = segments
        .iter()
        .filter_map(|s| match key_map.get(&s.speaker) {
            Some(Some(rep)) => Some(Seg {
                start: s.start,
                end: s.end,
                speaker: rep.clone(),
            }),
            // Dropped cluster, or a segment whose key had no cluster entry.
            _ => None,
        })
        .collect();

    // Keep survivors ordered by their representative key for stable output.
    survivors.sort_by(|a, b| a.rep.cmp(&b.rep));
    let out_clusters: Vec<ClusterOut> = survivors
        .into_iter()
        .map(|w| ClusterOut {
            dim: w.centroid.len() as i64,
            speaker: w.rep,
            centroid: w.centroid,
        })
        .collect();

    PostProcessResult {
        segments: out_segments,
        clusters: out_clusters,
    }
}

/// Repeatedly merge the closest pair of working clusters while their centroid
/// cosine is `>= merge_threshold`. Duration-weighted centroid mean, re-L2-
/// normalized after each merge.
fn greedy_merge(working: &mut Vec<Working>, merge_threshold: f32) {
    loop {
        if working.len() < 2 {
            return;
        }

        // Find the closest pair (i < j) above threshold.
        let mut best: Option<(usize, usize, f32)> = None;
        for i in 0..working.len() {
            for j in (i + 1)..working.len() {
                let sim = cosine_similarity(&working[i].centroid, &working[j].centroid);
                if sim >= merge_threshold && best.map(|(_, _, b)| sim > b).unwrap_or(true) {
                    best = Some((i, j, sim));
                }
            }
        }

        let Some((i, j, _)) = best else {
            return; // no pair above threshold — done.
        };

        // Merge j into i (weighted mean, re-normalize). Remove j.
        let cj = working.remove(j); // j > i, so i stays valid.
        let wi = &mut working[i];
        let merged = weighted_mean(&wi.centroid, wi.duration, &cj.centroid, cj.duration);
        wi.centroid = l2_normalize(merged);
        // Keep the higher-duration member's key as the representative.
        if cj.duration > wi.duration {
            wi.rep = cj.rep.clone();
        }
        wi.duration += cj.duration;
        wi.members.extend(cj.members);
    }
}

/// Greedily merge the closest pair of working clusters until at most `cap` remain,
/// **ignoring** the merge threshold (this is a hard cap, e.g. the calendar attendee
/// count). Duration-weighted centroid mean, re-L2-normalized after each merge; the
/// higher-duration member keeps the representative key.
fn merge_to_cap(working: &mut Vec<Working>, cap: usize) {
    while working.len() > cap && working.len() >= 2 {
        // Find the single closest pair (i < j) by centroid cosine.
        let mut best: Option<(usize, usize, f32)> = None;
        for i in 0..working.len() {
            for j in (i + 1)..working.len() {
                let sim = cosine_similarity(&working[i].centroid, &working[j].centroid);
                if best.map(|(_, _, b)| sim > b).unwrap_or(true) {
                    best = Some((i, j, sim));
                }
            }
        }
        let Some((i, j, _)) = best else { return };

        let cj = working.remove(j); // j > i, so i stays valid.
        let wi = &mut working[i];
        let merged = weighted_mean(&wi.centroid, wi.duration, &cj.centroid, cj.duration);
        wi.centroid = l2_normalize(merged);
        if cj.duration > wi.duration {
            wi.rep = cj.rep.clone();
        }
        wi.duration += cj.duration;
        wi.members.extend(cj.members);
    }
}

/// Duration-weighted element-wise mean of two equal-length centroids.
/// If either weight is non-positive it degrades to a plain mean; length
/// mismatch returns `a` unchanged (defensive — should not happen in practice).
fn weighted_mean(a: &[f32], wa: f64, b: &[f32], wb: f64) -> Vec<f32> {
    if a.len() != b.len() || a.is_empty() {
        return a.to_vec();
    }
    let (wa, wb) = if wa <= 0.0 && wb <= 0.0 {
        (1.0, 1.0) // both zero-duration → equal weight
    } else {
        (wa.max(0.0), wb.max(0.0))
    };
    let denom = (wa + wb) as f32;
    a.iter()
        .zip(b.iter())
        .map(|(&x, &y)| (x * wa as f32 + y * wb as f32) / denom)
        .collect()
}

/// L2-normalize a vector (returns a new owned vector). A zero-norm input is
/// returned unchanged (still zero) so downstream cosine reads it as no-match.
fn l2_normalize(mut v: Vec<f32>) -> Vec<f32> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > f32::EPSILON {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
    v
}

/// Index of the max-duration working cluster (ties → lowest index).
fn max_duration_index(items: &[Working]) -> usize {
    let mut best = 0usize;
    for (i, w) in items.iter().enumerate() {
        if w.duration > items[best].duration {
            best = i;
        }
    }
    best
}

/// Index of the surviving cluster whose centroid is closest to `centroid`, if the
/// best cosine is `>= min_cosine`. Returns `None` when nothing is close enough.
fn nearest_surviving(centroid: &[f32], survivors: &[Working], min_cosine: f32) -> Option<usize> {
    let mut best: Option<(usize, f32)> = None;
    for (i, w) in survivors.iter().enumerate() {
        let sim = cosine_similarity(centroid, &w.centroid);
        if best.map(|(_, b)| sim > b).unwrap_or(true) {
            best = Some((i, sim));
        }
    }
    match best {
        Some((i, sim)) if sim >= min_cosine => Some(i),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-4
    }

    /// Build a 2-D unit vector whose cosine with `[1,0]` is exactly `c`.
    fn at_cosine(c: f32) -> Vec<f32> {
        let x = c;
        let y = (1.0 - c * c).max(0.0).sqrt();
        vec![x, y]
    }

    fn seg(start: f64, end: f64, spk: &str) -> Seg {
        Seg {
            start,
            end,
            speaker: spk.to_string(),
        }
    }

    fn clus(spk: &str, centroid: Vec<f32>) -> ClusterIn {
        ClusterIn {
            speaker: spk.to_string(),
            centroid,
        }
    }

    // ---- weighted_mean / l2_normalize ----------------------------------

    #[test]
    fn weighted_mean_duration_weighted() {
        // a=[1,0] weight 3, b=[0,1] weight 1 → ([3,0]+[0,1])/4 = [0.75,0.25].
        let m = weighted_mean(&[1.0, 0.0], 3.0, &[0.0, 1.0], 1.0);
        assert!(approx(m[0], 0.75));
        assert!(approx(m[1], 0.25));
    }

    #[test]
    fn weighted_mean_then_normalize_is_unit() {
        let m = weighted_mean(&[1.0, 0.0], 3.0, &[0.0, 1.0], 1.0);
        let n = l2_normalize(m);
        let norm = (n[0] * n[0] + n[1] * n[1]).sqrt();
        assert!(approx(norm, 1.0));
        // Direction: [0.75,0.25] normalized = [0.9487, 0.3162].
        assert!(approx(n[0], 0.94868));
        assert!(approx(n[1], 0.31623));
    }

    #[test]
    fn weighted_mean_zero_durations_equal_weight() {
        let m = weighted_mean(&[2.0, 0.0], 0.0, &[0.0, 2.0], 0.0);
        assert!(approx(m[0], 1.0));
        assert!(approx(m[1], 1.0));
    }

    #[test]
    fn l2_normalize_zero_stays_zero() {
        assert_eq!(l2_normalize(vec![0.0, 0.0]), vec![0.0, 0.0]);
    }

    // ---- greedy post-merge ---------------------------------------------

    #[test]
    fn merges_two_highly_similar_clusters() {
        // Two clusters at cosine ~0.958 → merge under default threshold 0.7.
        let a = at_cosine(1.0); // [1,0]
        let b = at_cosine(0.958);
        // sanity: their cosine really is ~0.958
        assert!(approx(cosine_similarity(&a, &b), 0.958));

        let clusters = vec![clus("spk_0", a), clus("spk_1", b)];
        let segments = vec![
            seg(0.0, 30.0, "spk_0"),
            seg(30.0, 45.0, "spk_1"),
        ];
        let cfg = PostProcessConfig::default();
        let out = postprocess(&segments, &clusters, &cfg, true);
        assert_eq!(out.clusters.len(), 1, "the two similar clusters merge into one");
        // All segments survive, remapped to the single surviving key.
        assert_eq!(out.segments.len(), 2);
        let rep = &out.clusters[0].speaker;
        assert!(out.segments.iter().all(|s| &s.speaker == rep));
    }

    #[test]
    fn distinct_clusters_do_not_merge() {
        // cosine ~0.25 (cross-speaker) → stay separate.
        let a = at_cosine(1.0);
        let b = at_cosine(0.25);
        let clusters = vec![clus("spk_0", a), clus("spk_1", b)];
        let segments = vec![
            seg(0.0, 60.0, "spk_0"),
            seg(60.0, 120.0, "spk_1"),
        ];
        let cfg = PostProcessConfig::default();
        let out = postprocess(&segments, &clusters, &cfg, true);
        assert_eq!(out.clusters.len(), 2);
        assert_eq!(out.segments.len(), 2);
    }

    #[test]
    fn merge_skipped_in_forced_k_mode() {
        // Same two similar clusters, but apply_merge=false → no post-merge.
        // Give both enough speech to clear the floor so neither dissolves.
        let clusters = vec![clus("spk_0", at_cosine(1.0)), clus("spk_1", at_cosine(0.958))];
        let segments = vec![
            seg(0.0, 60.0, "spk_0"),
            seg(60.0, 120.0, "spk_1"),
        ];
        let cfg = PostProcessConfig::default();
        let out = postprocess(&segments, &clusters, &cfg, false);
        assert_eq!(out.clusters.len(), 2, "forced-K skips the post-merge");
    }

    // ---- speech-time floor ---------------------------------------------

    #[test]
    fn floor_dissolves_and_reassigns_to_near_cluster() {
        // Big cluster (100s) + tiny cluster (3s) that is close (cosine 0.9) →
        // tiny is dissolved and its segments reassigned to the big one.
        let clusters = vec![
            clus("spk_0", at_cosine(1.0)),
            clus("spk_1", at_cosine(0.9)),
        ];
        let segments = vec![
            seg(0.0, 100.0, "spk_0"),
            seg(100.0, 103.0, "spk_1"), // 3s < floor(10)
        ];
        // No merge, so we isolate the floor behavior. (0.9 >= 0.7 would merge in
        // auto mode; test the floor path with apply_merge=false.)
        let cfg = PostProcessConfig::default();
        let out = postprocess(&segments, &clusters, &cfg, false);
        assert_eq!(out.clusters.len(), 1, "tiny cluster dissolved");
        assert_eq!(out.segments.len(), 2, "reassigned segment kept");
        let rep = &out.clusters[0].speaker;
        assert!(out.segments.iter().all(|s| &s.speaker == rep));
        assert_eq!(rep, "spk_0");
    }

    #[test]
    fn floor_drops_far_dissolved_cluster() {
        // Big cluster + tiny far cluster (cosine ~0.1 < 0.5) → tiny dropped,
        // its segment left unlabeled (absent from output).
        let clusters = vec![
            clus("spk_0", at_cosine(1.0)),
            clus("spk_1", at_cosine(0.1)),
        ];
        let segments = vec![
            seg(0.0, 100.0, "spk_0"),
            seg(100.0, 104.0, "spk_1"), // 4s < floor(10), far away
        ];
        let cfg = PostProcessConfig::default();
        let out = postprocess(&segments, &clusters, &cfg, false);
        assert_eq!(out.clusters.len(), 1);
        assert_eq!(out.segments.len(), 1, "far tiny cluster's segment is dropped");
        assert_eq!(out.segments[0].speaker, "spk_0");
    }

    #[test]
    fn fractional_floor_applies_when_larger_than_abs() {
        // total speech = 1000s → 2% floor = 20s > 10s abs. A 15s cluster is below
        // the fractional floor and dissolves; a 12s one would survive the abs
        // floor but not the fractional one.
        let clusters = vec![
            clus("spk_0", at_cosine(1.0)),
            clus("spk_1", at_cosine(0.05)), // far → will drop, not reassign
        ];
        let segments = vec![
            seg(0.0, 985.0, "spk_0"),   // 985s
            seg(985.0, 1000.0, "spk_1"), // 15s < 20s fractional floor
        ];
        let cfg = PostProcessConfig::default();
        let out = postprocess(&segments, &clusters, &cfg, false);
        assert_eq!(out.clusters.len(), 1);
        assert_eq!(out.segments.len(), 1);
    }

    #[test]
    fn floor_keeps_largest_when_all_below() {
        // Two tiny clusters, both below the 10s abs floor → guard keeps the
        // largest rather than dropping everything.
        let clusters = vec![
            clus("spk_0", at_cosine(1.0)),
            clus("spk_1", at_cosine(0.2)),
        ];
        let segments = vec![
            seg(0.0, 6.0, "spk_0"),  // 6s
            seg(6.0, 9.0, "spk_1"),  // 3s
        ];
        let cfg = PostProcessConfig::default();
        let out = postprocess(&segments, &clusters, &cfg, false);
        assert_eq!(out.clusters.len(), 1, "largest cluster is kept");
        assert_eq!(out.clusters[0].speaker, "spk_0");
        // spk_1 is far (cosine 0.2 < 0.5) → its segment is dropped.
        assert_eq!(out.segments.len(), 1);
        assert_eq!(out.segments[0].speaker, "spk_0");
    }

    // ---- degenerate / edge inputs --------------------------------------

    #[test]
    fn empty_input_is_empty_output() {
        let cfg = PostProcessConfig::default();
        let out = postprocess(&[], &[], &cfg, true);
        assert!(out.segments.is_empty());
        assert!(out.clusters.is_empty());
    }

    #[test]
    fn segments_with_no_clusters_pass_through_untouched() {
        // No clusters at all → segments returned as-is (caller skips them).
        let cfg = PostProcessConfig::default();
        let segments = vec![seg(0.0, 5.0, "spk_0")];
        let out = postprocess(&segments, &[], &cfg, true);
        assert_eq!(out.segments, segments);
        assert!(out.clusters.is_empty());
    }

    #[test]
    fn single_cluster_survives_unchanged() {
        let clusters = vec![clus("spk_0", at_cosine(1.0))];
        let segments = vec![seg(0.0, 50.0, "spk_0")];
        let cfg = PostProcessConfig::default();
        let out = postprocess(&segments, &clusters, &cfg, true);
        assert_eq!(out.clusters.len(), 1);
        assert_eq!(out.clusters[0].speaker, "spk_0");
        assert_eq!(out.clusters[0].dim, 2);
        assert_eq!(out.segments.len(), 1);
    }

    #[test]
    fn merge_is_duration_weighted_toward_larger_cluster() {
        // Big cluster [1,0] (90s) + small cluster [0.8,0.6] (10s), merge_threshold
        // low enough to merge. Result direction should sit much closer to [1,0].
        let clusters = vec![
            clus("big", vec![1.0, 0.0]),
            clus("small", vec![0.8, 0.6]),
        ];
        let segments = vec![
            seg(0.0, 90.0, "big"),
            seg(90.0, 100.0, "small"),
        ];
        let cfg = PostProcessConfig {
            merge_threshold: 0.5,
            ..PostProcessConfig::default()
        };
        let out = postprocess(&segments, &clusters, &cfg, true);
        assert_eq!(out.clusters.len(), 1);
        // Weighted mean = ([1,0]*90 + [0.8,0.6]*10)/100 = [0.98, 0.06] → normalize.
        // x-component should dominate strongly (> 0.99 after normalize).
        let c = &out.clusters[0].centroid;
        assert!(c[0] > 0.99, "merged centroid dominated by big cluster, got {c:?}");
        // Representative key follows the higher-duration member.
        assert_eq!(out.clusters[0].speaker, "big");
    }

    // ---- max_clusters cap ----------------------------------------------

    #[test]
    fn max_clusters_caps_distinct_survivors() {
        // Four distinct, well-separated clusters (won't post-merge), each with
        // ample speech (all survive the floor). Cap of 2 forces two more merges of
        // the closest pairs → exactly 2 survive, all segments kept.
        let clusters = vec![
            clus("spk_0", at_cosine(1.0)),
            clus("spk_1", at_cosine(0.6)),
            clus("spk_2", at_cosine(0.2)),
            clus("spk_3", at_cosine(-0.4)),
        ];
        let segments = vec![
            seg(0.0, 40.0, "spk_0"),
            seg(40.0, 80.0, "spk_1"),
            seg(80.0, 120.0, "spk_2"),
            seg(120.0, 160.0, "spk_3"),
        ];
        let cfg = PostProcessConfig {
            merge_threshold: 0.7, // none of these pairs reach it
            max_clusters: Some(2),
            ..PostProcessConfig::default()
        };
        let out = postprocess(&segments, &clusters, &cfg, true);
        assert_eq!(out.clusters.len(), 2, "cap forces down to 2 survivors");
        assert_eq!(out.segments.len(), 4, "all segments kept, just remapped");
    }

    #[test]
    fn max_clusters_noop_when_under_cap() {
        let clusters = vec![clus("spk_0", at_cosine(1.0)), clus("spk_1", at_cosine(0.2))];
        let segments = vec![seg(0.0, 60.0, "spk_0"), seg(60.0, 120.0, "spk_1")];
        let cfg = PostProcessConfig {
            max_clusters: Some(5),
            ..PostProcessConfig::default()
        };
        let out = postprocess(&segments, &clusters, &cfg, true);
        assert_eq!(out.clusters.len(), 2, "already under the cap → unchanged");
    }

    #[test]
    fn max_clusters_one_collapses_to_single() {
        let clusters = vec![
            clus("spk_0", at_cosine(1.0)),
            clus("spk_1", at_cosine(0.1)),
            clus("spk_2", at_cosine(-0.5)),
        ];
        let segments = vec![
            seg(0.0, 40.0, "spk_0"),
            seg(40.0, 80.0, "spk_1"),
            seg(80.0, 120.0, "spk_2"),
        ];
        let cfg = PostProcessConfig {
            max_clusters: Some(1),
            ..PostProcessConfig::default()
        };
        let out = postprocess(&segments, &clusters, &cfg, true);
        assert_eq!(out.clusters.len(), 1);
        assert_eq!(out.segments.len(), 3);
    }

    #[test]
    fn three_way_merge_collapses_similar_group() {
        // Three near-identical clusters collapse to one; a fourth distinct one
        // stays. All have ample speech.
        let clusters = vec![
            clus("spk_0", at_cosine(1.0)),
            clus("spk_1", at_cosine(0.95)),
            clus("spk_2", at_cosine(0.92)),
            clus("spk_3", at_cosine(0.2)),
        ];
        let segments = vec![
            seg(0.0, 30.0, "spk_0"),
            seg(30.0, 60.0, "spk_1"),
            seg(60.0, 90.0, "spk_2"),
            seg(90.0, 150.0, "spk_3"),
        ];
        let cfg = PostProcessConfig::default();
        let out = postprocess(&segments, &clusters, &cfg, true);
        assert_eq!(out.clusters.len(), 2, "similar trio → 1, distinct → 1");
    }
}
