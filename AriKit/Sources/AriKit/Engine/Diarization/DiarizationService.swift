//
//  DiarizationService.swift — full offline diarization orchestration (plan §2.7, §5 D8; ←
//  Rust `ari-engine/src/diarization/commands.rs` `diarize_meeting_impl`/`run_diarization`
//  (192-360), `persist_clusters` (671-828), `speaker_assign_to_person_impl`/`merge_speaker_into`
//  (1103-1229)).
//
//  The orchestration layer: it composes the pure modules (`DiarizationPostProcess`,
//  `SpeakerMatcher`, `TranscriptStamper`) with a `DiarizationProvider` + `DiarizationAudioLoading`
//  backend and owns ALL persistence for one meeting's diarization run, exclusively through
//  `AppDatabase` repositories (invariant I5 — no raw SQLite here, no second DB owner).
//
//  Scope note (plan §1 non-goals, §9 R6): unlike the Rust incumbent's separate mic/system-track
//  handling (owner-track auto-enrollment + in-room speaker detection), this port targets a
//  single mixed-track file per meeting — split-track capture and the owner-mic-track enrollment
//  free win are explicitly out of scope for this plan. Every persisted segment is stamped
//  `source: .system` (R6): the stamper's system-preference rule stays dormant-but-correct for a
//  future split-track slice; owner identification happens via ordinary voiceprint matching, not
//  track origin.
//
//  `DiarizationService` is an `actor`: it serializes runs per process and owns no UI state. All
//  heavy work happens off the main actor inside the injected provider/loader's `async` calls;
//  this actor adds no threading of its own around them (plan §4).
//
import Foundation

/// The phases a `DiarizationService.run` progresses through, for honest UI progress reporting
/// (plan §6 — never a fake indeterminate bar over invented steps).
public enum DiarizationPhase: Sendable {
    case preparingModels
    case decodingAudio
    case diarizing
    case matching
    case stamping
}

public actor DiarizationService {
    private let database: AppDatabase
    private let provider: any DiarizationProvider
    private let audioLoader: any DiarizationAudioLoading
    private let matchConfig: MatchConfig
    private let postProcessConfig: PostProcessConfig

    public init(
        database: AppDatabase,
        provider: any DiarizationProvider,
        audioLoader: any DiarizationAudioLoading,
        matchConfig: MatchConfig = .init(),
        postProcessConfig: PostProcessConfig = .init()
    ) {
        self.database = database
        self.provider = provider
        self.audioLoader = audioLoader
        self.matchConfig = matchConfig
        self.postProcessConfig = postProcessConfig
    }

    /// One resolved speaker for a completed run: the persisted (matched or new-provisional)
    /// speaker, and the match decision that produced it — honest tier/score, never fabricated.
    public struct ResolvedSpeaker: Sendable, Equatable {
        public var speakerId: SpeakerID
        public var tier: MatchTier
        public var score: Float
        public var speechSecs: Double

        public init(speakerId: SpeakerID, tier: MatchTier, score: Float, speechSecs: Double) {
            self.speakerId = speakerId
            self.tier = tier
            self.score = score
            self.speechSecs = speechSecs
        }
    }

    /// Honest counts of what one `run` did — every field is a real total of what actually
    /// happened, nothing invented (mirrors Rust's `DiarizeMeetingSummary`).
    public struct RunResult: Sendable, Equatable {
        public var stampedRows: Int
        public var unresolvedRows: Int
        public var speakers: [ResolvedSpeaker]

        public init(stampedRows: Int, unresolvedRows: Int, speakers: [ResolvedSpeaker]) {
            self.stampedRows = stampedRows
            self.unresolvedRows = unresolvedRows
            self.speakers = speakers
        }
    }

    /// Full offline pipeline for one meeting. **Idempotent**: first clears the meeting's prior
    /// diarization (un-stamps transcripts, deletes its `speakerSegment` rows, tombstones now-
    /// orphaned provisional speakers) so re-runs never double-fold centroids or duplicate rows.
    /// Confirmed/owner voiceprints are never touched by the clear (folds are irreversible; they
    /// are the cross-meeting match pool).
    ///
    /// `hint` MUST NOT be `.automatic` — throws `DiarizationError.hintRequired` (invariant I4;
    /// `.automatic` exists only for the eval rig, plan §2.2).
    ///
    /// Sequence (parity-L3/L4 — pinned order, `commands.rs:192-360,700,728`): idempotency clear
    /// → `provider.prepare()` → `audioLoader.load16kMono` → `provider.diarize(hint:)` →
    /// `DiarizationPostProcess.run` (merge skipped under `.exact`; capped under `.upperBound`) →
    /// match each surviving cluster against confirmed/owner voiceprints in the same
    /// `embeddingModel` space → `assignMeetingClusters` FIRST, then `gateAutoConfirmByDuration`
    /// per cluster (reversing this order changes which cluster wins a same-meeting collision) →
    /// for each eligible auto-confirm cluster that clears `shouldFold`: duration-weighted fold +
    /// participant link; everything else becomes a fresh provisional speaker (confirm-before-
    /// enroll, invariant I1) → persist `Speaker`/`SpeakerSegment` rows → `TranscriptStamper` →
    /// batch transcript stamps → `RunResult`. All writes via repositories only (invariant I5).
    public func run(
        meetingId: MeetingID,
        audioURL: URL,
        hint: SpeakerCountHint,
        progress: (@Sendable (DiarizationPhase, Double) -> Void)? = nil
    ) async throws -> RunResult {
        guard hint != .automatic else {
            throw DiarizationError.hintRequired
        }

        // Idempotency guard — FATAL on failure (parity-L6, unlike Rust's best-effort/logged
        // clear): a failed clear before a re-run risks duplicate segment/stamp rows, which is
        // worse than refusing to proceed.
        _ = try await database.speakers.clearMeetingDiarization(meetingId)

        progress?(.preparingModels, 0.0)
        try await provider.prepare()
        progress?(.preparingModels, 1.0)

        progress?(.decodingAudio, 0.0)
        let samples = try await audioLoader.load16kMono(from: audioURL)
        progress?(.decodingAudio, 1.0)

        let output = try await provider.diarize(samples: samples, hint: hint) { fraction in
            progress?(.diarizing, fraction)
        }

        // applyMerge is false in forced-K (.exact) mode — counts already pinned; the floor still
        // runs. .upperBound passes its N through as the post-process cap (parity-L4:
        // `commands.rs:282-285` — .exact never caps).
        var ppConfig = postProcessConfig
        let applyMerge: Bool
        switch hint {
        case .exact:
            applyMerge = false
            ppConfig.maxClusters = nil
        case let .upperBound(n):
            applyMerge = true
            ppConfig.maxClusters = n
        case .automatic:
            // Unreachable — rejected above.
            applyMerge = true
        }
        let postProcessed = DiarizationPostProcess.run(
            segments: output.segments, clusters: output.clusters, config: ppConfig, applyMerge: applyMerge
        )

        progress?(.matching, 0.0)
        let now = Date()
        let candidateSpeakers = try await database.speakers.matchCandidates(embeddingModel: provider.embeddingModel)
        let candidates = candidateSpeakers.map { (id: $0.id, centroid: CentroidCodec.vector(from: $0.centroid)) }

        var decisions = postProcessed.clusters.map { cluster in
            SpeakerMatcher.match(embedding: cluster.centroid, candidates: candidates, config: matchConfig)
        }
        // Pinned order (parity-L3): resolve one-name-per-meeting collisions FIRST, then gate by
        // cluster duration — reversing this changes which cluster wins a collision.
        decisions = SpeakerMatcher.assignMeetingClusters(decisions, config: matchConfig)
        decisions = zip(decisions, postProcessed.clusters).map { decision, cluster in
            SpeakerMatcher.gateAutoConfirmByDuration(decision, clusterSpeechSecs: cluster.speechSecs, config: matchConfig)
        }
        progress?(.matching, 1.0)

        var resolvedSpeakers: [ResolvedSpeaker] = []
        var newSegments: [SpeakerSegment] = []

        for (index, cluster) in postProcessed.clusters.enumerated() {
            let decision = decisions[index]
            let clusterSegments = postProcessed.segments.filter { $0.clusterKey == cluster.key }
            guard !clusterSegments.isEmpty else { continue }

            let speakerId: SpeakerID
            if decision.eligibleToFold, let matchedId = decision.speakerId,
               let stored = candidateSpeakers.first(where: { $0.id == matchedId }) {
                // ---- Matched + auto-confirm: reuse the enrolled speaker (confirm-before-enroll:
                // only a previously user-confirmed voiceprint may auto-stamp, §2.4). ----
                speakerId = matchedId
                let storedCentroid = CentroidCodec.vector(from: stored.centroid)
                if SpeakerMatcher.shouldFold(
                    storedDim: storedCentroid.count, new: cluster.centroid,
                    clusterSpeechSecs: cluster.speechSecs, matchScore: decision.score, config: matchConfig
                ) {
                    let folded = SpeakerMatcher.foldCentroidWeighted(
                        stored: storedCentroid, storedTotalSecs: stored.totalSpeechSecs,
                        new: cluster.centroid, newSecs: cluster.speechSecs
                    )
                    try await database.speakers.persistFold(
                        matchedId, centroid: CentroidCodec.data(from: folded),
                        samples: stored.samples + 1,
                        totalSpeechSecs: stored.totalSpeechSecs + cluster.speechSecs,
                        at: now
                    )
                }
                if let personId = stored.personId {
                    try await database.persons.addParticipant(
                        meetingId: meetingId, personId: personId, linkSource: "speaker", at: now
                    )
                }
            } else {
                // ---- Not eligible (suggest/anonymous): a fresh provisional speaker awaiting
                // manual confirmation — never auto-linked to a person (invariant I1). ----
                let newId = SpeakerID(UUID().uuidString)
                let provisional = Speaker(
                    id: newId, personId: nil, label: nil,
                    centroid: CentroidCodec.data(from: cluster.centroid),
                    embeddingModel: provider.embeddingModel, dim: cluster.centroid.count,
                    samples: 1, enrollmentState: .provisional,
                    totalSpeechSecs: cluster.speechSecs, createdAt: now, updatedAt: now
                )
                try await database.speakers.upsert(provisional)
                speakerId = newId
            }

            resolvedSpeakers.append(ResolvedSpeaker(
                speakerId: speakerId, tier: decision.tier, score: decision.score, speechSecs: cluster.speechSecs
            ))

            let centroidBytes = CentroidCodec.data(from: cluster.centroid)
            for (segIndex, segment) in clusterSegments.enumerated() {
                newSegments.append(SpeakerSegment(
                    id: SpeakerSegmentID(UUID().uuidString), meetingId: meetingId, speakerId: speakerId,
                    clusterKey: cluster.key, startTime: segment.startTime, endTime: segment.endTime,
                    source: .system,
                    embedding: segIndex == 0 ? centroidBytes : nil,
                    createdAt: now
                ))
            }
        }

        if !newSegments.isEmpty {
            try await database.speakerSegments.insert(newSegments)
        }

        progress?(.stamping, 0.0)
        let transcripts = try await database.transcripts.forMeeting(meetingId)
        let allSegments = try await database.speakerSegments.forMeeting(meetingId)
        let stampResult = TranscriptStamper.stamp(transcripts: transcripts, segments: allSegments)
        if !stampResult.stamps.isEmpty {
            _ = try await database.transcripts.setSpeakers(
                stampResult.stamps.map { (transcriptId: $0.transcriptId, speakerId: $0.speakerId) },
                inMeeting: meetingId
            )
        }
        progress?(.stamping, 1.0)

        return RunResult(
            stampedRows: stampResult.stamps.count,
            unresolvedRows: stampResult.unstamped.count,
            speakers: resolvedSpeakers
        )
    }

    /// Confirm-before-enroll: link a (provisional) speaker to a person. If the person already
    /// has a confirmed/owner voiceprint in the same `embeddingModel` space (the CANONICAL row),
    /// this performs a minimal merge-to-canonical (B1 — ← Rust `speaker_assign_to_person_impl`/
    /// `merge_speaker_into`, `commands.rs:1103-1229`): a `shouldFold`-gated duration-weighted
    /// fold of `speakerId`'s centroid into the canonical, then repoints its `speakerSegment` and
    /// `transcript.speakerId` references onto the canonical and tombstones it
    /// (`repointSpeakerReferences`). The fold is skipped for a too-short/degenerate source (the
    /// merge/repoint still proceeds) — a user-confirmed identity is never lost while a noisy
    /// centroid can't drift a good one. If no canonical exists yet, `speakerId` simply becomes
    /// it (`assignToPerson`). Either way, links the person as a participant of `meetingId`
    /// (← `PersonRepository.addParticipant(linkSource: "speaker")`).
    ///
    /// The retroactive cross-meeting relabel scan (Rust `list_provisional_for_relabel`) stays a
    /// deferred non-goal (plan §1) — this only touches `meetingId`.
    public func confirmSpeaker(_ speakerId: SpeakerID, as personId: PersonID, inMeeting meetingId: MeetingID) async throws {
        guard let subject = try await database.speakers.find(speakerId) else {
            throw DiarizationError.providerFailed("speaker \(speakerId.rawValue) not found")
        }

        let now = Date()
        let sameSpaceCandidates = try await database.speakers.matchCandidates(embeddingModel: subject.embeddingModel)
        let canonical = sameSpaceCandidates.first { $0.personId == personId && $0.id != speakerId }

        if let canonical {
            let fromCentroid = CentroidCodec.vector(from: subject.centroid)
            let intoCentroid = CentroidCodec.vector(from: canonical.centroid)
            if SpeakerMatcher.shouldFold(
                storedDim: intoCentroid.count, new: fromCentroid,
                clusterSpeechSecs: subject.totalSpeechSecs, matchScore: nil, config: matchConfig
            ) {
                let folded = SpeakerMatcher.foldCentroidWeighted(
                    stored: intoCentroid, storedTotalSecs: canonical.totalSpeechSecs,
                    new: fromCentroid, newSecs: subject.totalSpeechSecs
                )
                try await database.speakers.persistFold(
                    canonical.id, centroid: CentroidCodec.data(from: folded),
                    samples: canonical.samples + 1,
                    totalSpeechSecs: canonical.totalSpeechSecs + subject.totalSpeechSecs,
                    at: now
                )
            }
            _ = try await database.speakers.repointSpeakerReferences(from: speakerId, to: canonical.id, inMeeting: meetingId)
        } else {
            try await database.speakers.assignToPerson(speakerId, personId: personId, at: now)
        }

        try await database.persons.addParticipant(meetingId: meetingId, personId: personId, linkSource: "speaker", at: now)
    }

    /// The full assignable-person list for the "Assign person…" picker's fallback list (plan §6
    /// — shown below the ranked suggestions, plus "New person…" in the UI itself). A read-only
    /// convenience; writes nothing.
    public func assignablePeople() async throws -> [Person] {
        try await database.persons.all()
    }

    /// Ranked assign-picker suggestions for one (usually provisional) speaker (plan §6 — ←
    /// `SpeakerMatcher.rankedSuggestions`, parity-M3). Read-only: looks up the speaker's own
    /// centroid and ranks it against every confirmed/owner voiceprint in the same
    /// `embeddingModel` space that is linked to a person. Honest empty array when the speaker
    /// can't be found or has no candidates — never a fabricated suggestion.
    public func assignmentSuggestions(forSpeaker speakerId: SpeakerID) async throws -> [(personId: PersonID, score: Float)] {
        guard let speaker = try await database.speakers.find(speakerId) else { return [] }
        let embedding = CentroidCodec.vector(from: speaker.centroid)
        let candidateSpeakers = try await database.speakers.matchCandidates(embeddingModel: speaker.embeddingModel)
        let candidates: [(id: SpeakerID, personId: PersonID, centroid: [Float])] = candidateSpeakers.compactMap { candidate in
            guard let personId = candidate.personId else { return nil }
            return (id: candidate.id, personId: personId, centroid: CentroidCodec.vector(from: candidate.centroid))
        }
        return SpeakerMatcher.rankedSuggestions(embedding: embedding, candidates: candidates)
    }
}
