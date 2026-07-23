//
//  Indexer.swift — build and refresh the recall index (plan §5 Slice 5, ← indexer.rs).
//
//  Indexing is idempotent (a re-run over unchanged transcript text with the same embedder is a
//  no-op) and best-effort about embeddings: if the local embedder is unavailable, the meeting is
//  indexed lexical-only and will be upgraded to embeddings on a later run once the model is
//  present. No Settings layer exists yet (plan §9 decision 1), so "the current model tag" is
//  simply the injected embedder's `modelTag` — there is nothing to invent here.
//
import Foundation
import os

/// Builds/refreshes the recall index for one or all meetings. `Sendable` value type over
/// injected repository handles + an embedder + a shared `ReindexCoordinator` — safe to call from
/// any isolation domain (mirrors `HybridSearch`'s shape).
public struct Indexer: Sendable {
    private static let logger = Logger(subsystem: "com.arivo.ari.AriKit", category: "recall.indexer")

    private let recallIndex: RecallIndexRepository
    private let transcripts: TranscriptRepository
    private let meetings: MeetingRepository
    private let summaries: SummaryRepository
    private let embedder: any RecallEmbedder
    private let coordinator: ReindexCoordinator

    public init(
        recallIndex: RecallIndexRepository,
        transcripts: TranscriptRepository,
        meetings: MeetingRepository,
        summaries: SummaryRepository,
        embedder: any RecallEmbedder,
        coordinator: ReindexCoordinator
    ) {
        self.recallIndex = recallIndex
        self.transcripts = transcripts
        self.meetings = meetings
        self.summaries = summaries
        self.embedder = embedder
        self.coordinator = coordinator
    }

    /// Index one meeting. Logs its own errors and NEVER throws — safe to fire-and-forget from a
    /// detached `Task` after a save (← `index_meeting`, indexer.rs:33).
    public func indexMeeting(_ meetingId: MeetingID) async {
        do {
            try await indexMeetingInner(meetingId)
        } catch {
            Self.logger.warning(
                "recall: failed to index meeting \(meetingId.rawValue, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// ← `index_meeting_inner` (indexer.rs:39-135), extended by plan
    /// `ask-meetings-tools-and-cards.md` §3.2 (Bug B fix): the summary body is now a SECOND chunk
    /// stream, tagged `sourceKind == .summary` so a summary-only fact becomes searchable even
    /// though it never appears verbatim in the raw transcript. The content hash covers BOTH texts,
    /// so a newly-generated/edited summary re-triggers indexing even when the transcript itself is
    /// unchanged.
    private func indexMeetingInner(_ meetingId: MeetingID) async throws {
        let transcriptRows = try await transcripts.forMeeting(meetingId)
        let summary = try await summaries.forMeeting(meetingId)

        let joinedTranscript = transcriptRows
            .map { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let summaryText = summary?.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if joinedTranscript.isEmpty, summaryText.isEmpty {
            // Nothing to index at all — clear any stale index.
            try? await recallIndex.deleteMeeting(meetingId)
            return
        }

        let contentHash = Self.fnv1aHex(joinedTranscript + "\n---\n" + summaryText)
        let wantModel = embedder.modelTag

        // Idempotency: skip only when unchanged AND already fully embedded with this model. A
        // prior lexical-only index (embeddedCount < chunkCount) is intentionally re-run so
        // embeddings fill in once the model becomes available.
        if let state = try? await recallIndex.indexState(meetingId: meetingId),
           state.contentHash == contentHash,
           state.chunkCount > 0,
           state.embeddedCount == state.chunkCount,
           state.embeddingModel == wantModel {
            return
        }

        let transcriptDrafts = Recall.chunkTranscripts(transcriptRows)
        let summaryDrafts = summaryText.isEmpty ? [] : Recall.chunkSummary(summaryText)
        if transcriptDrafts.isEmpty, summaryDrafts.isEmpty {
            try? await recallIndex.deleteMeeting(meetingId)
            return
        }

        // Tag each draft with the stream it came from BEFORE embedding, so the two arrays can be
        // combined into one `embedder.embed(texts)` call (embedding-model consistency, fewer
        // round trips) and split back apart afterward.
        let taggedDrafts: [(draft: ChunkDraft, sourceKind: RecallChunkSourceKind)] =
            transcriptDrafts.map { ($0, .transcript) } + summaryDrafts.map { ($0, .summary) }

        // Embed all chunks (transcript + summary together) in one batch with the injected backend.
        // Best-effort: any failure (embedder unavailable, or a mismatched count) falls back to
        // lexical-only for the whole meeting — never a partial or fabricated set of vectors.
        let texts = taggedDrafts.map(\.draft.text)
        let embeddings: [[Float]]?
        do {
            let vectors = try await embedder.embed(texts)
            if vectors.count == texts.count {
                embeddings = vectors
            } else {
                Self.logger.warning(
                    "recall: embedder returned a mismatched count; indexing \(meetingId.rawValue, privacy: .public) lexical-only"
                )
                embeddings = nil
            }
        } catch {
            Self.logger.warning(
                "recall: embedder unavailable (\(String(describing: error), privacy: .public)); indexing meeting \(meetingId.rawValue, privacy: .public) lexical-only"
            )
            embeddings = nil
        }

        var inputs: [RecallChunkInput] = []
        inputs.reserveCapacity(taggedDrafts.count)
        for (index, tagged) in taggedDrafts.enumerated() {
            let draft = tagged.draft
            let embeddingBytes: Data?
            let dim: Int?
            if let vectors = embeddings {
                embeddingBytes = Recall.packF32(vectors[index])
                dim = vectors[index].count
            } else {
                embeddingBytes = nil
                dim = nil
            }
            inputs.append(RecallChunkInput(
                id: RecallChunkID(UUID().uuidString),
                chunkIndex: draft.chunkIndex,
                chunkText: draft.text,
                startTime: draft.startTime,
                endTime: draft.endTime,
                timestampLabel: draft.timestampLabel,
                embedding: embeddingBytes,
                embeddingModel: dim != nil ? wantModel : nil,
                dim: dim,
                tokenEstimate: draft.tokenEstimate,
                sourceKind: tagged.sourceKind
            ))
        }

        let modelUsed = embeddings != nil ? wantModel : nil
        try await recallIndex.replaceMeetingChunks(
            meetingId: meetingId,
            chunks: inputs,
            contentHash: contentHash,
            embeddingModel: modelUsed,
            now: RFC3339.string(from: Date())
        )
    }

    /// Backfill every meeting that is missing or stale. Self-guarded against overlap via the
    /// shared `ReindexCoordinator`: returns `0` immediately if a backfill is already running.
    /// `force` re-indexes even unchanged meetings (e.g. to embed a vault that was previously
    /// indexed lexical-only) (← `reindex_all`, indexer.rs:154-161).
    public func reindexAll(force: Bool) async throws -> Int {
        guard await coordinator.tryBegin() else {
            return 0
        }
        do {
            let indexed = try await reindexAllInner(force: force)
            await coordinator.end()
            return indexed
        } catch {
            await coordinator.end()
            throw error
        }
    }

    /// ← `reindex_all_inner` (indexer.rs:163-176).
    private func reindexAllInner(force: Bool) async throws -> Int {
        let allMeetings = try await meetings.all()
        var indexed = 0
        for meeting in allMeetings {
            if force {
                try? await recallIndex.deleteMeeting(meeting.id)
            }
            await indexMeeting(meeting.id)
            indexed += 1
        }
        return indexed
    }

    /// FNV-1a (64-bit) hex digest of `text`'s UTF-8 bytes — the exact algorithm/seed from
    /// `indexer.rs:23-30`, so hashes computed by either side match byte-for-byte.
    static func fnv1aHex(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        var hex = String(hash, radix: 16)
        if hex.count < 16 {
            hex = String(repeating: "0", count: 16 - hex.count) + hex
        }
        return hex
    }
}
