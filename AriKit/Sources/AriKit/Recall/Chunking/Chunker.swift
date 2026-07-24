//
//  Chunker.swift — transcript chunking for the recall index (plan §7, ← chunker.rs).
//
//  Split a meeting's ordered transcript segments into overlapping windows suitable for embedding
//  + retrieval. Each chunk carries the recording-relative time span and a display timestamp so a
//  retrieved chunk can cite a moment. Consumes the ported `Models.Transcript`; char counts are in
//  Unicode scalars to match Rust `chars().count()`.
//
import Foundation

/// A drafted chunk (← `ChunkDraft`, chunker.rs:13) — the pre-persistence value the indexer will
/// embed + store. `chunkIndex` is sequential from 0 within a meeting.
public struct ChunkDraft: Codable, Hashable, Sendable {
    public var chunkIndex: Int
    public var text: String
    public var startTime: Double?
    public var endTime: Double?
    public var timestampLabel: String?
    public var tokenEstimate: Int

    public init(
        chunkIndex: Int,
        text: String,
        startTime: Double? = nil,
        endTime: Double? = nil,
        timestampLabel: String? = nil,
        tokenEstimate: Int
    ) {
        self.chunkIndex = chunkIndex
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.timestampLabel = timestampLabel
        self.tokenEstimate = tokenEstimate
    }
}

extension Recall {
    /// Target chunk size in scalars (~500 tokens at ~4 chars/token) (← `TARGET_CHARS`).
    private static let targetChars = 2000
    /// Segments carried into the next chunk so a boundary-spanning fact stays retrievable
    /// (← `OVERLAP_SEGMENTS`).
    private static let overlapSegments = 1

    /// Chunk transcript segments (expected chronological) into overlapping windows
    /// (← `chunk_transcripts`).
    public static func chunkTranscripts(_ segments: [Transcript]) -> [ChunkDraft] {
        var chunks: [ChunkDraft] = []
        var current: [Transcript] = []
        var currentChars = 0
        var index = 0

        for segment in segments {
            let text = segment.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                continue
            }
            current.append(segment)
            currentChars += text.unicodeScalars.count

            if currentChars >= targetChars {
                if let draft = buildChunk(index: index, segments: current) {
                    chunks.append(draft)
                    index += 1
                }
                let keepFrom = current.count - min(current.count, overlapSegments)
                current = Array(current[keepFrom...])
                currentChars = current.reduce(0) {
                    $0 + $1.transcript.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
                }
            }
        }

        // Flush the tail, unless it is only the carried-over overlap (already covered).
        let isPureOverlap = !chunks.isEmpty && current.count <= overlapSegments
        if !current.isEmpty, !isPureOverlap {
            if let draft = buildChunk(index: index, segments: current) {
                chunks.append(draft)
            }
        }

        return chunks
    }

    /// Chunk a meeting's generated summary body into overlapping windows, mirroring
    /// `chunkTranscripts`'s target-size/overlap behavior but over one plain document rather than N
    /// ordered transcript segments (plan `ask-meetings-tools-and-cards.md` §3.2). No timestamp is
    /// ever attached — a summary chunk has no meaningful recording-relative time span, and this
    /// function stays summary-agnostic about WHY it's being called: it is the caller (`Indexer`)
    /// that tags the resulting drafts with `sourceKind == .summary`, not `Chunker` itself.
    public static func chunkSummary(_ bodyMarkdown: String) -> [ChunkDraft] {
        let paragraphs = bodyMarkdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [] }

        var chunks: [ChunkDraft] = []
        var current: [String] = []
        var currentChars = 0
        var index = 0

        func flush() {
            let text = current.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(ChunkDraft(
                    chunkIndex: index,
                    text: text,
                    tokenEstimate: text.unicodeScalars.count / 4
                ))
                index += 1
            }
        }

        for paragraph in paragraphs {
            current.append(paragraph)
            currentChars += paragraph.unicodeScalars.count
            if currentChars >= targetChars {
                flush()
                let keepFrom = current.count - min(current.count, overlapSegments)
                current = Array(current[keepFrom...])
                currentChars = current.reduce(0) { $0 + $1.unicodeScalars.count }
            }
        }

        let isPureOverlap = !chunks.isEmpty && current.count <= overlapSegments
        if !current.isEmpty, !isPureOverlap {
            flush()
        }

        return chunks
    }

    private static func buildChunk(index: Int, segments: [Transcript]) -> ChunkDraft? {
        let text = segments
            .map { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        let startTime = segments.lazy.compactMap(\.audioStartTime).first
        let endTime = segments.reversed().lazy.compactMap(\.audioEndTime).first
        let timestampLabel = segments
            .first { !$0.timestamp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.timestamp.trimmingCharacters(in: .whitespacesAndNewlines) }
        let tokenEstimate = text.unicodeScalars.count / 4
        return ChunkDraft(
            chunkIndex: index,
            text: text,
            startTime: startTime,
            endTime: endTime,
            timestampLabel: timestampLabel,
            tokenEstimate: tokenEstimate
        )
    }
}
