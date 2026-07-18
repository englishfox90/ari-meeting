//
//  ChunkerTests.swift — plan §6 Slice 1 test 7.
//
//  1:1 port of every Rust `chunker.rs` test (chunker.rs:109-136).
//
import Testing
@testable import AriKit

@Suite struct ChunkerTests {
    /// Mirror of the Rust `seg(id, text, start)` fixture builder (chunker.rs:93).
    private func seg(_ id: String, _ text: String, _ start: Double) -> Transcript {
        let whole = Int(start)
        let label = String(format: "%02d:%02d", whole / 60, whole % 60)
        return Transcript(
            id: TranscriptID(id),
            meetingId: "m1",
            transcript: text,
            timestamp: label,
            audioStartTime: start,
            audioEndTime: start + 5.0,
            duration: 5.0
        )
    }

    @Test func shortTranscriptMakesOneChunkWithTimeSpan() {
        let segments = [seg("a", "hello world", 0.0), seg("b", "second line", 6.0)]
        let chunks = Recall.chunkTranscripts(segments)
        #expect(chunks.count == 1)
        #expect(chunks[0].startTime == 0.0)
        #expect(chunks[0].endTime == 11.0)
        #expect(chunks[0].timestampLabel == "00:00")
        #expect(chunks[0].text.contains("hello world"))
        #expect(chunks[0].text.contains("second line"))
    }

    @Test func longTranscriptSplitsIntoMultipleChunks() {
        let big = String(repeating: "word ", count: 500) // ~2500 chars
        let segments = [seg("a", big, 0.0), seg("b", big, 60.0), seg("c", "tail", 120.0)]
        let chunks = Recall.chunkTranscripts(segments)
        #expect(chunks.count >= 2)
        // Indices are sequential from 0.
        for (expected, chunk) in chunks.enumerated() {
            #expect(chunk.chunkIndex == expected)
        }
    }

    @Test func emptyInputYieldsNoChunks() {
        #expect(Recall.chunkTranscripts([]).isEmpty)
    }
}
