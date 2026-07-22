//
//  SpeakerSamplesTests.swift — speaker sample selection (port of the frozen Rust/React
//  `frontend/src/lib/speaker-samples.test.ts` contract).
//
import AriKit
import Testing
@testable import AriViewModels

@Suite("SpeakerSamples")
struct SpeakerSamplesTests {

    private static let meeting = MeetingID("m1")
    private static let speaker = SpeakerID("s1")
    private static let other = SpeakerID("s2")

    private static func row(
        _ id: String,
        text: String,
        start: Double?,
        end: Double? = nil,
        speakerId: SpeakerID? = speaker
    ) -> Transcript {
        Transcript(
            id: TranscriptID(id),
            meetingId: meeting,
            transcript: text,
            timestamp: "0",
            audioStartTime: start,
            audioEndTime: end,
            speakerId: speakerId
        )
    }

    @Test("the longest lines win the cap")
    func longestLinesWin() {
        let rows = [
            Self.row("1", text: "short", start: 10),
            Self.row("2", text: "a much longer and more substantive line of speech", start: 20),
            Self.row("3", text: "mid length line here", start: 30),
        ]
        let samples = SpeakerSamples.select(from: rows, speakerId: Self.speaker, max: 2)
        let ids = Set(samples.map { $0.id })
        #expect(ids == [TranscriptID("2"), TranscriptID("3")])
    }

    @Test("kept samples are re-sorted chronologically, not by length")
    func keptSamplesAreChronological() {
        let rows = [
            Self.row("1", text: "a much longer and more substantive line of speech", start: 30),
            Self.row("2", text: "mid length line here", start: 10),
            Self.row("3", text: "another sizeable chunk of substantive speech", start: 20),
        ]
        let samples = SpeakerSamples.select(from: rows, speakerId: Self.speaker, max: 3)
        #expect(samples.map { $0.startSeconds } == [10, 20, 30])
    }

    @Test("empty and whitespace-only text is excluded")
    func emptyAndWhitespaceTextExcluded() {
        let rows = [
            Self.row("1", text: "", start: 10),
            Self.row("2", text: "   \n\t  ", start: 20),
            Self.row("3", text: "real content here", start: 30),
        ]
        let samples = SpeakerSamples.select(from: rows, speakerId: Self.speaker)
        #expect(samples.map { $0.id } == [TranscriptID("3")])
    }

    @Test("endSeconds is carried from audioEndTime, nil when absent")
    func endSecondsCarriedFromAudioEndTime() {
        let rows = [
            Self.row("1", text: "has a known end", start: 10, end: 15),
            Self.row("2", text: "has no known end", start: 20, end: nil),
        ]
        let samples = SpeakerSamples.select(from: rows, speakerId: Self.speaker)
        #expect(samples.first { $0.id == TranscriptID("1") }?.endSeconds == 15)
        #expect(samples.first { $0.id == TranscriptID("2") }?.endSeconds == nil)
    }

    @Test("rows without an audio start time are excluded")
    func rowsWithoutAudioTimeExcluded() {
        let rows = [
            Self.row("1", text: "has no audio timing", start: nil),
            Self.row("2", text: "has audio timing", start: 5),
        ]
        let samples = SpeakerSamples.select(from: rows, speakerId: Self.speaker)
        #expect(samples.map { $0.id } == [TranscriptID("2")])
    }

    @Test("the cap is respected even with many qualifying rows")
    func capRespected() {
        let rows = (0..<10).map { i in
            Self.row("\(i)", text: "line number \(i) with some words in it", start: Double(i))
        }
        let samples = SpeakerSamples.select(from: rows, speakerId: Self.speaker, max: 5)
        #expect(samples.count == 5)
    }

    @Test("group() covers every stamped speaker")
    func groupCoversAllStampedSpeakers() {
        let rows = [
            Self.row("1", text: "hello from speaker one", start: 10, speakerId: Self.speaker),
            Self.row("2", text: "hello from speaker two", start: 20, speakerId: Self.other),
        ]
        let grouped = SpeakerSamples.group(from: rows)
        #expect(Set(grouped.keys) == [Self.speaker, Self.other])
        #expect(grouped[Self.speaker]?.count == 1)
        #expect(grouped[Self.other]?.count == 1)
    }

    @Test("rows with no speakerId are ignored entirely")
    func unstampedRowsIgnored() {
        let rows = [
            Self.row("1", text: "unattributed line", start: 10, speakerId: nil),
            Self.row("2", text: "attributed line", start: 20, speakerId: Self.speaker),
        ]
        let grouped = SpeakerSamples.group(from: rows)
        #expect(grouped.keys.count == 1)
        #expect(grouped[Self.speaker]?.map { $0.id } == [TranscriptID("2")])
    }
}
