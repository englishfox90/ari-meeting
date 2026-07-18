//
//  ProfileFactRepository.swift — the ONLY way feature code touches the `profileFact` and
//  `profileFactSource` tables (plan §2.2, §10 step 5).
//
//  Provenance/supersession is load-bearing (F2, plan §6/§8): every `ProfileFact` this repository
//  returns carries its `sourceCount`/`sourceMeetingTitle` computed live at read time (a `COUNT(*)`
//  over `profileFactSource` and a join against `meeting.title`, respectively) — never a stored,
//  driftable column (No-Fake-State, plan §0.1/§4.6). `withProvenance(_:)` composes a fact with
//  its full source lineage; `supersedeChain(from:)` walks `supersededBy` to the terminal fact.
//
import Foundation
import GRDB

public struct ProfileFactRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [ProfileFact] {
        try await dbWriter.read { db in
            var request = ProfileFactRecord.order(Column("createdAt"))
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { try Self.hydrate($0, db: db) }
        }
    }

    public func find(_ id: ProfileFactID) async throws -> ProfileFact? {
        try await dbWriter.read { db in
            guard let record = try ProfileFactRecord.fetchOne(db, key: id.rawValue) else {
                return nil
            }
            return try Self.hydrate(record, db: db)
        }
    }

    /// Non-tombstoned, `status == .active` facts for a person, in creation order.
    public func activeFacts(for personId: PersonID) async throws -> [ProfileFact] {
        try await dbWriter.read { db in
            let records = try ProfileFactRecord
                .filter(Column("personId") == personId.rawValue)
                .filter(Column("isDeleted") == false)
                .filter(Column("status") == FactStatus.active.rawValue)
                .order(Column("createdAt"))
                .fetchAll(db)
            return try records.map { try Self.hydrate($0, db: db) }
        }
    }

    /// A fact composed with its full provenance lineage (plan §7 test 4).
    public func withProvenance(_ factID: ProfileFactID) async throws -> ProfileFactWithProvenance? {
        try await dbWriter.read { db in
            guard let record = try ProfileFactRecord.fetchOne(db, key: factID.rawValue) else {
                return nil
            }
            let fact = try Self.hydrate(record, db: db)
            let sourceRecords = try ProfileFactSourceRecord
                .filter(Column("factId") == factID.rawValue)
                .filter(Column("isDeleted") == false)
                .order(Column("observedAt"))
                .fetchAll(db)
            let sources = try sourceRecords.map { try Self.hydrateSource($0, db: db) }
            return ProfileFactWithProvenance(fact: fact, sources: sources)
        }
    }

    /// Walks `supersededBy` from `from` to the terminal (non-superseded) fact, inclusive of
    /// `from` itself. Cycle-safe (stops if a pointer is revisited) and stops at the first
    /// unresolved pointer (a dangling `supersededBy` ends the chain rather than throwing).
    public func supersedeChain(from: ProfileFactID) async throws -> [ProfileFact] {
        try await dbWriter.read { db in
            var chain: [ProfileFact] = []
            var visited: Set<String> = []
            var currentID: String? = from.rawValue
            while let id = currentID, !visited.contains(id) {
                visited.insert(id)
                guard let record = try ProfileFactRecord.fetchOne(db, key: id) else { break }
                try chain.append(Self.hydrate(record, db: db))
                currentID = record.supersededBy
            }
            return chain
        }
    }

    /// Insert-or-update, keyed on the stable `ProfileFactID` primary key.
    public func upsert(_ fact: ProfileFact) async throws {
        try await dbWriter.write { db in
            try ProfileFactRecord(fact).save(db)
        }
    }

    /// Records one provenance observation backing a fact.
    public func recordSource(_ source: ProfileFactSource) async throws {
        try await dbWriter.write { db in
            try ProfileFactSourceRecord(source).save(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ id: ProfileFactID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try ProfileFactRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    public func observeAll() -> AsyncStream<[ProfileFact]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db -> [ProfileFact] in
            let records = try ProfileFactRecord
                .filter(Column("isDeleted") == false)
                .order(Column("createdAt"))
                .fetchAll(db)
            return try records.map { try Self.hydrate($0, db: db) }
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

    // MARK: - Read-time computed provenance (No-Fake-State — never stored columns)

    private static func hydrate(_ record: ProfileFactRecord, db: Database) throws -> ProfileFact {
        let sourceCount = try ProfileFactSourceRecord
            .filter(Column("factId") == record.id)
            .filter(Column("isDeleted") == false)
            .fetchCount(db)
        let sourceMeetingTitle = try record.sourceMeetingId.flatMap { meetingId in
            try MeetingRecord.fetchOne(db, key: meetingId)?.title
        }
        return record.asModel(sourceMeetingTitle: sourceMeetingTitle, sourceCount: sourceCount)
    }

    private static func hydrateSource(
        _ record: ProfileFactSourceRecord,
        db: Database
    ) throws -> ProfileFactSource {
        let meetingTitle = try record.meetingId.flatMap { meetingId in
            try MeetingRecord.fetchOne(db, key: meetingId)?.title
        }
        return record.asModel(meetingTitle: meetingTitle)
    }
}
