//
//  VocabularyRepository.swift — the ONLY way feature code touches the `vocabularyTerm` table
//  (docs/plans/custom-vocabulary.md §4.2).
//
import Foundation
import GRDB

public enum VocabularyError: Error, Sendable, Equatable {
    case duplicateTerm(String)
    case capExceeded(limit: Int)
    case emptyTerm
}

public struct VocabularyRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDisabled: Bool = true) async throws -> [VocabularyTerm] {
        try await dbWriter.read { db in
            var request = VocabularyTermRecord
                .filter(Column("isDeleted") == false)
                .order(Column("term").collating(.nocase))
            if !includingDisabled {
                request = request.filter(Column("isEnabled") == true)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func enabledTerms() async throws -> [VocabularyTerm] {
        try await all(includingDisabled: false)
    }

    public func find(_ id: VocabularyTermID) async throws -> VocabularyTerm? {
        try await dbWriter.read { db in
            try VocabularyTermRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    public func enabledCount() async throws -> Int {
        try await dbWriter.read { db in
            try VocabularyTermRecord
                .filter(Column("isDeleted") == false)
                .filter(Column("isEnabled") == true)
                .fetchCount(db)
        }
    }

    /// Insert-or-update. Throws `VocabularyError.emptyTerm` for a blank term,
    /// `.duplicateTerm(String)` on a normalized collision with a live row, and
    /// `.capExceeded(limit:)` when enabling would push the enabled count past
    /// `VocabularyBias.maxEnabledTerms`. All checks run INSIDE the same write transaction as the
    /// save — a UI-only guard would race.
    public func upsert(_ term: VocabularyTerm) async throws {
        let record = try VocabularyTermRecord(term)
        guard !record.normalizedTerm.isEmpty else {
            throw VocabularyError.emptyTerm
        }

        try await dbWriter.write { db in
            let duplicate = try VocabularyTermRecord
                .filter(Column("isDeleted") == false)
                .filter(Column("normalizedTerm") == record.normalizedTerm)
                .filter(Column("id") != record.id)
                .fetchOne(db)
            if duplicate != nil {
                throw VocabularyError.duplicateTerm(term.term)
            }

            if record.isEnabled {
                let existing = try VocabularyTermRecord.fetchOne(db, key: record.id)
                let wasAlreadyEnabled = existing?.isEnabled == true && existing?.isDeleted == false
                if !wasAlreadyEnabled {
                    let enabledCount = try VocabularyTermRecord
                        .filter(Column("isDeleted") == false)
                        .filter(Column("isEnabled") == true)
                        .fetchCount(db)
                    if enabledCount >= VocabularyBias.maxEnabledTerms {
                        throw VocabularyError.capExceeded(limit: VocabularyBias.maxEnabledTerms)
                    }
                }
            }

            try record.save(db)
        }
    }

    public func setEnabled(_ isEnabled: Bool, for id: VocabularyTermID) async throws {
        try await dbWriter.write { db in
            guard var record = try VocabularyTermRecord.fetchOne(db, key: id.rawValue) else {
                return
            }

            if isEnabled, !record.isEnabled {
                let enabledCount = try VocabularyTermRecord
                    .filter(Column("isDeleted") == false)
                    .filter(Column("isEnabled") == true)
                    .fetchCount(db)
                if enabledCount >= VocabularyBias.maxEnabledTerms {
                    throw VocabularyError.capExceeded(limit: VocabularyBias.maxEnabledTerms)
                }
            }

            record.isEnabled = isEnabled
            try record.update(db)
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`. Frees the term's
    /// `normalizedTerm` for reuse (the unique index is partial, `WHERE isDeleted = false`).
    public func softDelete(_ id: VocabularyTermID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try VocabularyTermRecord.fetchOne(db, key: id.rawValue) else {
                return
            }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    public func observeAll() -> AsyncStream<[VocabularyTerm]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try VocabularyTermRecord
                .filter(Column("isDeleted") == false)
                .order(Column("term").collating(.nocase))
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
