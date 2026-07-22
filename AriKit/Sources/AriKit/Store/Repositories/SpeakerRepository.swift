//
//  SpeakerRepository.swift — the ONLY way feature code touches the `speaker` table (plan §2.2).
//
import Foundation
import GRDB

public struct SpeakerRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [Speaker] {
        try await dbWriter.read { db in
            var request = SpeakerRecord.order(Column("createdAt").desc)
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func find(_ id: SpeakerID) async throws -> Speaker? {
        try await dbWriter.read { db in
            try SpeakerRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    /// Insert-or-update, keyed on the stable `SpeakerID` primary key.
    public func upsert(_ speaker: Speaker) async throws {
        try await dbWriter.write { db in
            try SpeakerRecord(speaker).save(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ id: SpeakerID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try SpeakerRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    // MARK: - Diarization (Phase 3.5, plan §3)

    /// Speakers that have spoken in a meeting, via `speakerSegment` (← Rust `list_for_meeting`,
    /// `speaker.rs:90-105`). Distinct, non-deleted, oldest first — closes the TODO(S6) gap.
    public func forMeeting(_ meetingId: MeetingID) async throws -> [Speaker] {
        try await dbWriter.read { db in
            let speakerIds = try String.fetchSet(
                db,
                SpeakerSegmentRecord
                    .filter(Column("meetingId") == meetingId.rawValue)
                    .filter(Column("speakerId") != nil)
                    .select(Column("speakerId"))
            )
            guard !speakerIds.isEmpty else { return [] }
            return try SpeakerRecord
                .filter(Column("isDeleted") == false)
                .filter(speakerIds.contains(Column("id")))
                .order(Column("createdAt"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// Enrolled voiceprints eligible as match candidates: `enrollmentState` IN (`confirmed`,
    /// `owner`), same `embeddingModel` space, not deleted (← Rust's `person_id IS NOT NULL`
    /// gate, `speaker.rs:189-196` — deliberately tightened per plan §3/parity-L5: filtering by
    /// `embeddingModel` here rather than relying on the matcher's dim guard).
    public func matchCandidates(embeddingModel: String) async throws -> [Speaker] {
        try await dbWriter.read { db in
            try SpeakerRecord
                .filter(Column("isDeleted") == false)
                .filter(Column("embeddingModel") == embeddingModel)
                .filter(["confirmed", "owner"].contains(Column("enrollmentState")))
                .order(Column("updatedAt").desc)
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// Write-only fold persist: the duration-weighted centroid math lives in `SpeakerMatcher`
    /// (← Rust `fold_centroid`, `speaker.rs:164-187`); this only writes the resulting bytes,
    /// sample count, and accumulated speech seconds.
    public func persistFold(
        _ id: SpeakerID,
        centroid: Data,
        samples: Int,
        totalSpeechSecs: Double,
        at date: Date
    ) async throws {
        try await dbWriter.write { db in
            guard var record = try SpeakerRecord.fetchOne(db, key: id.rawValue) else { return }
            record.centroid = centroid
            record.samples = samples
            record.totalSpeechSecs = totalSpeechSecs
            record.updatedAt = date
            try record.update(db)
        }
    }

    /// Link a speaker to a person and mark it confirmed — the confirm-before-enroll gate
    /// (← Rust `assign_to_person`, `speaker.rs:123-143`).
    public func assignToPerson(_ id: SpeakerID, personId: PersonID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try SpeakerRecord.fetchOne(db, key: id.rawValue) else { return }
            record.personId = personId.rawValue
            record.enrollmentState = EnrollmentState.confirmed.rawValue
            record.updatedAt = date
            try record.update(db)
        }
    }

    /// B1 — minimal merge-to-canonical (← Rust `merge_speaker_into`'s repoint step,
    /// `commands.rs:1180-1229` / `repoint_and_delete_speaker`, `speaker.rs:486-514`), ONE
    /// transaction, scoped to `meetingId` (plan §3/§2.7 — the retroactive cross-meeting scan
    /// stays a deferred non-goal): repoint `speakerSegment.speakerId` and `transcript.speakerId`
    /// from the provisional to the canonical for this meeting, then tombstone (soft-delete) the
    /// provisional — never a hard `DELETE` (sync-aware schema rule; Rust deletes the row, Swift
    /// tombstones it instead).
    public func repointSpeakerReferences(
        from provisionalId: SpeakerID,
        to canonicalId: SpeakerID,
        inMeeting meetingId: MeetingID
    ) async throws -> (segmentsRepointed: Int, transcriptsRepointed: Int) {
        try await dbWriter.write { db in
            let segmentsRepointed = try SpeakerSegmentRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .filter(Column("speakerId") == provisionalId.rawValue)
                .updateAll(db, Column("speakerId").set(to: canonicalId.rawValue))

            let transcriptsRepointed = try TranscriptRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .filter(Column("speakerId") == provisionalId.rawValue)
                .updateAll(db, Column("speakerId").set(to: canonicalId.rawValue))

            if var record = try SpeakerRecord.fetchOne(db, key: provisionalId.rawValue) {
                record.isDeleted = true
                record.deletedAt = Date()
                try record.update(db)
            }

            return (segmentsRepointed, transcriptsRepointed)
        }
    }

    /// The idempotency guard (← Rust `clear_meeting_diarization`, `speaker.rs:290-328`), ONE
    /// transaction: un-stamp the meeting's transcripts, delete its `speakerSegment` rows, then
    /// tombstone (never hard-delete — sync-aware schema rule) now-orphaned provisional speakers
    /// (`personId IS NULL`, `.provisional`, no remaining segment references anywhere).
    /// Confirmed/owner voiceprints are never touched — folds are irreversible and they are the
    /// cross-meeting match pool. Callers (`DiarizationService`) treat a thrown error as FATAL
    /// and abort the run (parity-L6 — unlike Rust's best-effort/logged-and-continue clear).
    public func clearMeetingDiarization(
        _ meetingId: MeetingID
    ) async throws -> (transcriptsCleared: Int, segmentsDeleted: Int, provisionalsRemoved: Int) {
        try await dbWriter.write { db in
            let now = Date()

            let transcriptsCleared = try TranscriptRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .updateAll(db, Column("speakerId").set(to: nil as String?))

            let segmentsDeleted = try SpeakerSegmentRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .deleteAll(db)

            let referencedSpeakerIds = try String.fetchSet(
                db,
                SpeakerSegmentRecord.select(Column("speakerId")).filter(Column("speakerId") != nil)
            )

            let orphanCandidates = try SpeakerRecord
                .filter(Column("isDeleted") == false)
                .filter(Column("personId") == nil)
                .filter(Column("enrollmentState") == EnrollmentState.provisional.rawValue)
                .fetchAll(db)

            var provisionalsRemoved = 0
            for var record in orphanCandidates where !referencedSpeakerIds.contains(record.id) {
                record.isDeleted = true
                record.deletedAt = now
                try record.update(db)
                provisionalsRemoved += 1
            }

            return (transcriptsCleared, segmentsDeleted, provisionalsRemoved)
        }
    }

    public func observeAll() -> AsyncStream<[Speaker]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try SpeakerRecord
                .filter(Column("isDeleted") == false)
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .map { $0.asModel() }
        }
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: dbWriter) {
                        continuation.yield(value)
                    }
                } catch {
                    // See MeetingRepository.observeAll(): a failure ends the stream.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
