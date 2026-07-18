//
//  ImportReport.swift — the No-Fake-State ledger for the legacy-library importer (plan §5.5).
//
//  Never claims success it can't back with a count: for every source table the importer touches,
//  `importedCount + skippedCount` must equal `sourceRowCount` exactly, or `isFullyReconciled`
//  goes false. A silently dropped row is a bug this type is built to catch (plan §7 test 3(a)).
//
//  ⚠️ Extends the plan's literal §5.5 struct with two additive fields, both load-bearing for the
//  same No-Fake-State goal rather than exhaustively enumerated there:
//  - `warnings`: informational findings that are NOT a skipped row — a stale `audioReferencePath`
//    (§5.4), the `person.isOwner` multi-true-row anomaly, a self-inconsistent `audio_end_time`
//    (§5.5's "carried, not masked" data bug), or a calendar event whose `attendees` JSON was
//    malformed but the rest of the row imported fine. Surfacing these as text rather than
//    silently swallowing them keeps the ledger honest without failing an otherwise-good row.
//  - `sourceError`: set only when the legacy file itself couldn't be opened (§5.6) — `tables` is
//    empty in that case, so `isFullyReconciled` is vacuously `true`. Callers MUST check
//    `sourceError` before trusting `isFullyReconciled`.
//
import Foundation

public struct ImportReport: Sendable {
    /// Per-source-table reconciliation (plan §5.5). `table` names the LEGACY table (`"meetings"`,
    /// `"profile_facts"`, …) — the mapping to the AriKit table(s) it fed is documented in
    /// `ImportMapping` and plan §5.2, not repeated here.
    public struct TableResult: Sendable, Equatable {
        public let table: String
        public let sourceRowCount: Int
        public let importedCount: Int
        public let skippedCount: Int
        public let skipReasons: [String]

        public init(
            table: String,
            sourceRowCount: Int,
            importedCount: Int,
            skippedCount: Int,
            skipReasons: [String]
        ) {
            self.table = table
            self.sourceRowCount = sourceRowCount
            self.importedCount = importedCount
            self.skippedCount = skippedCount
            self.skipReasons = skipReasons
        }
    }

    /// Why the legacy source database itself couldn't be read at all (plan §5.6) — distinct from
    /// a per-row skip, which is recorded in a `TableResult.skipReasons` instead.
    public enum SourceError: Sendable, Equatable {
        case sourceNotFound(path: String)
        case openFailed(path: String, reason: String)
    }

    public let tables: [TableResult]
    public let startedAt: Date
    public let finishedAt: Date
    public let warnings: [String]
    public let sourceError: SourceError?

    public init(
        tables: [TableResult],
        startedAt: Date,
        finishedAt: Date,
        warnings: [String] = [],
        sourceError: SourceError? = nil
    ) {
        self.tables = tables
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.warnings = warnings
        self.sourceError = sourceError
    }

    /// Row-count reconciliation across every table (plan §5.5): every source row was either
    /// imported or explicitly skipped-and-logged — never silently dropped. Vacuously `true` when
    /// `tables` is empty (the `sourceError` case) — check that field first.
    public var isFullyReconciled: Bool {
        tables.allSatisfy { $0.importedCount + $0.skippedCount == $0.sourceRowCount }
    }
}
