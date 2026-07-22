//
//  SpeakerMatcher.swift — dual-gate, three-tier voiceprint matcher (pure)
//  (← Rust `ari-engine/src/diarization/matching.rs`, plus `speaker_match_suggestions_impl`,
//  `ari-engine/src/diarization/commands.rs:1361-1444`).
//
//  Pure: no DB, no IO, no async. Every function is a deterministic transform over `[Float]`
//  embeddings/centroids and small tuples, which makes it trivially unit-testable. The
//  orchestration layer (D8) calls these functions and owns all persistence.
//
//  Speaker identity is represented as a voiceprint **centroid** — a running mean of the
//  embeddings observed for that speaker. Matching a fresh embedding against a set of enrolled
//  speakers is cosine similarity ranked descending, gated by (1) an absolute threshold and
//  (2) a margin over the runner-up. Only when both gates pass is a match eligible for
//  auto-assignment without user confirmation ("confirm-before-enroll"). Everything else is
//  surfaced as a suggestion the user must confirm, or left anonymous.
//

/// Which confidence tier a match landed in.
public enum MatchTier: Sendable, Equatable {
    /// Best `>= autoThreshold` **and** beats runner-up by `>= margin`. Safe to auto-assign
    /// without user confirmation.
    case autoConfirm
    /// Best in `[suggestThreshold, autoThreshold)`, or `>= autoThreshold` but the margin over
    /// the runner-up is too small (ambiguous). Surfaced to the user to confirm.
    case suggest
    /// Best `< suggestThreshold` (or nothing to match against). Leave the speaker anonymous.
    case anonymous
}

/// Why the matcher produced the tier/decision it did.
public enum MatchReason: Sendable, Equatable {
    /// A confident, unambiguous match at/above `autoThreshold`.
    case matched
    /// Top match cleared a threshold but did not beat the runner-up by `margin` — ambiguous,
    /// so not auto-assigned.
    case ambiguousMargin
    /// Top match fell below `suggestThreshold`.
    case belowThreshold
    /// Otherwise-eligible match was downgraded because the cluster's total speech was below
    /// `MatchConfig.minAutoConfirmSpeechSecs` — too short/noisy to trust without confirmation.
    case tooShortForAutoConfirm
    /// The query embedding was empty/zero-length (nothing to compare).
    case noEmbedding
    /// There were no candidates to compare against.
    case noCandidates
}

/// The result of matching one query embedding against a candidate set.
public struct MatchDecision: Sendable, Equatable {
    public var tier: MatchTier
    public var reason: MatchReason
    /// The matched speaker id, if any candidate was the top match. Present for all tiers
    /// where a best candidate exists; only `eligibleToFold` gates auto-assignment.
    public var speakerId: SpeakerID?
    /// Cosine of the best candidate (`0.0` when there was nothing to match).
    public var score: Float
    /// `true` **only** for `autoConfirm` — i.e. safe to auto-assign without user confirmation.
    public var eligibleToFold: Bool

    public init(tier: MatchTier, reason: MatchReason, speakerId: SpeakerID?, score: Float, eligibleToFold: Bool) {
        self.tier = tier
        self.reason = reason
        self.speakerId = speakerId
        self.score = score
        self.eligibleToFold = eligibleToFold
    }

    fileprivate static func empty(_ reason: MatchReason) -> MatchDecision {
        MatchDecision(tier: .anonymous, reason: reason, speakerId: nil, score: 0.0, eligibleToFold: false)
    }
}

public enum SpeakerMatcher {
    /// Match a single query embedding against a set of enrolled candidates. Computes cosine to
    /// every candidate, ranks descending, then applies the dual-gate three-tier logic.
    public static func match(
        embedding: [Float],
        candidates: [(id: SpeakerID, centroid: [Float])],
        config: MatchConfig
    ) -> MatchDecision {
        if embedding.isEmpty {
            return .empty(.noEmbedding)
        }
        if candidates.isEmpty {
            return .empty(.noCandidates)
        }

        var scored: [(id: SpeakerID, score: Float)] = candidates.map { candidate in
            (candidate.id, SpeakerMath.cosineSimilarity(embedding, candidate.centroid))
        }
        // Stable sort descending by score; input order preserved on ties.
        scored = scored.enumerated()
            .sorted { a, b in
                if a.element.score != b.element.score { return a.element.score > b.element.score }
                return a.offset < b.offset
            }
            .map(\.element)

        let best = scored[0]
        let runnerUp = scored.count > 1 ? scored[1].score : nil

        return classify(bestId: best.id, bestScore: best.score, runnerUp: runnerUp, config: config)
    }

    /// Core tier classification shared by `match` and `assignMeetingClusters`.
    private static func classify(
        bestId: SpeakerID?,
        bestScore: Float,
        runnerUp: Float?,
        config: MatchConfig
    ) -> MatchDecision {
        let marginOK: Bool
        if let runnerUp {
            marginOK = (bestScore - runnerUp) >= config.margin
        } else {
            marginOK = true
        }

        let tier: MatchTier
        let reason: MatchReason
        let eligible: Bool
        if bestScore < config.suggestThreshold {
            (tier, reason, eligible) = (.anonymous, .belowThreshold, false)
        } else if bestScore >= config.autoThreshold, marginOK {
            (tier, reason, eligible) = (.autoConfirm, .matched, true)
        } else if bestScore >= config.autoThreshold {
            (tier, reason, eligible) = (.suggest, .ambiguousMargin, false)
        } else {
            (tier, reason, eligible) = (.suggest, .matched, false)
        }

        return MatchDecision(tier: tier, reason: reason, speakerId: bestId, score: bestScore, eligibleToFold: eligible)
    }

    /// Apply the duration gate to an already-computed `MatchDecision`. If `decision` is
    /// `eligibleToFold` (`autoConfirm`) but `clusterSpeechSecs` is below
    /// `MatchConfig.minAutoConfirmSpeechSecs`, downgrade it to `suggest` — the match may still
    /// be correct, it just isn't safe to auto-assign without confirmation. Non-eligible
    /// decisions pass through unchanged.
    public static func gateAutoConfirmByDuration(
        _ decision: MatchDecision,
        clusterSpeechSecs: Double,
        config: MatchConfig
    ) -> MatchDecision {
        guard decision.eligibleToFold, clusterSpeechSecs < MatchConfig.minAutoConfirmSpeechSecs else {
            return decision
        }
        var gated = decision
        gated.tier = .suggest
        gated.eligibleToFold = false
        gated.reason = .tooShortForAutoConfirm
        return gated
    }

    /// Greedily resolve **one name per meeting**: given the independently-computed best match
    /// per cluster (index-aligned with the meeting's clusters), demote every collision but the
    /// highest-scoring cluster for a given enrolled speaker so the same enrolled speaker is
    /// never auto-confirmed to two different clusters in a single meeting. Pure; does not
    /// mutate its input; returns a new, index-aligned array.
    public static func assignMeetingClusters(
        _ decisions: [MatchDecision],
        config: MatchConfig
    ) -> [MatchDecision] {
        var bySpeaker: [SpeakerID: [Int]] = [:]
        for (i, d) in decisions.enumerated() where d.eligibleToFold {
            if let id = d.speakerId {
                bySpeaker[id, default: []].append(i)
            }
        }

        var out = decisions
        for (_, indices) in bySpeaker {
            guard indices.count > 1 else { continue }
            let sorted = indices.sorted { out[$0].score > out[$1].score }
            for loser in sorted.dropFirst() {
                let s = out[loser]
                if s.score >= config.suggestThreshold {
                    out[loser] = MatchDecision(
                        tier: .suggest,
                        reason: .ambiguousMargin,
                        speakerId: s.speakerId,
                        score: s.score,
                        eligibleToFold: false
                    )
                } else {
                    out[loser] = MatchDecision(
                        tier: .anonymous,
                        reason: .belowThreshold,
                        speakerId: s.speakerId,
                        score: s.score,
                        eligibleToFold: false
                    )
                }
            }
        }
        return out
    }

    /// Fold a new embedding into a stored centroid using a running mean:
    /// `new_centroid = (stored * samples + new) / (samples + 1)`. `samples` is the number of
    /// embeddings already averaged into `stored`.
    ///
    /// Guards: empty `stored` -> a copy of `new` (brand-new speaker); empty `new`, or a length
    /// mismatch (both non-empty) -> a copy of `stored` unchanged.
    public static func foldCentroid(stored: [Float], samples: Int, new: [Float]) -> [Float] {
        if stored.isEmpty {
            return new
        }
        if new.isEmpty || stored.count != new.count {
            return stored
        }

        let n = Float(samples)
        let denom = n + 1.0
        return zip(stored, new).map { s, e in (s * n + e) / denom }
    }

    /// Duration-weighted fold of a new cluster centroid into a stored voiceprint, then
    /// re-L2-normalized: `new = (stored * W + new * w) / (W + w)`, where
    /// `W = min(storedTotalSecs, foldWeightCapSecs)` and `w = newSecs`.
    ///
    /// Guards (mirror `foldCentroid`): empty `stored` -> L2-normalized `new` (brand-new
    /// voiceprint); empty `new`, or a length mismatch -> `stored` unchanged; non-positive
    /// total weight -> falls back to an equal-weight mean.
    public static func foldCentroidWeighted(
        stored: [Float],
        storedTotalSecs: Double,
        new: [Float],
        newSecs: Double
    ) -> [Float] {
        if stored.isEmpty {
            return SpeakerMath.l2Normalized(new)
        }
        if new.isEmpty || stored.count != new.count {
            return stored
        }

        let bigW = min(max(storedTotalSecs, 0.0), MatchConfig.foldWeightCapSecs)
        let smallW = max(newSecs, 0.0)
        let (weightBig, weightSmall): (Double, Double) = (bigW + smallW <= 0.0) ? (1.0, 1.0) : (bigW, smallW)

        let denom = Float(weightBig + weightSmall)
        let merged = zip(stored, new).map { s, e in
            (s * Float(weightBig) + e * Float(weightSmall)) / denom
        }
        return SpeakerMath.l2Normalized(merged)
    }

    /// Quality gate for a duration-weighted fold (P1): decide whether a matched (or owner)
    /// cluster is trustworthy enough to update a stored voiceprint. When it returns `false`
    /// the caller keeps the match/assignment but skips the fold, so a noisy cluster never
    /// drifts a good voiceprint.
    ///
    /// Gates: `clusterSpeechSecs >= MatchConfig.minFoldSpeechSecs`; `new` non-empty and not
    /// all-zero; if `storedDim != 0`, dimensions match `new`; `matchScore`, when non-`nil`, is
    /// `>= autoThreshold + margin` — i.e. only an unambiguously strong auto-confirm folds.
    /// Pass `nil` for the owner path (owner enrollment is not a cross-speaker match).
    public static func shouldFold(
        storedDim: Int,
        new: [Float],
        clusterSpeechSecs: Double,
        matchScore: Float?,
        config: MatchConfig
    ) -> Bool {
        if clusterSpeechSecs < MatchConfig.minFoldSpeechSecs {
            return false
        }
        if new.isEmpty || new.allSatisfy({ $0 == 0.0 }) {
            return false
        }
        if storedDim != 0, storedDim != new.count {
            return false
        }
        if let matchScore, matchScore < config.autoThreshold + config.margin {
            return false
        }
        return true
    }

    /// Quality gate: should this embedding be folded into a profile centroid? The
    /// "suspect-cluster guard" — an embedding only improves a stored voiceprint when the
    /// segment is long enough and clean enough, so noisy or cross-talk-contaminated snippets
    /// don't drift the centroid. `selfSimilarity` is the cosine of this embedding against the
    /// cluster's own centroid — a low value means the segment is an outlier within its own
    /// cluster (likely overlap/noise) and should not be enrolled.
    public static func isEnrollable(segmentDurationSecs: Float, selfSimilarity: Float, config: MatchConfig) -> Bool {
        segmentDurationSecs >= config.minEnrollDurationSecs && selfSimilarity >= config.minEnrollSelfSimilarity
    }

    /// Rank the enrolled people whose voiceprints most resemble `embedding` — the candidate
    /// list for the assign dialog (← Rust `speaker_match_suggestions_impl`,
    /// `commands.rs:1361-1444`). Honest: never fabricates entries; returns an empty array when
    /// `embedding` is empty or there are no candidates.
    ///
    /// One person may own several enrolled speaker rows; results are deduped by person,
    /// keeping each person's best score. Weak matches (`score < noiseFloor`) are dropped as
    /// noise, but the single best candidate is always kept if any exist — unless that lone
    /// survivor is itself pure noise, in which case nothing is surfaced rather than a junk row.
    /// Sorted by descending similarity, capped at `limit`.
    public static func rankedSuggestions(
        embedding: [Float],
        candidates: [(id: SpeakerID, personId: PersonID, centroid: [Float])],
        limit: Int = 5,
        noiseFloor: Float = 0.3
    ) -> [(personId: PersonID, score: Float)] {
        guard !embedding.isEmpty, !candidates.isEmpty else { return [] }

        var bestByPerson: [PersonID: Float] = [:]
        for candidate in candidates {
            let score = SpeakerMath.cosineSimilarity(embedding, candidate.centroid)
            if let existing = bestByPerson[candidate.personId] {
                if score > existing { bestByPerson[candidate.personId] = score }
            } else {
                bestByPerson[candidate.personId] = score
            }
        }

        let ranked = bestByPerson.sorted { $0.value > $1.value }

        var suggestions: [(personId: PersonID, score: Float)] = ranked.enumerated()
            .filter { index, entry in index == 0 || entry.value >= noiseFloor }
            .prefix(limit)
            .map { _, entry in (entry.key, entry.value) }

        if suggestions.count == 1, suggestions[0].score < noiseFloor {
            suggestions.removeAll()
        }

        return suggestions
    }
}
