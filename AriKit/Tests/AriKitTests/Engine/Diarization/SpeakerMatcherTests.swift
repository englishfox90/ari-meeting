//
//  SpeakerMatcherTests.swift — ← Rust `ari-engine/src/diarization/matching.rs` `#[cfg(test)]`
//  module (tests 26-55) + `speaker_match_suggestions_impl`
//  (`ari-engine/src/diarization/commands.rs:1361-1444`), ported (plan §5, D2).
//
import Testing
@testable import AriKit

@Suite("SpeakerMatcher")
struct SpeakerMatcherTests {
    private func approx(_ a: Float, _ b: Float) -> Bool {
        abs(a - b) < 1e-4
    }

    private func norm(_ v: [Float]) -> Float {
        v.reduce(Float(0.0)) { $0 + $1 * $1 }.squareRoot()
    }

    /// Build a 2-D unit vector whose cosine with `[1,0]` is exactly `target`.
    private func candAtCosine(_ id: SpeakerID, _ target: Float) -> (id: SpeakerID, centroid: [Float]) {
        let x = target
        let y = max(1.0 - target * target, 0.0).squareRoot()
        return (id, [x, y])
    }

    // ---- fold_centroid ----------------------------------------------------

    @Test
    func foldCentroidKnownExample() {
        // stored = [2, 4], n = 3, emb = [10, 0]
        // new = (stored*3 + emb) / 4 = ([6,12]+[10,0])/4 = [16,12]/4 = [4, 3]
        let out = SpeakerMatcher.foldCentroid(stored: [2.0, 4.0], samples: 3, new: [10.0, 0.0])
        #expect(approx(out[0], 4.0))
        #expect(approx(out[1], 3.0))
    }

    @Test
    func foldCentroidFirstSample() {
        let out = SpeakerMatcher.foldCentroid(stored: [9.0, 9.0], samples: 0, new: [1.0, 2.0])
        #expect(approx(out[0], 1.0))
        #expect(approx(out[1], 2.0))
    }

    @Test
    func foldCentroidEmptyStoredTakesEmb() {
        let out = SpeakerMatcher.foldCentroid(stored: [], samples: 0, new: [1.0, 2.0, 3.0])
        #expect(out == [1.0, 2.0, 3.0])
    }

    @Test
    func foldCentroidEmptyEmbKeepsStored() {
        let stored: [Float] = [1.0, 2.0]
        let out = SpeakerMatcher.foldCentroid(stored: stored, samples: 5, new: [])
        #expect(out == stored)
    }

    @Test
    func foldCentroidLengthMismatchKeepsStored() {
        let stored: [Float] = [1.0, 2.0, 3.0]
        let out = SpeakerMatcher.foldCentroid(stored: stored, samples: 5, new: [1.0, 2.0])
        #expect(out == stored)
    }

    // ---- fold_centroid_weighted --------------------------------------------

    @Test
    func weightedFoldEmptyStoredTakesNormalizedEmb() {
        let out = SpeakerMatcher.foldCentroidWeighted(stored: [], storedTotalSecs: 0.0, new: [3.0, 4.0], newSecs: 10.0)
        #expect(approx(out[0], 0.6))
        #expect(approx(out[1], 0.8))
    }

    @Test
    func weightedFoldEmptyEmbKeepsStored() {
        let stored: [Float] = [1.0, 2.0]
        let out = SpeakerMatcher.foldCentroidWeighted(stored: stored, storedTotalSecs: 100.0, new: [], newSecs: 5.0)
        #expect(out == stored)
    }

    @Test
    func weightedFoldLengthMismatchKeepsStored() {
        let stored: [Float] = [1.0, 2.0, 3.0]
        let out = SpeakerMatcher.foldCentroidWeighted(stored: stored, storedTotalSecs: 100.0, new: [1.0, 2.0], newSecs: 5.0)
        #expect(out == stored)
    }

    @Test
    func weightedFoldIsDurationWeightedAndUnit() {
        // stored [1,0] weight 30s, new [0,1] weight 10s → ([30,0]+[0,10])/40 = [0.75, 0.25] →
        // normalized. Result is unit-length and closer to [1,0].
        let out = SpeakerMatcher.foldCentroidWeighted(stored: [1.0, 0.0], storedTotalSecs: 30.0, new: [0.0, 1.0], newSecs: 10.0)
        #expect(approx(norm(out), 1.0))
        #expect(out[0] > out[1], "weighted toward the longer stored side")
        #expect(approx(out[0], 0.94868))
        #expect(approx(out[1], 0.31623))
    }

    @Test
    func weightedFoldCapsStoredWeightForEMA() {
        // A very mature voiceprint (10000s stored) should still move noticeably for a 200s new
        // cluster because W is capped at 600. With cap: weights 600 vs 200 → new gets 25%.
        // Without a cap it'd be ~2%.
        let out = SpeakerMatcher.foldCentroidWeighted(stored: [1.0, 0.0], storedTotalSecs: 10_000.0, new: [0.0, 1.0], newSecs: 200.0)
        #expect(out[1] > 0.2, "cap keeps a mature voiceprint adaptive, got \(out)")
    }

    // ---- should_fold gate --------------------------------------------------

    @Test
    func shouldFoldRejectsShortClusters() {
        let cfg = MatchConfig()
        #expect(!SpeakerMatcher.shouldFold(storedDim: 2, new: [1.0, 0.0], clusterSpeechSecs: 4.0, matchScore: 0.9, config: cfg))
        #expect(SpeakerMatcher.shouldFold(storedDim: 2, new: [1.0, 0.0], clusterSpeechSecs: 5.0, matchScore: 0.9, config: cfg))
    }

    @Test
    func shouldFoldRejectsZeroOrEmptyCentroid() {
        let cfg = MatchConfig()
        #expect(!SpeakerMatcher.shouldFold(storedDim: 0, new: [], clusterSpeechSecs: 30.0, matchScore: nil, config: cfg))
        #expect(!SpeakerMatcher.shouldFold(storedDim: 2, new: [0.0, 0.0], clusterSpeechSecs: 30.0, matchScore: nil, config: cfg))
    }

    @Test
    func shouldFoldRejectsDimMismatch() {
        let cfg = MatchConfig()
        #expect(!SpeakerMatcher.shouldFold(storedDim: 3, new: [1.0, 0.0], clusterSpeechSecs: 30.0, matchScore: nil, config: cfg))
        // stored_len 0 (brand-new) is allowed.
        #expect(SpeakerMatcher.shouldFold(storedDim: 0, new: [1.0, 0.0], clusterSpeechSecs: 30.0, matchScore: nil, config: cfg))
    }

    @Test
    func shouldFoldRequiresAutoPlusMarginForMatches() {
        let cfg = MatchConfig() // auto 0.70 + margin 0.08 = 0.78
        // A bare auto-confirm (0.72) is NOT strong enough to fold.
        #expect(!SpeakerMatcher.shouldFold(storedDim: 2, new: [1.0, 0.0], clusterSpeechSecs: 30.0, matchScore: 0.72, config: cfg))
        // 0.80 clears the bar.
        #expect(SpeakerMatcher.shouldFold(storedDim: 2, new: [1.0, 0.0], clusterSpeechSecs: 30.0, matchScore: 0.80, config: cfg))
        // Owner path (nil) ignores the score gate.
        #expect(SpeakerMatcher.shouldFold(storedDim: 2, new: [1.0, 0.0], clusterSpeechSecs: 30.0, matchScore: nil, config: cfg))
    }

    // ---- config defaults (invariant I9, ports tuning test 56) --------------

    @Test
    func matchConfigDefaultsAreTheParityValues() {
        let cfg = MatchConfig()
        #expect(cfg.autoThreshold == 0.70)
        #expect(cfg.suggestThreshold == 0.55)
        #expect(cfg.margin == 0.08)
        #expect(cfg.minEnrollDurationSecs == 3.0)
        #expect(cfg.minEnrollSelfSimilarity == 0.60)
        #expect(MatchConfig.minFoldSpeechSecs == 5.0)
        #expect(MatchConfig.foldWeightCapSecs == 600.0)
        #expect(MatchConfig.minAutoConfirmSpeechSecs == 5.0)
    }

    // ---- match tiers --------------------------------------------------------

    @Test
    func matchEmptyQueryIsNoEmbedding() {
        let cands = [candAtCosine("a", 1.0)]
        let r = SpeakerMatcher.match(embedding: [], candidates: cands, config: MatchConfig())
        #expect(r.reason == .noEmbedding)
        #expect(r.tier == .anonymous)
        #expect(!r.eligibleToFold)
    }

    @Test
    func matchNoCandidatesIsNoCandidates() {
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: [], config: MatchConfig())
        #expect(r.reason == .noCandidates)
        #expect(!r.eligibleToFold)
    }

    @Test
    func matchAutoConfirmAboveThresholdWithMargin() {
        let cfg = MatchConfig()
        let query: [Float] = [1.0, 0.0]
        // best ~0.80 (>= 0.70), runner-up ~0.50 → margin 0.30 >= 0.08.
        let cands = [candAtCosine("hi", 0.80), candAtCosine("lo", 0.50)]
        let r = SpeakerMatcher.match(embedding: query, candidates: cands, config: cfg)
        #expect(r.tier == .autoConfirm)
        #expect(r.reason == .matched)
        #expect(r.eligibleToFold)
        #expect(r.speakerId == "hi")
        #expect(r.score > 0.79 && r.score < 0.81)
    }

    @Test
    func matchJustBelowAutoThresholdIsSuggest() {
        let cfg = MatchConfig()
        let cands = [candAtCosine("a", 0.69)]
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        #expect(r.tier == .suggest)
        #expect(r.reason == .matched)
        #expect(!r.eligibleToFold)
    }

    @Test
    func matchJustAboveAutoThresholdIsAuto() {
        let cfg = MatchConfig()
        let cands = [candAtCosine("a", 0.71)]
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        #expect(r.tier == .autoConfirm)
        #expect(r.eligibleToFold)
    }

    @Test
    func matchAboveThresholdButAmbiguousMarginIsSuggest() {
        let cfg = MatchConfig()
        // best 0.75, runner-up 0.72 → margin 0.03 < 0.08 → ambiguous.
        let cands = [candAtCosine("a", 0.75), candAtCosine("b", 0.72)]
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        #expect(r.tier == .suggest)
        #expect(r.reason == .ambiguousMargin)
        #expect(!r.eligibleToFold)
    }

    @Test
    func matchAllBelowSuggestIsAnonymous() {
        let cfg = MatchConfig()
        let cands = [candAtCosine("a", 0.40), candAtCosine("b", 0.30)]
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        #expect(r.tier == .anonymous)
        #expect(r.reason == .belowThreshold)
        #expect(!r.eligibleToFold)
    }

    @Test
    func matchExactlyAtAutoThresholdIsAuto() {
        let cfg = MatchConfig()
        let cands = [candAtCosine("a", 0.70)]
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        #expect(r.tier == .autoConfirm)
        #expect(r.eligibleToFold)
    }

    @Test
    func matchExactlyAtSuggestThresholdIsSuggest() {
        let cfg = MatchConfig()
        let cands = [candAtCosine("a", 0.55)]
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        #expect(r.tier == .suggest)
        #expect(!r.eligibleToFold)
    }

    // ---- assignMeetingClusters ----------------------------------------------

    @Test
    func assignNoDoubleAssignDemotesWeakerCluster() {
        let cfg = MatchConfig()
        let alice: (id: SpeakerID, centroid: [Float]) = ("alice", [1.0, 0.0])
        // Two clusters both best-match alice, but with different strengths.
        let c0 = SpeakerMatcher.match(embedding: [0.95, (1.0 - 0.95 * 0.95 as Float).squareRoot()], candidates: [alice], config: cfg)
        let c1 = SpeakerMatcher.match(embedding: [0.85, (1.0 - 0.85 * 0.85 as Float).squareRoot()], candidates: [alice], config: cfg)
        let out = SpeakerMatcher.assignMeetingClusters([c0, c1], config: cfg)
        #expect(out.count == 2)
        // Winner: the stronger cluster keeps the auto-confirm.
        #expect(out[0].tier == .autoConfirm)
        #expect(out[0].eligibleToFold)
        #expect(out[0].speakerId == "alice")
        // Loser: demoted, no longer eligible, still points at alice as suggest.
        #expect(out[1].tier == .suggest)
        #expect(!out[1].eligibleToFold)
        #expect(out[1].reason == .ambiguousMargin)
    }

    @Test
    func assignDistinctSpeakersBothAutoConfirm() {
        let cfg = MatchConfig()
        let cands: [(id: SpeakerID, centroid: [Float])] = [("alice", [1.0, 0.0]), ("bob", [0.0, 1.0])]
        let c0 = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        let c1 = SpeakerMatcher.match(embedding: [0.0, 1.0], candidates: cands, config: cfg)
        let out = SpeakerMatcher.assignMeetingClusters([c0, c1], config: cfg)
        #expect(out[0].speakerId == "alice")
        #expect(out[0].eligibleToFold)
        #expect(out[1].speakerId == "bob")
        #expect(out[1].eligibleToFold)
    }

    @Test
    func assignIndexAlignedWithClusters() {
        let cfg = MatchConfig()
        let cands: [(id: SpeakerID, centroid: [Float])] = [("alice", [1.0, 0.0])]
        let c0 = SpeakerMatcher.match(embedding: [0.1, 0.99], candidates: cands, config: cfg) // weak → anonymous
        let c1 = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg) // strong → auto
        let out = SpeakerMatcher.assignMeetingClusters([c0, c1], config: cfg)
        #expect(out.count == 2)
        #expect(out[0].tier == .anonymous)
        #expect(out[1].tier == .autoConfirm)
    }

    // ---- gateAutoConfirmByDuration -------------------------------------------

    @Test
    func durationGateDowngradesShortAutoConfirm() {
        let cfg = MatchConfig()
        let cands = [candAtCosine("owner", 0.90)]
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        #expect(r.eligibleToFold) // would auto-confirm on score alone

        let gated = SpeakerMatcher.gateAutoConfirmByDuration(r, clusterSpeechSecs: 2.0, config: cfg)
        #expect(!gated.eligibleToFold)
        #expect(gated.tier == .suggest)
        #expect(gated.reason == .tooShortForAutoConfirm)
        // Identity is preserved so the UI can still surface it as a suggestion.
        #expect(gated.speakerId == "owner")
        #expect(gated.score == r.score)
    }

    @Test
    func durationGatePassesLongAutoConfirm() {
        let cfg = MatchConfig()
        let cands = [candAtCosine("owner", 0.90)]
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        let gated = SpeakerMatcher.gateAutoConfirmByDuration(r, clusterSpeechSecs: MatchConfig.minAutoConfirmSpeechSecs, config: cfg)
        #expect(gated == r)
    }

    @Test
    func durationGateLeavesNonEligibleUnchanged() {
        let cfg = MatchConfig()
        let cands = [candAtCosine("a", 0.60)] // Suggest tier, not eligible
        let r = SpeakerMatcher.match(embedding: [1.0, 0.0], candidates: cands, config: cfg)
        #expect(!r.eligibleToFold)
        let gated = SpeakerMatcher.gateAutoConfirmByDuration(r, clusterSpeechSecs: 0.5, config: cfg)
        #expect(gated == r)
    }

    // ---- isEnrollable ---------------------------------------------------------

    @Test
    func enrollableRequiresDurationAndQuality() {
        let cfg = MatchConfig()
        // Both gates pass.
        #expect(SpeakerMatcher.isEnrollable(segmentDurationSecs: 4.0, selfSimilarity: 0.75, config: cfg))
        // Too short.
        #expect(!SpeakerMatcher.isEnrollable(segmentDurationSecs: 2.0, selfSimilarity: 0.75, config: cfg))
        // Too noisy (low self-similarity).
        #expect(!SpeakerMatcher.isEnrollable(segmentDurationSecs: 4.0, selfSimilarity: 0.40, config: cfg))
        // Boundary: exactly at both thresholds passes.
        #expect(SpeakerMatcher.isEnrollable(segmentDurationSecs: 3.0, selfSimilarity: 0.60, config: cfg))
    }

    // ---- rankedSuggestions (← speaker_match_suggestions_impl) -----------------

    @Test
    func rankedSuggestionsDedupesByPersonKeepingBestScore() {
        // Two speaker rows for the same person; the higher-scoring one should win.
        let query: [Float] = [1.0, 0.0]
        let cands: [(id: SpeakerID, personId: PersonID, centroid: [Float])] = [
            ("s1", "nia", candAtCosine("s1", 0.5).centroid),
            ("s2", "nia", candAtCosine("s2", 0.9).centroid)
        ]
        let out = SpeakerMatcher.rankedSuggestions(embedding: query, candidates: cands)
        #expect(out.count == 1)
        #expect(out[0].personId == "nia")
        #expect(approx(out[0].score, 0.9))
    }

    @Test
    func rankedSuggestionsSortedDescendingAndCapped() {
        let query: [Float] = [1.0, 0.0]
        let cands: [(id: SpeakerID, personId: PersonID, centroid: [Float])] = [
            ("s1", "p1", candAtCosine("s1", 0.9).centroid),
            ("s2", "p2", candAtCosine("s2", 0.8).centroid),
            ("s3", "p3", candAtCosine("s3", 0.7).centroid),
            ("s4", "p4", candAtCosine("s4", 0.6).centroid),
            ("s5", "p5", candAtCosine("s5", 0.5).centroid),
            ("s6", "p6", candAtCosine("s6", 0.4).centroid)
        ]
        let out = SpeakerMatcher.rankedSuggestions(embedding: query, candidates: cands)
        #expect(out.count == 5, "top-5 cap")
        #expect(out.map(\.personId) == ["p1", "p2", "p3", "p4", "p5"])
        #expect(zip(out, out.dropFirst()).allSatisfy { $0.score >= $1.score })
    }

    @Test
    func rankedSuggestionsDropsNoiseBelowFloorButKeepsTopEvenIfWeak() {
        let query: [Float] = [1.0, 0.0]
        let cands: [(id: SpeakerID, personId: PersonID, centroid: [Float])] = [
            ("s1", "p1", candAtCosine("s1", 0.9).centroid),
            ("s2", "p2", candAtCosine("s2", 0.2).centroid) // below 0.3 noise floor
        ]
        let out = SpeakerMatcher.rankedSuggestions(embedding: query, candidates: cands)
        #expect(out.count == 1, "the sub-floor candidate is dropped, but the strong top match is kept")
        #expect(out[0].personId == "p1")
    }

    @Test
    func rankedSuggestionsClearsWhenLoneSurvivorIsPureNoise() {
        let query: [Float] = [1.0, 0.0]
        let cands: [(id: SpeakerID, personId: PersonID, centroid: [Float])] = [
            ("s1", "p1", candAtCosine("s1", 0.1).centroid)
        ]
        let out = SpeakerMatcher.rankedSuggestions(embedding: query, candidates: cands)
        #expect(out.isEmpty, "a lone noise-level candidate is surfaced as nothing, not a junk row")
    }

    @Test
    func rankedSuggestionsEmptyQueryOrCandidatesIsEmpty() {
        let cands: [(id: SpeakerID, personId: PersonID, centroid: [Float])] = [("s1", "p1", [1.0, 0.0])]
        #expect(SpeakerMatcher.rankedSuggestions(embedding: [], candidates: cands).isEmpty)
        #expect(SpeakerMatcher.rankedSuggestions(embedding: [1.0, 0.0], candidates: []).isEmpty)
    }
}
