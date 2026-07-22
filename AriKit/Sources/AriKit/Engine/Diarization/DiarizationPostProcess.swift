//
//  DiarizationPostProcess.swift — diarization cluster post-processing (pure)
//  (← Rust `ari-engine/src/diarization/postprocess.rs`).
//
//  A pure, unit-tested cleanup stage that runs on the diarizer's raw output *before*
//  matching/enrollment/segment insertion. No DB, no IO, no async — a deterministic transform
//  over segments + per-cluster centroids.
//
//  Recipe:
//  1. Greedy post-merge — repeatedly merge the pair of clusters with the highest centroid
//     cosine >= `mergeThreshold` (default 0.7), combining centroids as a speech-duration-
//     weighted mean (re-L2-normalized). Segments follow their cluster.
//  2. Speech-time floor — dissolve clusters whose total speech is below
//     `max(floorAbsSecs, floorFrac * total speech)`. Each dissolved cluster's segments are
//     reassigned to the nearest surviving cluster if the centroid cosine >= `reassignMinCosine`,
//     else dropped (left unlabeled — identity is never invented).
//  3. Optional cap — the calendar attendee count is an UPPER BOUND, not a forced K: if more
//     clusters survive than `maxClusters`, the closest pairs are greedily merged (ignoring
//     `mergeThreshold`) until at most that many remain.
//
//  The post-merge is skipped in forced-K mode (`applyMerge: false`), where the caller already
//  pinned an exact cluster count; the floor still runs.
//

public struct PostProcessConfig: Sendable, Equatable {
    /// Greedy post-merge cutoff: two clusters merge while their centroid cosine is `>= this`.
    /// Higher = fewer merges. Default `0.7`.
    public var mergeThreshold: Float = 0.7
    /// Absolute floor (seconds) of speech a cluster must hold to survive. Default `10.0`.
    public var floorAbsSecs: Double = 10.0
    /// Fractional floor: a cluster must also hold `>= this * total speech`. The effective floor
    /// is `max(floorAbsSecs, floorFrac * total)`. Default `0.02`.
    public var floorFrac: Double = 0.02
    /// A dissolved cluster's segments are reassigned to the nearest surviving cluster only if
    /// the centroid cosine is `>= this`; otherwise they are dropped (left unlabeled).
    /// Default `0.5`.
    public var reassignMinCosine: Float = 0.5
    /// Optional hard cap on the number of surviving clusters (the calendar attendee count used
    /// as an upper bound, not a forced K). `nil` = no cap. The cap is the FULL attendee count
    /// (the owner is present in the mixed stream), never `attendees - 1`.
    public var maxClusters: Int?

    public init() {}
}

/// Internal working cluster: accumulates the merged centroid, total speech duration, and the
/// set of original cluster keys folded into it.
private struct Working {
    /// Canonical key surfaced downstream (kept from the highest-duration member).
    var rep: String
    var centroid: [Float]
    var duration: Double
    var members: [String]
}

public enum DiarizationPostProcess {
    /// Run the post-process pipeline. `applyMerge` gates step 1 (the greedy post-merge): pass
    /// `true` in auto mode, `false` in forced-K mode (where the count is already pinned). The
    /// floor (step 2) always runs.
    ///
    /// Pure: does not mutate its inputs. Segments whose cluster is dropped are omitted from the
    /// result; all others are returned with their key remapped to the canonical surviving
    /// cluster key.
    public static func run(
        segments: [DiarizedSegment],
        clusters: [DiarizationCluster],
        config: PostProcessConfig,
        applyMerge: Bool
    ) -> (segments: [DiarizedSegment], clusters: [DiarizationCluster]) {
        guard !clusters.isEmpty else {
            // Nothing to cluster against; return segments untouched (the caller skips those
            // that carry keys with no matching cluster).
            return (segments, [])
        }

        // Per-cluster total speech duration (sum of its segment lengths).
        var durationByKey: [String: Double] = [:]
        for s in segments {
            let d = max(s.endTime - s.startTime, 0.0)
            durationByKey[s.clusterKey, default: 0.0] += d
        }

        // Seed one working cluster per input cluster.
        var working: [Working] = clusters.map { c in
            Working(
                rep: c.key,
                centroid: c.centroid,
                duration: durationByKey[c.key] ?? 0.0,
                members: [c.key]
            )
        }

        // ---- Step 1: greedy duration-weighted post-merge ----
        if applyMerge {
            greedyMerge(&working, mergeThreshold: config.mergeThreshold)
        }

        // ---- Step 2: speech-time floor + reassign/drop ----
        let totalSpeech = working.reduce(0.0) { $0 + $1.duration }
        let floor = max(config.floorAbsSecs, config.floorFrac * totalSpeech)

        var survivors = working.filter { $0.duration >= floor }
        var dissolved = working.filter { $0.duration < floor }

        // Guard: never dissolve *every* cluster. If there is speech but nothing clears the
        // floor, keep the single largest cluster so at least one speaker survives (honest —
        // there is real speech).
        if survivors.isEmpty, !dissolved.isEmpty {
            let idx = maxDurationIndex(dissolved)
            let promoted = dissolved.remove(at: idx)
            survivors = [promoted]
        }

        // ---- Step 3 (optional): cap the surviving cluster count ----
        // The calendar attendee count is an UPPER BOUND, not a forced K: only if more clusters
        // survived than the cap do we keep greedily merging the closest pairs (ignoring
        // `mergeThreshold`) until we're at/under the cap. Runs after the floor so tiny clusters
        // are already gone, and before the key map is built so the extra merges' members are
        // picked up. Reassignment of dissolved clusters (below) then targets the final capped
        // survivors.
        if let cap = config.maxClusters {
            mergeToCap(&survivors, cap: max(cap, 1))
        }

        // Map every original cluster key -> its final canonical surviving key. A key absent from
        // the map is dropped (either its cluster was dropped outright, or it never had a
        // matching cluster entry — both cases skip the segment). Start with the survivors' own
        // members.
        var keyMap: [String: String] = [:]
        for w in survivors {
            for m in w.members {
                keyMap[m] = w.rep
            }
        }

        // Reassign each dissolved cluster to the nearest surviving centroid (if close enough),
        // else drop it (leave its members unmapped).
        for d in dissolved {
            guard let target = nearestSurviving(d.centroid, survivors: survivors, minCosine: config.reassignMinCosine) else {
                continue
            }
            let rep = survivors[target].rep
            for m in d.members {
                keyMap[m] = rep
            }
        }

        // Remap + filter segments.
        let outSegments: [DiarizedSegment] = segments.compactMap { s in
            guard let rep = keyMap[s.clusterKey] else { return nil }
            return DiarizedSegment(clusterKey: rep, startTime: s.startTime, endTime: s.endTime)
        }

        // Keep survivors ordered by their representative key for stable output.
        survivors.sort { $0.rep < $1.rep }
        let outClusters: [DiarizationCluster] = survivors.map { w in
            DiarizationCluster(key: w.rep, centroid: w.centroid, speechSecs: w.duration)
        }

        return (outSegments, outClusters)
    }

    /// Repeatedly merge the closest pair of working clusters while their centroid cosine is
    /// `>= mergeThreshold`. Duration-weighted centroid mean, re-L2-normalized after each merge.
    private static func greedyMerge(_ working: inout [Working], mergeThreshold: Float) {
        while working.count >= 2 {
            var best: (i: Int, j: Int, sim: Float)?
            for i in 0..<working.count {
                for j in (i + 1)..<working.count {
                    let sim = SpeakerMath.cosineSimilarity(working[i].centroid, working[j].centroid)
                    if sim >= mergeThreshold, best == nil || sim > best!.sim {
                        best = (i, j, sim)
                    }
                }
            }

            guard let (i, j, _) = best else { return }

            let cj = working.remove(at: j) // j > i, so i stays valid.
            let merged = SpeakerMath.weightedMean(working[i].centroid, working[i].duration, cj.centroid, cj.duration)
            working[i].centroid = SpeakerMath.l2Normalized(merged)
            if cj.duration > working[i].duration {
                working[i].rep = cj.rep
            }
            working[i].duration += cj.duration
            working[i].members.append(contentsOf: cj.members)
        }
    }

    /// Greedily merge the closest pair of working clusters until at most `cap` remain,
    /// **ignoring** the merge threshold (this is a hard cap, e.g. the calendar attendee count).
    /// Duration-weighted centroid mean, re-L2-normalized after each merge; the higher-duration
    /// member keeps the representative key.
    private static func mergeToCap(_ working: inout [Working], cap: Int) {
        while working.count > cap, working.count >= 2 {
            var best: (i: Int, j: Int, sim: Float)?
            for i in 0..<working.count {
                for j in (i + 1)..<working.count {
                    let sim = SpeakerMath.cosineSimilarity(working[i].centroid, working[j].centroid)
                    if best == nil || sim > best!.sim {
                        best = (i, j, sim)
                    }
                }
            }
            guard let (i, j, _) = best else { return }

            let cj = working.remove(at: j) // j > i, so i stays valid.
            let merged = SpeakerMath.weightedMean(working[i].centroid, working[i].duration, cj.centroid, cj.duration)
            working[i].centroid = SpeakerMath.l2Normalized(merged)
            if cj.duration > working[i].duration {
                working[i].rep = cj.rep
            }
            working[i].duration += cj.duration
            working[i].members.append(contentsOf: cj.members)
        }
    }

    /// Index of the max-duration working cluster (ties -> lowest index).
    private static func maxDurationIndex(_ items: [Working]) -> Int {
        var best = 0
        for (i, w) in items.enumerated() where w.duration > items[best].duration {
            best = i
        }
        return best
    }

    /// Index of the surviving cluster whose centroid is closest to `centroid`, if the best
    /// cosine is `>= minCosine`. Returns `nil` when nothing is close enough.
    private static func nearestSurviving(_ centroid: [Float], survivors: [Working], minCosine: Float) -> Int? {
        var best: (i: Int, sim: Float)?
        for (i, w) in survivors.enumerated() {
            let sim = SpeakerMath.cosineSimilarity(centroid, w.centroid)
            if best == nil || sim > best!.sim {
                best = (i, sim)
            }
        }
        guard let (i, sim) = best, sim >= minCosine else { return nil }
        return i
    }
}
