//
//  HybridSearch.swift — hybrid retrieval: FTS5 BM25 (lexical) ⊕ vector cosine (semantic), fused
//  with reciprocal rank fusion and weighted by meeting recency (plan §5 Slice 4, ← search.rs).
//
//  Returns `TranscriptSearchResult` — the exact shape the legacy keyword search returned — so it
//  drops straight into the (later) orchestrator shell with the entire bounding/prompt/source-
//  safety shell untouched.
//
//  Relevance is scored across ALL indexed chunks (semantic + lexical) BEFORE any cap, and
//  recency is a smooth weight rather than a hard `LIMIT … ORDER BY createdAt DESC` that would
//  evict older-but-relevant meetings before they were ever scored.
//
import Foundation

/// Cross-meeting (`globalSearch`) and series-scoped (`globalSearchScoped`, F9) hybrid retrieval
/// for Ask Meetings. `Sendable` value type over injected repository handles + an embedder — safe
/// to call from any isolation domain.
public struct HybridSearch: Sendable {
    private let recallIndex: RecallIndexRepository
    private let meetings: MeetingRepository
    private let summaries: SummaryRepository
    private let transcripts: TranscriptRepository
    private let embedder: any RecallEmbedder

    public init(
        recallIndex: RecallIndexRepository,
        meetings: MeetingRepository,
        summaries: SummaryRepository,
        transcripts: TranscriptRepository,
        embedder: any RecallEmbedder
    ) {
        self.recallIndex = recallIndex
        self.meetings = meetings
        self.summaries = summaries
        self.transcripts = transcripts
        self.embedder = embedder
    }

    /// Global (cross-meeting) retrieval. Falls back to the legacy keyword search when nothing is
    /// indexed yet (first-run backfill) or when both arms return empty, so Ask never regresses to
    /// worse-than-before behavior (← `global_search`, search.rs:74-79).
    public func globalSearch(_ question: String) async throws -> [TranscriptSearchResult] {
        try await globalSearchInner(question, allowed: nil)
    }

    /// Series-scoped (F9) retrieval. Identical hybrid ranking to `globalSearch`, but every arm's
    /// hits are filtered to chunks whose `meetingId` is in `allowedMeetingIds` BEFORE fusion, so
    /// relevance is scored only within the series (← `global_search_scoped`, search.rs:86-92).
    public func globalSearchScoped(
        _ question: String,
        allowedMeetingIds: Set<MeetingID>
    ) async throws -> [TranscriptSearchResult] {
        try await globalSearchInner(question, allowed: allowedMeetingIds)
    }

    /// Shared implementation for `globalSearch` (no filter) and `globalSearchScoped` (member-
    /// meeting filter) — ← `global_search_inner`, search.rs:97-268.
    private func globalSearchInner(
        _ question: String,
        allowed: Set<MeetingID>?
    ) async throws -> [TranscriptSearchResult] {
        // Scoped search cannot fall back to the keyword LIKE search (which is cross-meeting and
        // cannot honor the member filter). An empty allowed set means the series has no members,
        // so there is nothing to retrieve.
        if let allowed, allowed.isEmpty {
            return []
        }
        func isAllowed(_ meetingId: MeetingID) -> Bool {
            allowed?.contains(meetingId) ?? true
        }

        let indexedCount = try await recallIndex.countChunks()
        if indexedCount == 0 {
            // Only the unscoped (global) path may fall back to the legacy keyword search; the
            // scoped path returns empty rather than leak chunks outside the series.
            if allowed != nil {
                return []
            }
            return try await transcripts.searchTranscripts(matching: question)
        }

        var ranks: [RecallChunkID: Double] = [:]
        var chunkMeeting: [RecallChunkID: MeetingID] = [:]

        // --- Lexical arm (FTS5 BM25) ---
        let terms = Self.ftsTerms(question)
        if let matchQuery = Self.buildMatchQuery(terms) {
            // Best-effort: an FTS failure degrades to lexical-skipped, never fails the whole search.
            if let hits = try? await recallIndex.ftsSearch(
                matchQuery: matchQuery,
                limit: RecallBounds.ftsCandidates
            ) {
                for (rank, hit) in hits.enumerated() {
                    guard isAllowed(hit.meetingId) else { continue }
                    Self.addRRF(&ranks, chunkId: hit.chunkId, rank: rank)
                    chunkMeeting[hit.chunkId] = hit.meetingId
                }
            }
        }

        // --- Semantic arm (vector cosine), best-effort — NEVER fabricates a vector on failure ---
        if let queryVector = try? await embedder.embedQuery(question) {
            if let rows = try? await recallIndex.allEmbeddings() {
                var scored: [(chunkId: RecallChunkID, meetingId: MeetingID, similarity: Float)] =
                    rows.compactMap { row in
                        guard isAllowed(row.meetingId) else { return nil }
                        let vector = Recall.unpackF32(row.embedding)
                        guard vector.count == queryVector.count else { return nil }
                        return (row.chunkId, row.meetingId, Recall.cosine(queryVector, vector))
                    }
                scored.sort { $0.similarity > $1.similarity }
                for (rank, entry) in scored.prefix(RecallBounds.vectorCandidates).enumerated() {
                    Self.addRRF(&ranks, chunkId: entry.chunkId, rank: rank)
                    if chunkMeeting[entry.chunkId] == nil {
                        chunkMeeting[entry.chunkId] = entry.meetingId
                    }
                }
            }
        }

        if ranks.isEmpty {
            // Scoped: no member chunk matched; return empty (no cross-meeting keyword fallback).
            if allowed != nil {
                return []
            }
            return try await transcripts.searchTranscripts(matching: question)
        }

        // --- Recency weighting (per meeting) ---
        let allMeetings = try await meetings.all()
        let now = Date()
        // meetingId -> (title, RFC3339 date, recency weight)
        var meetingMeta: [MeetingID: (title: String, date: String, weight: Double)] = [:]
        for meeting in allMeetings {
            let ageDays = max(0, now.timeIntervalSince(meeting.createdAt)) / 86400.0
            let weight = Self.recencyWeight(ageDays: ageDays)
            meetingMeta[meeting.id] = (meeting.title, RFC3339.string(from: meeting.createdAt), weight)
        }

        var scoredChunks: [(chunkId: RecallChunkID, score: Double)] = ranks.compactMap { chunkId, score in
            // Drop chunks whose parent meeting was soft-deleted (tombstoned): its metadata is
            // absent from `meetingMeta` (built from `meetings.all()`, which excludes deleted rows),
            // so it would otherwise surface as an "Untitled meeting" with no date and leak deleted
            // content into Ask. Delete now also purges the index (`RecallIndexTrigger.purgeOnDelete`),
            // but that purge is a fire-and-forget detached task, so a race window exists between the
            // tombstone write and the purge completing — this query-time filter is the defense-in-depth
            // backstop that closes that window, matching the meetings list, `observeAll()`, and the
            // keyword-fallback's `WHERE m.isDeleted = 0`.
            guard let meetingId = chunkMeeting[chunkId], let meta = meetingMeta[meetingId] else {
                return nil
            }
            return (chunkId, score * meta.weight)
        }
        scoredChunks.sort { $0.score > $1.score }
        scoredChunks = Array(scoredChunks.prefix(RecallBounds.maxHits))

        if scoredChunks.isEmpty {
            // Every ranked chunk belonged to a deleted meeting. Mirror the `ranks.isEmpty` path:
            // global scope may still fall back to the (deleted-filtered) keyword search; scoped
            // recall returns empty rather than leak chunks outside the series.
            if allowed != nil {
                return []
            }
            return try await transcripts.searchTranscripts(matching: question)
        }

        // Fetch the chunk rows we kept.
        let chunkRows = try await recallIndex.chunks(byIds: scoredChunks.map(\.chunkId))
        let chunkById = Dictionary(uniqueKeysWithValues: chunkRows.map { ($0.id, $0) })

        // Fetch summaries once per distinct meeting in the (bounded) result set.
        var summaryByMeeting: [MeetingID: String?] = [:]
        for (chunkId, _) in scoredChunks {
            guard let chunk = chunkById[chunkId] else { continue }
            if summaryByMeeting[chunk.meetingId] == nil {
                let summary = try? await summaries.forMeeting(chunk.meetingId)
                summaryByMeeting[chunk.meetingId] = summary?.bodyMarkdown
            }
        }

        // Map to `TranscriptSearchResult` in score order. `id` = meetingId (repeated across a
        // meeting's chunks); the (later) shell dedups + caps meetings.
        var results: [TranscriptSearchResult] = []
        for (chunkId, _) in scoredChunks {
            guard let chunk = chunkById[chunkId] else { continue }
            let meta = meetingMeta[chunk.meetingId]
            // A summary chunk never carries a real transcript timestamp — stamp it explicitly
            // rather than relying on `timestampLabel` happening to be `nil` (plan
            // ask-meetings-tools-and-cards.md §3.2).
            let timestamp: String = chunk.sourceKind == .summary
                ? "not available"
                : chunk.timestampLabel ?? "not available"
            results.append(TranscriptSearchResult(
                id: chunk.meetingId.rawValue,
                title: meta?.title ?? "Untitled meeting",
                matchContext: chunk.chunkText,
                timestamp: timestamp,
                meetingDate: meta?.date,
                summary: summaryByMeeting[chunk.meetingId] ?? nil
            ))
        }
        return results
    }

    // MARK: - Term extraction / query building (← search.rs:36-69)

    /// Stopwords dropped from the lexical arm's FTS5 query (← `STOP_WORDS`, search.rs:36-40).
    /// Distinct from `TranscriptRepository`'s own (smaller) keyword-fallback stopword list —
    /// the two lists are frozen independently in the Rust source and are NOT unified here.
    static let stopWords: Set<String> = [
        "about", "from", "have", "meetings", "meeting", "that", "this", "what", "when", "where",
        "which", "with", "would", "were", "did", "does", "our", "was", "and", "how", "who", "the",
        "for", "are", "you", "your"
    ]

    /// Extract FTS5 search terms from a free-text question (← `fts_terms`, search.rs:42-52).
    /// Splits on non-alphanumeric Unicode scalars, lowercases, keeps tokens with ≥3 scalars that
    /// are not stopwords, sorts, dedups, and truncates to 16 (`search.rs`'s own cap, distinct from
    /// the keyword-fallback's 12).
    static func ftsTerms(_ query: String) -> [String] {
        let alphanumerics = CharacterSet.alphanumerics
        var terms: [String] = []
        var current: [Unicode.Scalar] = []
        for scalar in Recall.scalars(query) {
            if alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                terms.append(Recall.string(fromScalars: current).lowercased())
                current.removeAll()
            }
        }
        if !current.isEmpty {
            terms.append(Recall.string(fromScalars: current).lowercased())
        }

        var filtered = terms.filter { $0.unicodeScalars.count >= 3 && !stopWords.contains($0) }
        filtered.sort()
        var seen = Set<String>()
        var deduped: [String] = []
        for term in filtered where seen.insert(term).inserted {
            deduped.append(term)
        }
        return Array(deduped.prefix(16))
    }

    /// OR the terms, each double-quoted so FTS5 `MATCH` treats them as literals — prevents FTS
    /// operator injection from user text (← `build_match_query`, search.rs:56-65). Empty terms
    /// skip the lexical arm entirely.
    static func buildMatchQuery(_ terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        let quoted = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
        return quoted.joined(separator: " OR ")
    }

    /// Accumulate one reciprocal-rank-fusion contribution for a chunk (← `add_rrf`,
    /// search.rs:67-69).
    static func addRRF(_ ranks: inout [RecallChunkID: Double], chunkId: RecallChunkID, rank: Int) {
        ranks[chunkId, default: 0] += 1.0 / (RecallBounds.rrfK + Double(rank) + 1.0)
    }

    /// Recency weight for a meeting `ageDays` days old — exponential half-life decay clamped to a
    /// floor (← the inline `weight` expression, search.rs:195-197: `RECENCY_FLOOR.max(0.5f64
    /// .powf(age_days / RECENCY_HALF_LIFE_DAYS))`). Pulled out to an internal `static` helper
    /// (mirroring `ftsTerms`/`buildMatchQuery`) purely so the half-life decay and floor can be
    /// unit-tested directly, without needing to engineer exact BM25/cosine ties in a fixture.
    static func recencyWeight(ageDays: Double) -> Double {
        max(RecallBounds.recencyFloor, pow(0.5, ageDays / RecallBounds.recencyHalfLifeDays))
    }
}
