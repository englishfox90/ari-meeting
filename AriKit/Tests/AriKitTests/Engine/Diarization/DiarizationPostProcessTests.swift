//
//  DiarizationPostProcessTests.swift — ← Rust `ari-engine/src/diarization/postprocess.rs`
//  `#[cfg(test)]` module, ported verbatim (plan §5, D1).
//
import Testing
@testable import AriKit

@Suite("DiarizationPostProcess")
struct DiarizationPostProcessTests {
    private func approx(_ a: Float, _ b: Float) -> Bool {
        abs(a - b) < 1e-4
    }

    /// Build a 2-D unit vector whose cosine with `[1,0]` is exactly `c`.
    private func atCosine(_ c: Float) -> [Float] {
        let x = c
        let y = max(1.0 - c * c, 0.0).squareRoot()
        return [x, y]
    }

    private func seg(_ start: Double, _ end: Double, _ spk: String) -> DiarizedSegment {
        DiarizedSegment(clusterKey: spk, startTime: start, endTime: end)
    }

    private func clus(_ spk: String, _ centroid: [Float]) -> DiarizationCluster {
        DiarizationCluster(key: spk, centroid: centroid, speechSecs: 0)
    }

    // ---- greedy post-merge -----------------------------------------------

    @Test
    func mergesTwoHighlySimilarClusters() {
        // Two clusters at cosine ~0.958 -> merge under default threshold 0.7.
        let a = atCosine(1.0) // [1,0]
        let b = atCosine(0.958)
        #expect(approx(SpeakerMath.cosineSimilarity(a, b), 0.958))

        let clusters = [clus("spk_0", a), clus("spk_1", b)]
        let segments = [seg(0.0, 30.0, "spk_0"), seg(30.0, 45.0, "spk_1")]
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: true)
        #expect(out.clusters.count == 1, "the two similar clusters merge into one")
        #expect(out.segments.count == 2)
        let rep = out.clusters[0].key
        #expect(out.segments.allSatisfy { $0.clusterKey == rep })
    }

    @Test
    func distinctClustersDoNotMerge() {
        // cosine ~0.25 (cross-speaker) -> stay separate.
        let a = atCosine(1.0)
        let b = atCosine(0.25)
        let clusters = [clus("spk_0", a), clus("spk_1", b)]
        let segments = [seg(0.0, 60.0, "spk_0"), seg(60.0, 120.0, "spk_1")]
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: true)
        #expect(out.clusters.count == 2)
        #expect(out.segments.count == 2)
    }

    @Test
    func mergeSkippedInForcedKMode() {
        // Same two similar clusters, but applyMerge=false -> no post-merge. Give both enough
        // speech to clear the floor so neither dissolves.
        let clusters = [clus("spk_0", atCosine(1.0)), clus("spk_1", atCosine(0.958))]
        let segments = [seg(0.0, 60.0, "spk_0"), seg(60.0, 120.0, "spk_1")]
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: false)
        #expect(out.clusters.count == 2, "forced-K skips the post-merge")
    }

    // ---- speech-time floor -------------------------------------------------

    @Test
    func floorDissolvesAndReassignsToNearCluster() {
        // Big cluster (100s) + tiny cluster (3s) that is close (cosine 0.9) -> tiny is dissolved
        // and its segments reassigned to the big one.
        let clusters = [clus("spk_0", atCosine(1.0)), clus("spk_1", atCosine(0.9))]
        let segments = [seg(0.0, 100.0, "spk_0"), seg(100.0, 103.0, "spk_1")] // 3s < floor(10)
        // No merge, so we isolate the floor behavior. (0.9 >= 0.7 would merge in auto mode;
        // test the floor path with applyMerge=false.)
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: false)
        #expect(out.clusters.count == 1, "tiny cluster dissolved")
        #expect(out.segments.count == 2, "reassigned segment kept")
        let rep = out.clusters[0].key
        #expect(out.segments.allSatisfy { $0.clusterKey == rep })
        #expect(rep == "spk_0")
    }

    @Test
    func floorDropsFarDissolvedCluster() {
        // Big cluster + tiny far cluster (cosine ~0.1 < 0.5) -> tiny dropped, its segment left
        // unlabeled (absent from output).
        let clusters = [clus("spk_0", atCosine(1.0)), clus("spk_1", atCosine(0.1))]
        let segments = [seg(0.0, 100.0, "spk_0"), seg(100.0, 104.0, "spk_1")] // 4s < floor(10), far
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: false)
        #expect(out.clusters.count == 1)
        #expect(out.segments.count == 1, "far tiny cluster's segment is dropped")
        #expect(out.segments[0].clusterKey == "spk_0")
    }

    @Test
    func fractionalFloorAppliesWhenLargerThanAbs() {
        // total speech = 1000s -> 2% floor = 20s > 10s abs. A 15s cluster is below the
        // fractional floor and dissolves.
        let clusters = [clus("spk_0", atCosine(1.0)), clus("spk_1", atCosine(0.05))] // far -> drops, not reassigns
        let segments = [seg(0.0, 985.0, "spk_0"), seg(985.0, 1000.0, "spk_1")] // 15s < 20s fractional floor
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: false)
        #expect(out.clusters.count == 1)
        #expect(out.segments.count == 1)
    }

    @Test
    func floorKeepsLargestWhenAllBelow() {
        // Two tiny clusters, both below the 10s abs floor -> guard keeps the largest rather than
        // dropping everything.
        let clusters = [clus("spk_0", atCosine(1.0)), clus("spk_1", atCosine(0.2))]
        let segments = [seg(0.0, 6.0, "spk_0"), seg(6.0, 9.0, "spk_1")]
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: false)
        #expect(out.clusters.count == 1, "largest cluster is kept")
        #expect(out.clusters[0].key == "spk_0")
        // spk_1 is far (cosine 0.2 < 0.5) -> its segment is dropped.
        #expect(out.segments.count == 1)
        #expect(out.segments[0].clusterKey == "spk_0")
    }

    // ---- degenerate / edge inputs -------------------------------------------

    @Test
    func emptyInputIsEmptyOutput() {
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: [], clusters: [], config: cfg, applyMerge: true)
        #expect(out.segments.isEmpty)
        #expect(out.clusters.isEmpty)
    }

    @Test
    func segmentsWithNoClustersPassThroughUntouched() {
        // No clusters at all -> segments returned as-is (caller skips them).
        let cfg = PostProcessConfig()
        let segments = [seg(0.0, 5.0, "spk_0")]
        let out = DiarizationPostProcess.run(segments: segments, clusters: [], config: cfg, applyMerge: true)
        #expect(out.segments == segments)
        #expect(out.clusters.isEmpty)
    }

    @Test
    func singleClusterSurvivesUnchanged() {
        let clusters = [clus("spk_0", atCosine(1.0))]
        let segments = [seg(0.0, 50.0, "spk_0")]
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: true)
        #expect(out.clusters.count == 1)
        #expect(out.clusters[0].key == "spk_0")
        #expect(out.clusters[0].centroid.count == 2)
        #expect(out.segments.count == 1)
    }

    @Test
    func mergeIsDurationWeightedTowardLargerCluster() {
        // Big cluster [1,0] (90s) + small cluster [0.8,0.6] (10s), merge_threshold low enough to
        // merge. Result direction should sit much closer to [1,0].
        let clusters = [clus("big", [1.0, 0.0]), clus("small", [0.8, 0.6])]
        let segments = [seg(0.0, 90.0, "big"), seg(90.0, 100.0, "small")]
        var cfg = PostProcessConfig()
        cfg.mergeThreshold = 0.5
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: true)
        #expect(out.clusters.count == 1)
        // Weighted mean = ([1,0]*90 + [0.8,0.6]*10)/100 = [0.98, 0.06] -> normalize.
        // x-component should dominate strongly (> 0.99 after normalize).
        let c = out.clusters[0].centroid
        #expect(c[0] > 0.99, "merged centroid dominated by big cluster, got \(c)")
        // Representative key follows the higher-duration member.
        #expect(out.clusters[0].key == "big")
    }

    // ---- maxClusters cap ---------------------------------------------------

    @Test
    func maxClustersCapsDistinctSurvivors() {
        // Four distinct, well-separated clusters (won't post-merge), each with ample speech
        // (all survive the floor). Cap of 2 forces two more merges of the closest pairs -> exactly
        // 2 survive, all segments kept.
        let clusters = [
            clus("spk_0", atCosine(1.0)),
            clus("spk_1", atCosine(0.6)),
            clus("spk_2", atCosine(0.2)),
            clus("spk_3", atCosine(-0.4))
        ]
        let segments = [
            seg(0.0, 40.0, "spk_0"),
            seg(40.0, 80.0, "spk_1"),
            seg(80.0, 120.0, "spk_2"),
            seg(120.0, 160.0, "spk_3")
        ]
        var cfg = PostProcessConfig()
        cfg.mergeThreshold = 0.7 // none of these pairs reach it
        cfg.maxClusters = 2
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: true)
        #expect(out.clusters.count == 2, "cap forces down to 2 survivors")
        #expect(out.segments.count == 4, "all segments kept, just remapped")
    }

    @Test
    func maxClustersNoopWhenUnderCap() {
        let clusters = [clus("spk_0", atCosine(1.0)), clus("spk_1", atCosine(0.2))]
        let segments = [seg(0.0, 60.0, "spk_0"), seg(60.0, 120.0, "spk_1")]
        var cfg = PostProcessConfig()
        cfg.maxClusters = 5
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: true)
        #expect(out.clusters.count == 2, "already under the cap -> unchanged")
    }

    @Test
    func maxClustersOneCollapsesToSingle() {
        let clusters = [
            clus("spk_0", atCosine(1.0)),
            clus("spk_1", atCosine(0.1)),
            clus("spk_2", atCosine(-0.5))
        ]
        let segments = [
            seg(0.0, 40.0, "spk_0"),
            seg(40.0, 80.0, "spk_1"),
            seg(80.0, 120.0, "spk_2")
        ]
        var cfg = PostProcessConfig()
        cfg.maxClusters = 1
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: true)
        #expect(out.clusters.count == 1)
        #expect(out.segments.count == 3)
    }

    @Test
    func threeWayMergeCollapsesSimilarGroup() {
        // Three near-identical clusters collapse to one; a fourth distinct one stays. All have
        // ample speech.
        let clusters = [
            clus("spk_0", atCosine(1.0)),
            clus("spk_1", atCosine(0.95)),
            clus("spk_2", atCosine(0.92)),
            clus("spk_3", atCosine(0.2))
        ]
        let segments = [
            seg(0.0, 30.0, "spk_0"),
            seg(30.0, 60.0, "spk_1"),
            seg(60.0, 90.0, "spk_2"),
            seg(90.0, 150.0, "spk_3")
        ]
        let cfg = PostProcessConfig()
        let out = DiarizationPostProcess.run(segments: segments, clusters: clusters, config: cfg, applyMerge: true)
        #expect(out.clusters.count == 2, "similar trio -> 1, distinct -> 1")
    }
}
