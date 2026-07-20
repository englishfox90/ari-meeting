//
//  TranscriptMappingTests.swift — plan §6 Slice D (segment → Transcript, pure/headless).
//
import Foundation
import Testing
@testable import AriKit

struct TranscriptMappingTests {
    private let meetingId = MeetingID("meeting-1")

    @Test func mapsTimesAndDurationFromSegment() {
        let segment = TranscriptionSegment(
            text: "hello world",
            startSec: 12.0,
            endSec: 15.5,
            confidence: 0.9,
            words: []
        )

        let transcript = TranscriptMapping.transcript(from: segment, meetingId: meetingId)

        #expect(transcript.meetingId == meetingId)
        #expect(transcript.transcript == "hello world")
        #expect(transcript.audioStartTime == 12.0)
        #expect(transcript.audioEndTime == 15.5)
        #expect(transcript.duration == 3.5)
    }

    @Test func speakerIdIsAlwaysNil() {
        let segment = TranscriptionSegment(
            text: "who said this",
            startSec: 0,
            endSec: 1,
            confidence: nil,
            words: []
        )

        let transcript = TranscriptMapping.transcript(from: segment, meetingId: meetingId)

        #expect(transcript.speakerId == nil)
    }

    @Test func derivesMMSSLabelFromStartSeconds() {
        let cases: [(Double, String)] = [
            (0, "00:00"),
            (5, "00:05"),
            (65, "01:05"),
            (600, "10:00"),
            (12.9, "00:12")
        ]

        for (start, expectedLabel) in cases {
            let segment = TranscriptionSegment(
                text: "x",
                startSec: start,
                endSec: start + 1,
                confidence: nil,
                words: []
            )
            let transcript = TranscriptMapping.transcript(from: segment, meetingId: meetingId)
            #expect(transcript.timestamp == expectedLabel)
        }
    }

    @Test func emptyTextSegmentMapsToEmptyTranscriptVerbatim() {
        let segment = TranscriptionSegment(
            text: "",
            startSec: 3,
            endSec: 4,
            confidence: nil,
            words: []
        )

        let transcript = TranscriptMapping.transcript(from: segment, meetingId: meetingId)

        #expect(transcript.transcript.isEmpty)
        #expect(transcript.audioStartTime == 3)
        #expect(transcript.audioEndTime == 4)
        #expect(transcript.duration == 1)
        #expect(transcript.speakerId == nil)
    }

    @Test func eachMappedTranscriptGetsAFreshID() {
        let segment = TranscriptionSegment(text: "same segment", startSec: 0, endSec: 1, confidence: nil, words: [])

        let first = TranscriptMapping.transcript(from: segment, meetingId: meetingId)
        let second = TranscriptMapping.transcript(from: segment, meetingId: meetingId)

        #expect(first.id != second.id)
    }

    @Test func batchHelperMapsAllSegmentsInOrder() {
        let segments = [
            TranscriptionSegment(text: "first", startSec: 0, endSec: 2, confidence: nil, words: []),
            TranscriptionSegment(text: "", startSec: 2, endSec: 2.5, confidence: nil, words: []),
            TranscriptionSegment(text: "third", startSec: 10, endSec: 12, confidence: 0.5, words: [])
        ]

        let transcripts = TranscriptMapping.transcripts(from: segments, meetingId: meetingId)

        #expect(transcripts.count == 3)
        #expect(transcripts[0].transcript == "first")
        #expect(transcripts[0].timestamp == "00:00")
        #expect(transcripts[1].transcript.isEmpty)
        #expect(transcripts[1].timestamp == "00:02")
        #expect(transcripts[2].transcript == "third")
        #expect(transcripts[2].timestamp == "00:10")
        #expect(transcripts.allSatisfy { $0.meetingId == meetingId })
        #expect(transcripts.allSatisfy { $0.speakerId == nil })
    }
}
