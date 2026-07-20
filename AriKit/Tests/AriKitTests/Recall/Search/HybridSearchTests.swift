//
//  HybridSearchTests.swift — plan §6 `HybridSearchTests` (Recall Slice 4, ← search.rs).
//
//  Dual-run parity: a deterministic stub embedder + hand-seeded FTS/vector fixtures let every
//  assertion be computed BY HAND from the RRF formula `1/(rrfK + rank + 1)` (rrfK = 60), matching
//  `search.rs`'s `add_rrf` exactly. No real embedding model is ever invoked in this suite.
//
import Foundation
import Testing
@testable import AriKit

@Suite("Hybrid search (RRF) — Recall Slice 4")
struct HybridSearchTests {

    // MARK: - Fixtures

    /// Ignores its input text entirely and returns the same preset vector for every document —
    /// enough for these tests, since `HybridSearch` only ever calls `embedQuery`, never `embed`
    /// on real chunk text (chunk embeddings are seeded directly into the index as packed bytes).
    private struct FixedVectorEmbedder: RecallEmbedder {
        let vector: [Float]
        let modelTag = "stub-fixed"
        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in vector }
        }
    }

    /// Fails every embed call — models the local embedder being unavailable mid-search. The
    /// semantic arm must degrade to lexical-only, never crash and never fabricate a vector.
    private struct ThrowingEmbedder: RecallEmbedder {
        struct Unavailable: Error {}
        let modelTag = "stub-throwing"
        func embed(_: [String]) async throws -> [[Float]] {
            throw Unavailable()
        }
    }

    private func makeMeeting(
        id: String,
        title: String = "Fixture meeting",
        createdAt: Date = Date()
    ) -> Meeting {
        Meeting(id: MeetingID(id), title: title, createdAt: createdAt, updatedAt: createdAt)
    }

    private func makeSearch(
        _ db: AppDatabase,
        embedderVector: [Float] = [1, 0]
    ) -> HybridSearch {
        HybridSearch(
            recallIndex: db.recallIndex,
            meetings: db.meetings,
            summaries: db.summaries,
            transcripts: db.transcripts,
            embedder: FixedVectorEmbedder(vector: embedderVector)
        )
    }

    // MARK: - 1. RRF fusion (overlapping lexical + semantic hits)

    @Test("RRF fuses lexical + semantic ranks; hand-computed order matches search.rs's add_rrf")
    func rrfFusionMatchesHandComputedOrder() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "meeting-rrf")
        try await db.meetings.upsert(meeting)

        // chunkA: strong lexical-only hit (tf("gizmo") = 20 in a similarly-sized document to
        // chunkB, so BM25's monotonic-in-tf property gives it FTS rank 0 over chunkB's tf = 1).
        // No embedding — absent from the vector arm entirely.
        let chunkA = RecallChunkInput(
            id: RecallChunkID("chunk-a"),
            chunkIndex: 0,
            chunkText: String(repeating: "gizmo ", count: 20) + "quarterly review notes."
        )
        // chunkB: weak lexical hit (tf("gizmo") = 1, FTS rank 1) AND the best semantic hit
        // (embedding == query vector, cosine 1.0, vector rank 0) — the overlap chunk.
        let chunkB = RecallChunkInput(
            id: RecallChunkID("chunk-b"),
            chunkIndex: 1,
            chunkText: "The gizmo appeared once during the review of quarterly plans and " +
                "nothing else stood out really at all today for the whole team.",
            embedding: Recall.packF32([1, 0]),
            embeddingModel: "stub-fixed",
            dim: 2
        )
        // chunkC: vector-only hit, orthogonal to the query (cosine 0.0, vector rank 1). No
        // "gizmo" anywhere in its text, so it never enters the lexical arm.
        let chunkC = RecallChunkInput(
            id: RecallChunkID("chunk-c"),
            chunkIndex: 2,
            chunkText: "Completely unrelated notes about budgeting and travel logistics.",
            embedding: Recall.packF32([0, 1]),
            embeddingModel: "stub-fixed",
            dim: 2
        )

        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [chunkA, chunkB, chunkC],
            contentHash: "hash-rrf",
            embeddingModel: "stub-fixed",
            now: "2026-07-20T00:00:00Z"
        )

        // Ground truth for the lexical arm's rank ordering, from the SAME repository call
        // `HybridSearch` itself makes — avoids re-deriving SQLite's exact bm25() arithmetic here.
        let ftsHits = try await db.recallIndex.ftsSearch(matchQuery: "\"gizmo\"", limit: 48)
        #expect(ftsHits.map(\.chunkId) == [chunkA.id, chunkB.id])

        // Hand-computed RRF (rrfK = 60, contribution = 1 / (60 + rank + 1)):
        //   chunkA: FTS rank 0                       -> 1/61              ≈ 0.0163934
        //   chunkB: FTS rank 1 + vector rank 0        -> 1/62 + 1/61       ≈ 0.0325225
        //   chunkC: vector rank 1                     -> 1/62              ≈ 0.0161290
        // A single meeting means every chunk gets the SAME recency multiplier, so this raw
        // ordering survives recency weighting unchanged: B > A > C.
        let search = makeSearch(db, embedderVector: [1, 0])
        let results = try await search.globalSearch("gizmo")

        #expect(results.count == 3)
        #expect(results[0].matchContext == chunkB.chunkText)
        #expect(results[1].matchContext == chunkA.chunkText)
        #expect(results[2].matchContext == chunkC.chunkText)
        #expect(results.allSatisfy { $0.id == meeting.id.rawValue })
    }

    // MARK: - 2. Recency weighting

    @Test("Recency: equal raw RRF, newer meeting outranks an older one")
    func recencyBreaksATieInFavorOfTheNewerMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        let now = Date()
        let meetingNew = makeMeeting(id: "meeting-new", title: "New meeting", createdAt: now)
        let meetingOld = makeMeeting(
            id: "meeting-old",
            title: "Old meeting",
            createdAt: now.addingTimeInterval(-300 * 86400)
        )
        try await db.meetings.upsert(meetingNew)
        try await db.meetings.upsert(meetingOld)

        // chunkNew: sole lexical hit for a term that appears nowhere else -> FTS rank 0.
        let chunkNew = RecallChunkInput(
            id: RecallChunkID("chunk-new"),
            chunkIndex: 0,
            chunkText: "The zephyrus initiative kicked off this quarter."
        )
        // chunkOld: no lexical match at all for the query term; sole vector hit (cosine 1.0
        // against the fixed query vector) -> vector rank 0.
        let chunkOld = RecallChunkInput(
            id: RecallChunkID("chunk-old"),
            chunkIndex: 0,
            chunkText: "Unrelated notes with no matching keyword whatsoever.",
            embedding: Recall.packF32([1, 0]),
            embeddingModel: "stub-fixed",
            dim: 2
        )

        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meetingNew.id,
            chunks: [chunkNew],
            contentHash: "hash-new",
            embeddingModel: nil,
            now: "2026-07-20T00:00:00Z"
        )
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meetingOld.id,
            chunks: [chunkOld],
            contentHash: "hash-old",
            embeddingModel: "stub-fixed",
            now: "2026-07-20T00:00:00Z"
        )

        // Both chunks land at rank 0 in their own (disjoint) arm, so their raw RRF contribution
        // is EXACTLY equal (1/61 each) before recency is applied — isolating recency as the only
        // variable that can determine the final order.
        let search = makeSearch(db, embedderVector: [1, 0])
        let results = try await search.globalSearch("zephyrus")

        #expect(results.count == 2)
        #expect(results[0].matchContext == chunkNew.chunkText)
        #expect(results[1].matchContext == chunkOld.chunkText)
    }

    @Test("Recency weight: half-life decay, floored at 0.35, never suppressed further with age")
    func recencyWeightHalfLifeAndFloor() {
        #expect(HybridSearch.recencyWeight(ageDays: 0) == 1.0)
        // One half-life (45 days): weight halves exactly.
        #expect(abs(HybridSearch.recencyWeight(ageDays: 45) - 0.5) < 1e-9)
        // Two half-lives (90 days) would naively be 0.25, which is BELOW the 0.35 floor — the
        // floor must win.
        #expect(HybridSearch.recencyWeight(ageDays: 90) == 0.35)
        // Arbitrarily ancient (2000x the half-life): still exactly the floor, never lower.
        #expect(HybridSearch.recencyWeight(ageDays: 45 * 2000) == 0.35)
    }

    // MARK: - 3. Keyword-LIKE fallback (unscoped, nothing indexed yet)

    @Test("Fallback: empty recall index + seeded transcripts -> keyword-LIKE results, unscoped")
    func fallsBackToKeywordSearchWhenNothingIsIndexed() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "fallback-1", title: "Retro session")
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("transcript-1"),
            meetingId: meeting.id,
            transcript: "We decided to postpone the widgets rollout until next quarter.",
            timestamp: "00:10"
        ))

        // Nothing was ever indexed (`countChunks() == 0`), so `globalSearch` must delegate to
        // `TranscriptRepository.searchTranscripts` rather than returning empty.
        let search = makeSearch(db)
        let results = try await search.globalSearch("What did we decide about widgets?")

        #expect(results.count == 1)
        #expect(results[0].id == meeting.id.rawValue)
        #expect(results[0].matchContext.contains("widgets rollout"))
    }

    // MARK: - 4. Series scoping — never leaks outside the allowed set

    @Test("Scoped search excludes chunks whose meeting is outside allowedMeetingIds")
    func scopedSearchExcludesDisallowedMeetings() async throws {
        let db = try AppDatabase.makeInMemory()
        let allowedMeeting = makeMeeting(id: "series-member")
        let disallowedMeeting = makeMeeting(id: "series-outsider")
        try await db.meetings.upsert(allowedMeeting)
        try await db.meetings.upsert(disallowedMeeting)

        let allowedChunk = RecallChunkInput(
            id: RecallChunkID("allowed-chunk"),
            chunkIndex: 0,
            chunkText: "The signal strength was strong during the member meeting."
        )
        let disallowedChunk = RecallChunkInput(
            id: RecallChunkID("disallowed-chunk"),
            chunkIndex: 0,
            chunkText: "A signal was also mentioned in the outsider meeting."
        )
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: allowedMeeting.id,
            chunks: [allowedChunk],
            contentHash: "hash-allowed",
            embeddingModel: nil,
            now: "2026-07-20T00:00:00Z"
        )
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: disallowedMeeting.id,
            chunks: [disallowedChunk],
            contentHash: "hash-disallowed",
            embeddingModel: nil,
            now: "2026-07-20T00:00:00Z"
        )

        let search = makeSearch(db)
        let results = try await search.globalSearchScoped(
            "signal",
            allowedMeetingIds: [allowedMeeting.id]
        )

        #expect(results.count == 1)
        #expect(results[0].id == allowedMeeting.id.rawValue)
        #expect(results[0].matchContext == allowedChunk.chunkText)
    }

    @Test("Scoped search with an empty allowed set returns empty immediately")
    func scopedSearchWithEmptyAllowedSetReturnsEmpty() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "some-meeting")
        try await db.meetings.upsert(meeting)
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [
                RecallChunkInput(id: RecallChunkID("c-1"), chunkIndex: 0, chunkText: "some content")
            ],
            contentHash: "hash-x",
            embeddingModel: nil,
            now: "2026-07-20T00:00:00Z"
        )

        let search = makeSearch(db)
        let results = try await search.globalSearchScoped("some", allowedMeetingIds: [])
        #expect(results.isEmpty)
    }

    @Test("Scoped search over an empty index returns empty — never leaks via keyword fallback")
    func scopedSearchOverEmptyIndexDoesNotLeakViaFallback() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "unindexed-meeting")
        try await db.meetings.upsert(meeting)
        // Seed a transcript that WOULD match the keyword-LIKE fallback, to prove the scoped path
        // does not accidentally take it (unlike the unscoped path in test 3).
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("transcript-scoped"),
            meetingId: meeting.id,
            transcript: "We decided to postpone the widgets rollout until next quarter.",
            timestamp: "00:10"
        ))

        let search = makeSearch(db)
        let results = try await search.globalSearchScoped(
            "What did we decide about widgets?",
            allowedMeetingIds: [meeting.id]
        )
        #expect(results.isEmpty)
    }

    // MARK: - 5. Term extraction / stopword / match-query helpers

    @Test("ftsTerms drops stopwords and sub-3-character tokens, dedups, sorts, truncates to 16")
    func ftsTermsFiltersDedupsSortsAndTruncates() {
        let terms = HybridSearch.ftsTerms("What did we decide about the microphone and audio audio?")
        // "what"/"did"/"we"/"about"/"the"/"and" are stopwords or too short; "audio" is repeated.
        #expect(terms == ["audio", "decide", "microphone"])
    }

    @Test("ftsTerms truncates to at most 16 terms")
    func ftsTermsTruncatesToSixteen() {
        let words = (0 ..< 20).map { "keyword\($0)" }
        let terms = HybridSearch.ftsTerms(words.joined(separator: " "))
        #expect(terms.count == 16)
    }

    @Test("buildMatchQuery ORs double-quoted literal terms; empty terms yields nil")
    func buildMatchQueryQuotesAndOrsTerms() {
        #expect(HybridSearch.buildMatchQuery([]) == nil)
        #expect(HybridSearch.buildMatchQuery(["alpha"]) == "\"alpha\"")
        #expect(HybridSearch.buildMatchQuery(["alpha", "beta"]) == "\"alpha\" OR \"beta\"")
    }

    @Test("buildMatchQuery strips embedded quotes to prevent FTS operator injection")
    func buildMatchQueryStripsEmbeddedQuotes() {
        #expect(HybridSearch.buildMatchQuery(["al\"pha"]) == "\"alpha\"")
    }

    @Test("addRRF accumulates 1/(rrfK + rank + 1) contributions across multiple calls")
    func addRRFAccumulatesContributions() throws {
        var ranks: [RecallChunkID: Double] = [:]
        let chunkId = RecallChunkID("chunk-1")
        HybridSearch.addRRF(&ranks, chunkId: chunkId, rank: 0)
        HybridSearch.addRRF(&ranks, chunkId: chunkId, rank: 1)
        let expected = 1.0 / (60.0 + 0 + 1) + 1.0 / (60.0 + 1 + 1)
        #expect(try abs(#require(ranks[chunkId]) - expected) < 1e-12)
    }

    // MARK: - 6. Best-effort semantic arm (No-Fake-State, §7)

    @Test("Embedder failure degrades to lexical-only; results still returned, never fabricated")
    func embedderFailureDegradesToLexicalOnly() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "degrade-1", title: "Planning")
        try await db.meetings.upsert(meeting)

        // An indexed chunk (so countChunks() > 0 — we are NOT on the empty-index fallback path)
        // that matches the query lexically. It has NO embedding, so the only way it can surface is
        // the FTS arm continuing after the semantic arm throws.
        try await db.recallIndex.replaceMeetingChunks(
            meetingId: meeting.id,
            chunks: [
                RecallChunkInput(
                    id: RecallChunkID("degrade-chunk"),
                    chunkIndex: 0,
                    chunkText: "The widget rollout timeline was finalized in this planning session."
                )
            ],
            contentHash: "hash-degrade",
            embeddingModel: nil,
            now: "2026-07-20T00:00:00Z"
        )

        // The embedder throws on every call — the semantic arm must be skipped silently, not
        // crash the search and not inject a placeholder vector.
        let search = HybridSearch(
            recallIndex: db.recallIndex,
            meetings: db.meetings,
            summaries: db.summaries,
            transcripts: db.transcripts,
            embedder: ThrowingEmbedder()
        )
        let results = try await search.globalSearch("widget rollout")

        #expect(results.count == 1)
        #expect(results[0].id == meeting.id.rawValue)
        #expect(results[0].matchContext.contains("widget rollout"))
    }
}
