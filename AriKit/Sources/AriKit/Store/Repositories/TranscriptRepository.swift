//
//  TranscriptRepository.swift — the ONLY way feature code touches the `transcript` table
//  (plan §2.2).
//
import Foundation
import GRDB

public struct TranscriptRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [Transcript] {
        try await dbWriter.read { db in
            var request = TranscriptRecord.order(Column("timestamp"))
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { $0.asModel() }
        }
    }

    public func find(_ id: TranscriptID) async throws -> Transcript? {
        try await dbWriter.read { db in
            try TranscriptRecord.fetchOne(db, key: id.rawValue)?.asModel()
        }
    }

    /// All (non-deleted) transcript segments for a meeting, in recording order.
    public func forMeeting(_ meetingId: MeetingID) async throws -> [Transcript] {
        try await dbWriter.read { db in
            try TranscriptRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .filter(Column("isDeleted") == false)
                .order(Column("audioStartTime"))
                .fetchAll(db)
                .map { $0.asModel() }
        }
    }

    /// Insert-or-update, keyed on the stable `TranscriptID` primary key.
    public func upsert(_ transcript: Transcript) async throws {
        try await dbWriter.write { db in
            try TranscriptRecord(transcript).save(db)
        }
    }

    /// Insert-or-update a batch of segments in ONE write transaction (additive; ari-recording-
    /// page.md §2.3/§5 — the deferred batch write assigned to this slice). `dbWriter.write`
    /// already runs its whole closure inside a single GRDB transaction, rolling back entirely on
    /// any thrown error — so a mid-batch failure leaves NONE of the batch persisted (atomicity),
    /// and a batch containing an already-persisted id is a plain idempotent re-`save`, same as
    /// the scalar `upsert(_:)` above. Preserves `transcripts`' order (irrelevant to storage, but
    /// keeps behavior deterministic for callers who care). Used for the recording session's
    /// burst-drain at `stop()` (plan §5); the live per-segment path can keep calling the scalar
    /// `upsert(_:)`.
    public func upsert(_ transcripts: [Transcript]) async throws {
        try await dbWriter.write { db in
            for transcript in transcripts {
                try TranscriptRecord(transcript).save(db)
            }
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt`, never issues a hard `DELETE`.
    public func softDelete(_ id: TranscriptID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try TranscriptRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    /// Legacy keyword-`LIKE` fallback for recall's hybrid search when nothing is indexed yet
    /// (← `TranscriptsRepository::search_transcripts` / `search_transcripts_scoped(_, _, None)`,
    /// `ari-engine/src/database/repositories/transcript.rs:91-223`). Scores each (meeting,
    /// transcript-segment) row by how many query terms appear across its title / segment text /
    /// summary, applying a minimum-score gate (≥2 terms when the query itself yields ≥3 terms,
    /// else ≥1) that suppresses noise on rich queries while still matching short ones.
    ///
    /// NOT the primary retrieval path — `HybridSearch` reaches this only when the recall index is
    /// empty (first-run backfill), matching the Rust fallback's own scope. Only the unscoped
    /// variant is ported (Slice 4 never calls the meeting-scoped `search_meeting_transcripts`).
    public func searchTranscripts(matching question: String) async throws -> [TranscriptSearchResult] {
        let terms = Self.searchTerms(question)
        guard !terms.isEmpty else { return [] }

        return try await dbWriter.read { db in
            var sql = """
            SELECT m.id AS meetingId, m.title AS title, t.transcript AS transcript,
                   t.timestamp AS timestamp, m.createdAt AS createdAt, s.bodyMarkdown AS summary
            FROM meeting m
            JOIN transcript t ON m.id = t.meetingId AND t.isDeleted = 0
            LEFT JOIN summary s ON m.id = s.meetingId AND s.isDeleted = 0
            WHERE m.isDeleted = 0 AND (
            """
            var arguments: [DatabaseValueConvertible?] = []
            for (index, term) in terms.enumerated() {
                if index > 0 {
                    sql += " OR "
                }
                sql += "(LOWER(t.transcript) LIKE ? OR LOWER(m.title) LIKE ? OR LOWER(COALESCE(s.bodyMarkdown, '')) LIKE ?)"
                let pattern = "%\(term)%"
                arguments.append(pattern)
                arguments.append(pattern)
                arguments.append(pattern)
            }
            sql += ") ORDER BY m.createdAt DESC LIMIT 64"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let minimumScore = terms.count >= 3 ? 2 : 1

            var scored: [(score: Int, result: TranscriptSearchResult)] = []
            for row in rows {
                let title: String = row["title"]
                let transcript: String = row["transcript"]
                let summary: String? = row["summary"]
                let haystack = "\(title.lowercased()) \(transcript.lowercased()) \((summary ?? "").lowercased())"
                let score = terms.filter { haystack.contains($0) }.count
                guard score >= minimumScore else { continue }
                let createdAt: Date = row["createdAt"]
                let result = TranscriptSearchResult(
                    id: row["meetingId"],
                    title: title,
                    matchContext: Self.matchContext(in: transcript, terms: terms),
                    timestamp: row["timestamp"],
                    meetingDate: RFC3339.string(from: createdAt),
                    summary: summary
                )
                scored.append((score, result))
            }
            scored.sort { $0.score > $1.score }
            return scored.map(\.result)
        }
    }

    /// Search terms for the keyword-`LIKE` fallback (← `search_terms`, transcript.rs:225-240).
    /// Its stopword list and truncate cap (12) are frozen independently of `HybridSearch`'s own
    /// (larger) FTS-side list (16) — the two are NOT unified.
    private static let searchStopWords: Set<String> = [
        "about", "from", "have", "meetings", "meeting", "that", "the", "this", "what", "when",
        "where", "which", "with", "would", "were", "did", "does", "our", "was", "and", "how", "who"
    ]

    private static func searchTerms(_ query: String) -> [String] {
        let alphanumerics = CharacterSet.alphanumerics
        var terms: [String] = []
        var current: [Unicode.Scalar] = []
        for scalar in query.unicodeScalars {
            if alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                terms.append(String(String.UnicodeScalarView(current)).lowercased())
                current.removeAll()
            }
        }
        if !current.isEmpty {
            terms.append(String(String.UnicodeScalarView(current)).lowercased())
        }

        var filtered = terms.filter { $0.unicodeScalars.count >= 3 && !searchStopWords.contains($0) }
        filtered.sort()
        var seen = Set<String>()
        var deduped: [String] = []
        for term in filtered where seen.insert(term).inserted {
            deduped.append(term)
        }
        return Array(deduped.prefix(12))
    }

    /// Extract a snippet of text around the first match of a query (← `get_match_context`,
    /// transcript.rs:243-262). Rust locates the match via a byte-index `find` into the lowercased
    /// transcript, then converts to a char count against the ORIGINAL string; this Swift port
    /// works in Unicode scalars throughout (matching the `chars().count()` semantics elsewhere in
    /// this subsystem) instead of mixing byte and character indices, which is an implementation
    /// detail difference with no behavioral effect for ASCII/common-case text.
    private static func matchContext(in transcript: String, terms: [String]) -> String {
        let lowerScalars = Array(transcript.lowercased().unicodeScalars)
        let originalScalars = Array(transcript.unicodeScalars)

        var matchIndex: Int?
        for term in terms {
            let termScalars = Array(term.unicodeScalars)
            if let found = firstIndex(of: termScalars, in: lowerScalars) {
                matchIndex = matchIndex.map { min($0, found) } ?? found
            }
        }
        let matchCharacter = matchIndex ?? 0

        let start = max(0, matchCharacter - 100)
        let end = min(matchCharacter + 200, originalScalars.count)
        var context = String(String.UnicodeScalarView(originalScalars[start ..< end]))
        if start > 0 {
            context = "...\(context)"
        }
        if end < originalScalars.count {
            context += "..."
        }
        return context
    }

    private static func firstIndex(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let limit = haystack.count - needle.count
        guard limit >= 0 else { return nil }
        for start in 0 ... limit where Array(haystack[start ..< (start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    /// Batch stamp / reassign / clear `speakerId` on transcript rows (← Rust
    /// `set_transcript_speaker` + `reassign_transcript_speaker`, `speaker.rs:242-277`), ONE
    /// write transaction. `speakerId: nil` clears a row back to unattributed (a manual "no clear
    /// speaker" correction); scoped by `meetingId` so a stale/wrong `transcriptId` can never
    /// touch another meeting's row (mirrors Rust's `meeting_id` guard). Returns the number of
    /// rows actually updated.
    @discardableResult
    public func setSpeakers(
        _ stamps: [(transcriptId: TranscriptID, speakerId: SpeakerID?)],
        inMeeting meetingId: MeetingID
    ) async throws -> Int {
        try await dbWriter.write { db in
            var updated = 0
            for stamp in stamps {
                updated += try TranscriptRecord
                    .filter(Column("id") == stamp.transcriptId.rawValue)
                    .filter(Column("meetingId") == meetingId.rawValue)
                    .updateAll(db, Column("speakerId").set(to: stamp.speakerId?.rawValue))
            }
            return updated
        }
    }

    public func observeAll() -> AsyncStream<[Transcript]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try TranscriptRecord
                .filter(Column("isDeleted") == false)
                .order(Column("timestamp"))
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
