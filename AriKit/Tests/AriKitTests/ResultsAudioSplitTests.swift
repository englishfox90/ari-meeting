//
//  ResultsAudioSplitTests.swift — plan §5 test 6.
//
//  The results/audio split (migration principle 5, plan §6): a meeting references its audio by a
//  device-local path (`LocalAudioReference`), never as bytes on a synced domain type. This suite
//  asserts (via Codable-key reflection over one instance of every domain type) that **no** domain
//  type carries an audio `Data` field. The two small model vectors — `Speaker.centroid` and
//  `SpeakerSegment.embedding` — are explicitly exempt (voiceprint vectors, not audio).
//
import Foundation
import Testing
@testable import AriKit

@Suite struct ResultsAudioSplitTests {
    /// Stored properties permitted to be `Data` — model vectors, not audio.
    private static let exemptDataFields: Set<String> = ["centroid", "embedding"]

    @Test func meetingAudioReferenceIsPathNotBytes() throws {
        let meeting = try FixtureLoader.decode(Meeting.self, from: "meeting")
        let reference = try #require(meeting.audioReference)
        #expect(reference.path == "/Users/owner/Recordings/meeting-1")
        // The reference wraps a String path; it is not a Data blob.
        #expect(!(reference.path is Data))
    }

    @Test func noDomainTypeCarriesAudioData() {
        assertNoUnexpectedData(ModelSamples.meeting)
        assertNoUnexpectedData(ModelSamples.transcript)
        assertNoUnexpectedData(ModelSamples.speaker)
        assertNoUnexpectedData(ModelSamples.speakerSegment)
        assertNoUnexpectedData(ModelSamples.person)
        assertNoUnexpectedData(ModelSamples.profileFact)
        assertNoUnexpectedData(ModelSamples.profileFactSource)
        assertNoUnexpectedData(ModelSamples.series)
        assertNoUnexpectedData(ModelSamples.attendee)
        assertNoUnexpectedData(ModelSamples.calendarEvent)
    }

    /// Fails if any stored property is `Data`/`Data?` other than the exempt model-vector fields.
    private func assertNoUnexpectedData(_ value: some Any, sourceLocation: SourceLocation = #_sourceLocation) {
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            guard let label = child.label else { continue }
            let typeName = String(describing: type(of: child.value))
            let isDataLike = typeName == "Data" || typeName == "Optional<Data>"
            if isDataLike {
                #expect(
                    Self.exemptDataFields.contains(label),
                    "Unexpected audio-shaped Data field '\(label)' on \(type(of: value))",
                    sourceLocation: sourceLocation
                )
            }
        }
    }
}
