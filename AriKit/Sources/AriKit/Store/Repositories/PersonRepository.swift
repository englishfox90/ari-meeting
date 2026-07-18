//
//  PersonRepository.swift — the ONLY way feature code touches the `person` table (plan §2.2,
//  §10 step 5).
//
import Foundation
import GRDB

/// Thrown by `PersonRepository.setOwner(_:)` when asked to promote a person that doesn't exist.
public enum PersonRepositoryError: Error, Sendable, Equatable {
    case personNotFound(PersonID)
}

public struct PersonRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [Person] {
        try await dbWriter.read { db in
            var request = PersonRecord.order(Column("displayName"))
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func find(_ id: PersonID) async throws -> Person? {
        try await dbWriter.read { db in
            try PersonRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    /// The current recording owner (`isOwner == true`), if one has been set.
    public func owner() async throws -> Person? {
        try await dbWriter.read { db in
            try PersonRecord
                .filter(Column("isOwner") == true)
                .filter(Column("isDeleted") == false)
                .fetchOne(db)?
                .asModel()
        }
    }

    /// Insert-or-update, keyed on the stable `PersonID` primary key. Does NOT touch `isOwner`
    /// exclusivity — use `setOwner(_:)` to change ownership; a plain `upsert` persists whatever
    /// `isOwner` value the caller's `Person` carries, so prefer `setOwner` over hand-rolling the
    /// invariant at call sites.
    public func upsert(_ person: Person) async throws {
        try await dbWriter.write { db in
            try PersonRecord(person).save(db)
        }
    }

    /// Atomically marks `id` as the sole owner, unsetting any prior owner in the same
    /// transaction (plan §0.1(4) — repository-enforced single-true-row, not a DB constraint;
    /// SQLite has no partial-unique-on-boolean primitive that survives CloudKit per-record
    /// conflict resolution cleanly). Throws `.personNotFound` if `id` doesn't exist.
    public func setOwner(_ id: PersonID) async throws {
        try await dbWriter.write { db in
            guard var newOwner = try PersonRecord.fetchOne(db, key: id.rawValue) else {
                throw PersonRepositoryError.personNotFound(id)
            }
            try PersonRecord
                .filter(Column("isOwner") == true)
                .filter(Column("id") != id.rawValue)
                .updateAll(db, [Column("isOwner").set(to: false)])
            newOwner.isOwner = true
            try newOwner.update(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ id: PersonID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try PersonRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    public func observeAll() -> AsyncStream<[Person]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try PersonRecord
                .filter(Column("isDeleted") == false)
                .order(Column("displayName"))
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
