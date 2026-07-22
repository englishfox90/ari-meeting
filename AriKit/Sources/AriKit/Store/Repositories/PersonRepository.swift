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

    // MARK: - Participant roster (`meetingParticipant` — Phase 3.4 Track H, §2.3/§6-5)

    /// The persons linked to `meetingId` as participants (← `list_participants`, `person.rs:370`),
    /// alphabetical by display name, excluding soft-deleted persons (a documented improvement over
    /// Rust, which has no person-level soft-delete concept). Persons extraction/reconciliation's
    /// "no linked participants — nothing to do" degrade gate reads this.
    public func participants(inMeeting meetingId: MeetingID) async throws -> [Person] {
        try await dbWriter.read { db in
            let personIds = try MeetingParticipantRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .fetchAll(db)
                .map(\.personId)
            guard !personIds.isEmpty else { return [] }
            return try PersonRecord
                .filter(personIds.contains(Column("id")))
                .filter(Column("isDeleted") == false)
                .order(Column("displayName"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// Insert-or-ignore a meeting/person participant link (← `link_participant`, `person.rs:348`
    /// — `INSERT OR IGNORE`, so re-linking the same pair is a no-op rather than overwriting an
    /// existing `linkSource`/`createdAt`). Population (e.g. auto-link from calendar attendees) is
    /// a Phase-2 concern (plan §6-5) — this is the additive primitive only.
    public func addParticipant(
        meetingId: MeetingID,
        personId: PersonID,
        linkSource: String? = nil,
        at date: Date = Date()
    ) async throws {
        try await dbWriter.write { db in
            let arguments: [DatabaseValueConvertible?] = [
                meetingId.rawValue, personId.rawValue, linkSource, date
            ]
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO meetingParticipant (meetingId, personId, linkSource, createdAt)
                VALUES (?, ?, ?, ?)
                """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// A genuine hard delete of the link row — no tombstone column exists on `meetingParticipant`
    /// (mirrors `seriesMember`'s precedent). Returns whether a row was actually removed.
    @discardableResult
    public func removeParticipant(meetingId: MeetingID, personId: PersonID) async throws -> Bool {
        try await dbWriter.write { db in
            try MeetingParticipantRecord.deleteOne(
                db,
                key: ["meetingId": meetingId.rawValue, "personId": personId.rawValue]
            )
        }
    }

    // MARK: - Reverse lookup + calendar-attendee bridge (people-view-parity plan §2.1 Slice 1)

    /// The meetings `id` is linked to as a participant, non-deleted, newest first (← reverse of
    /// `participants(inMeeting:)`; closes the `PersonDetailViewModel` TODO(S6)).
    public func meetings(forPerson id: PersonID) async throws -> [Meeting] {
        try await dbWriter.read { db in
            let meetingIds = try MeetingParticipantRecord
                .filter(Column("personId") == id.rawValue)
                .fetchAll(db)
                .map(\.meetingId)
            guard !meetingIds.isEmpty else { return [] }
            return try MeetingRecord
                .filter(meetingIds.contains(Column("id")))
                .filter(Column("isDeleted") == false)
                .order(Column("createdAt").desc)
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// Email-keyed idempotent stub, one write transaction (← Rust `upsert_stub_from_attendee`,
    /// `person.rs:308-346`): if `email` is non-nil and a non-deleted person with that email
    /// (case-insensitive) already exists, that person is returned **unchanged** — never clobbers
    /// authored identity. Otherwise inserts a stub (`isOwner=false`, all optionals nil) with a
    /// resolved display name: trimmed `displayName` if non-empty, else the email's local-part
    /// (before `@`), else `"Unknown"`.
    @discardableResult
    public func upsertStubFromAttendee(
        email: String?,
        displayName: String,
        at date: Date = Date()
    ) async throws -> Person {
        try await dbWriter.write { db in
            if let email, let existing = try Self.findByEmail(email, db: db) {
                return existing.asModel()
            }

            let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName: String = if !trimmedName.isEmpty {
                trimmedName
            } else if let email {
                email.split(separator: "@").first.map(String.init) ?? email
            } else {
                "Unknown"
            }

            let record = PersonRecord(Person(
                id: PersonID(UUID().uuidString),
                email: email,
                displayName: resolvedName,
                isOwner: false,
                createdAt: date,
                updatedAt: date
            ))
            try record.insert(db)
            return record.asModel()
        }
    }

    /// Case-insensitive, non-deleted lookup by email. Store-internal (mirrors Rust's
    /// `get_by_email`); nested inside a transaction by callers that need read-then-write.
    private static func findByEmail(_ email: String, db: Database) throws -> PersonRecord? {
        try PersonRecord
            .filter(Column("isDeleted") == false)
            .filter(Column("email").collating(.nocase) == email)
            .fetchOne(db)
    }
}
