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

    /// Insert-or-update, keyed on the stable `ProfileFactID` primary key. Preserves
    /// `supersedesFactId`/`lastConfirmedAt` on an existing row (Store-internal fields the domain
    /// `ProfileFact` doesn't carry) by fetch-then-mutate rather than blind overwrite — mirrors
    /// `SeriesRepository.upsert(_:)`'s precedent for the same class of gap (see
    /// `Records/ProfileFactRecord.swift`'s header).
    public func upsert(_ fact: ProfileFact) async throws {
        try await dbWriter.write { db in
            var record = ProfileFactRecord(fact)
            if let existing = try ProfileFactRecord.fetchOne(db, key: fact.id.rawValue) {
                record.supersedesFactId = existing.supersedesFactId
                record.lastConfirmedAt = existing.lastConfirmedAt
            }
            try record.save(db)
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

    // MARK: - Reconciliation (Phase 3.4 Track H, `arikit-engine-extras.md` §2.3) — additive

    /// Active + pending facts for a person, in creation order — the "current facts" the
    /// reconciliation engine shows the model so it decides add/keep/supersede/remove instead of
    /// piling on near-duplicates (← `list_active_and_pending_for_person`, `person.rs:661`).
    public func listActiveAndPending(for personId: PersonID) async throws -> [ProfileFact] {
        try await dbWriter.read { db in
            let records = try ProfileFactRecord
                .filter(Column("personId") == personId.rawValue)
                .filter(["active", "pending"].contains(Column("status")))
                .filter(Column("isDeleted") == false)
                .order(Column("createdAt"))
                .fetchAll(db)
            return try records.map { try Self.hydrate($0, db: db) }
        }
    }

    /// Records that `newFactId` (a pending replacement) proposes to supersede `oldFactId`, WITHOUT
    /// retiring the old fact (← `mark_supersedes`, `person.rs:632`) — deferred supersession: the
    /// old fact stays ACTIVE (and in use) until a future confirm flow retires it via
    /// `supersededBy`. A no-op if `newFactId` doesn't exist.
    public func markSupersedes(newFactId: ProfileFactID, oldFactId: ProfileFactID) async throws {
        try await dbWriter.write { db in
            guard var record = try ProfileFactRecord.fetchOne(db, key: newFactId.rawValue) else { return }
            record.supersedesFactId = oldFactId.rawValue
            try record.update(db)
        }
    }

    /// Resets the staleness clock (← `touch_confirmed`, `person.rs:699`) — called both by a future
    /// explicit user-confirm flow and by reconciliation's "keep" decision after fresh transcript
    /// evidence reaffirms a fact. A no-op if `factId` doesn't exist.
    public func touchConfirmed(_ factId: ProfileFactID, at date: Date = Date()) async throws {
        try await dbWriter.write { db in
            guard var record = try ProfileFactRecord.fetchOne(db, key: factId.rawValue) else { return }
            record.lastConfirmedAt = date
            try record.update(db)
        }
    }

    /// Marks a fact `.removed` — automated reconciliation/cap-enforcement pruning, distinct from
    /// `softDelete` (a tombstone) and from a user's explicit `.rejected` (← `mark_removed`,
    /// `person.rs:688`). A no-op if `factId` doesn't exist.
    public func markRemoved(_ factId: ProfileFactID) async throws {
        try await dbWriter.write { db in
            guard var record = try ProfileFactRecord.fetchOne(db, key: factId.rawValue) else { return }
            record.status = FactStatus.removed.rawValue
            try record.update(db)
        }
    }

    /// Adds a corroborating source only if `factId` has no existing (non-deleted) source for the
    /// same non-nil `meetingId` (← `add_source_dedup`, `person.rs:892`) — keeps a re-run of
    /// reconciliation for the same meeting from double-counting a reaffirmation. Returns whether a
    /// row was inserted. A `nil` `meetingId` is always inserted (nothing to dedupe against).
    @discardableResult
    public func addSourceDedup(
        factId: ProfileFactID,
        meetingId: MeetingID?,
        segmentRef: String?,
        origin: FactOrigin,
        relation: FactSourceRelation,
        confidence: Double,
        at date: Date = Date()
    ) async throws -> Bool {
        try await dbWriter.write { db in
            if let meetingId {
                let existingCount = try ProfileFactSourceRecord
                    .filter(Column("factId") == factId.rawValue)
                    .filter(Column("meetingId") == meetingId.rawValue)
                    .filter(Column("isDeleted") == false)
                    .fetchCount(db)
                if existingCount > 0 {
                    return false
                }
            }
            try ProfileFactSourceRecord(ProfileFactSource(
                id: ProfileFactSourceID(UUID().uuidString),
                factId: factId,
                meetingId: meetingId,
                segmentRef: segmentRef,
                origin: origin,
                relation: relation,
                confidence: min(max(confidence, 0.0), 1.0),
                observedAt: date
            )).save(db)
            return true
        }
    }

    /// Enforces a per-person cap on ACTIVE facts (← `trim_active_to_cap`, `person.rs:744`): when
    /// over cap, the lowest-confidence / oldest active facts are marked `.removed` (automated
    /// pruning, not user rejection) until the count is back at `cap`. Returns how many were pruned.
    @discardableResult
    public func trimActiveToCap(person personId: PersonID, cap: Int) async throws -> Int {
        try await trim(status: .active, person: personId, cap: cap)
    }

    /// Enforces a per-person cap on PENDING facts, mirroring `trimActiveToCap` (←
    /// `trim_pending_to_cap`, `person.rs:790`) — prevents an unbounded backlog when a person is
    /// never reviewed. Returns how many were pruned.
    @discardableResult
    public func trimPendingToCap(person personId: PersonID, cap: Int) async throws -> Int {
        try await trim(status: .pending, person: personId, cap: cap)
    }

    private func trim(status: FactStatus, person personId: PersonID, cap: Int) async throws -> Int {
        try await dbWriter.write { db in
            let records = try ProfileFactRecord
                .filter(Column("personId") == personId.rawValue)
                .filter(Column("status") == status.rawValue)
                .filter(Column("isDeleted") == false)
                .order(Column("confidence"), Column("createdAt"))
                .fetchAll(db)
            let excess = records.count - cap
            guard excess > 0 else { return 0 }
            for record in records.prefix(excess) {
                var mutable = record
                mutable.status = FactStatus.removed.rawValue
                try mutable.update(db)
            }
            return excess
        }
    }

    /// Active/pending facts for a person that haven't been (re)confirmed in over `staleDays` (←
    /// `facts_needing_review`, `person.rs:712`) — falls back to `createdAt` when never confirmed.
    /// Ordered most-stale-first (oldest reference date first), surfaced for a future "needs
    /// review" UI affordance.
    public func factsNeedingReview(person personId: PersonID, staleDays: Int) async throws -> [ProfileFact] {
        try await dbWriter.read { db in
            let records = try ProfileFactRecord
                .filter(Column("personId") == personId.rawValue)
                .filter(["active", "pending"].contains(Column("status")))
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            let now = Date()
            let staleSeconds = TimeInterval(staleDays) * 86400
            let stale = records.filter { record in
                let reference = record.lastConfirmedAt ?? record.createdAt
                return now.timeIntervalSince(reference) > staleSeconds
            }
            let sorted = stale.sorted {
                ($0.lastConfirmedAt ?? $0.createdAt) < ($1.lastConfirmedAt ?? $1.createdAt)
            }
            return try sorted.map { try Self.hydrate($0, db: db) }
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
