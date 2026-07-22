//
//  TranscriptStamperTests.swift — net-new suite encoding `commands.rs:885-955` rules (plan §5,
//  D4). The Rust `stamp_transcripts` has no `#[cfg(test)]` module; this is the first coverage.
//
import Foundation
import Testing
@testable import AriKit

@Suite("TranscriptStamper")
struct TranscriptStamperTests {
    private func transcript(_ id: String, _ start: Double?, _ end: Double?) -> Transcript {
        Transcript(
            id: TranscriptID(id),
            meetingId: "meeting-1",
            transcript: "text",
            timestamp: "0:00",
            audioStartTime: start,
            audioEndTime: end
        )
    }

    private func segment(
        _ speakerId: String?,
        _ start: Double,
        _ end: Double,
        source: SegmentSource
    ) -> SpeakerSegment {
        SpeakerSegment(
            id: SpeakerSegmentID(UUID().uuidString),
            meetingId: "meeting-1",
            speakerId: speakerId.map { SpeakerID($0) },
            clusterKey: speakerId ?? "unassigned",
            startTime: start,
            endTime: end,
            source: source,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test
    func systemOverlapBeatsLargerMicrophoneOverlap() {
        let t = transcript("t1", 0.0, 10.0)
        let segments = [
            segment("mic-speaker", 0.0, 10.0, source: .microphone),
            segment("sys-speaker", 4.0, 6.0, source: .system),
        ]
        let result = TranscriptStamper.stamp(transcripts: [t], segments: segments)
        #expect(result.unstamped.isEmpty)
        #expect(result.stamps.count == 1)
        #expect(result.stamps[0].speakerId == SpeakerID("sys-speaker"))
    }

    @Test
    func microphoneFallbackOnlyWhenZeroSystemOverlap() {
        let t = transcript("t1", 0.0, 10.0)
        let segments = [
            segment("sys-speaker", 20.0, 30.0, source: .system), // no overlap with row
            segment("mic-speaker", 0.0, 10.0, source: .microphone),
        ]
        let result = TranscriptStamper.stamp(transcripts: [t], segments: segments)
        #expect(result.stamps.count == 1)
        #expect(result.stamps[0].speakerId == SpeakerID("mic-speaker"))
    }

    @Test
    func largerOverlapWinsWithinPool() {
        let t = transcript("t1", 0.0, 10.0)
        let segments = [
            segment("a", 0.0, 3.0, source: .microphone),
            segment("b", 2.0, 10.0, source: .microphone),
        ]
        let result = TranscriptStamper.stamp(transcripts: [t], segments: segments)
        #expect(result.stamps.count == 1)
        #expect(result.stamps[0].speakerId == SpeakerID("b"))
    }

    @Test
    func nearEqualOverlapPrefersShorterSegment() {
        let t = transcript("t1", 0.0, 10.0)
        let segments = [
            // Both segments overlap the row's full 0...10 span exactly (overlap == 10.0), but
            // "longer" extends well past it (dur 20.0) while "shorter" exactly spans it (dur 10.0).
            segment("longer", -10.0, 10.0, source: .microphone),
            segment("shorter", 0.0, 10.0, source: .microphone),
        ]
        let result = TranscriptStamper.stamp(transcripts: [t], segments: segments)
        #expect(result.stamps.count == 1)
        #expect(result.stamps[0].speakerId == SpeakerID("shorter"))
    }

    @Test
    func rowsWithoutAudioTimesGoUnstamped() {
        let t = transcript("t1", nil, nil)
        let segments = [segment("a", 0.0, 10.0, source: .microphone)]
        let result = TranscriptStamper.stamp(transcripts: [t], segments: segments)
        #expect(result.stamps.isEmpty)
        #expect(result.unstamped == [TranscriptID("t1")])
    }

    @Test
    func rowsWithNoOverlapGoUnstamped() {
        let t = transcript("t1", 0.0, 5.0)
        let segments = [segment("a", 10.0, 20.0, source: .microphone)]
        let result = TranscriptStamper.stamp(transcripts: [t], segments: segments)
        #expect(result.stamps.isEmpty)
        #expect(result.unstamped == [TranscriptID("t1")])
    }

    @Test
    func wholeSpanMicrophoneSegmentDoesNotSweepMeeting() {
        let rows = [
            transcript("t1", 0.0, 10.0),
            transcript("t2", 10.0, 20.0),
        ]
        let segments = [
            segment("mic-wide", 0.0, 1_000.0, source: .microphone),
            segment("sys-a", 0.0, 10.0, source: .system),
        ]
        let result = TranscriptStamper.stamp(transcripts: rows, segments: segments)
        #expect(result.stamps.count == 2)
        // Row covered by a system segment prefers the system speaker...
        #expect(result.stamps.first { $0.transcriptId == TranscriptID("t1") }?.speakerId == SpeakerID("sys-a"))
        // ...and only the row nothing else covers falls back to the whole-span mic segment.
        #expect(result.stamps.first { $0.transcriptId == TranscriptID("t2") }?.speakerId == SpeakerID("mic-wide"))
    }

    @Test
    func segmentsWithNilSpeakerIdAreSkipped() {
        let t = transcript("t1", 0.0, 10.0)
        let segments = [
            segment(nil, 0.0, 10.0, source: .system),
            segment("mic-speaker", 0.0, 10.0, source: .microphone),
        ]
        let result = TranscriptStamper.stamp(transcripts: [t], segments: segments)
        #expect(result.stamps.count == 1)
        #expect(result.stamps[0].speakerId == SpeakerID("mic-speaker"))
    }
}
