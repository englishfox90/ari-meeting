//
//  ModelsCodableTests.swift — plan §5 test 2.
//
//  Two guarantees per included domain type:
//  1. Codable round-trip: `decode(encode(x)) == x` through the shared `Models.jsonDecoder` /
//     `Models.jsonEncoder`.
//  2. Wire-fixture parity: the hand-authored camelCase engine JSON (Fixtures/) decodes to the
//     expected value. These fixtures are placeholders for captured live engine JSON (see
//     Fixtures/README.md).
//
import Foundation
import Testing
@testable import AriKit

struct ModelsCodableTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let encoded = try Models.jsonEncoder.encode(value)
        let decoded = try Models.jsonDecoder.decode(T.self, from: encoded)
        #expect(decoded == value)
    }

    // MARK: - Round-trip (every included type)

    @Test func roundTripsAllTypes() throws {
        try roundTrip(ModelSamples.meeting)
        try roundTrip(ModelSamples.transcript)
        try roundTrip(ModelSamples.speaker)
        try roundTrip(ModelSamples.speakerSegment)
        try roundTrip(ModelSamples.person)
        try roundTrip(ModelSamples.profileFact)
        try roundTrip(ModelSamples.profileFactSource)
        try roundTrip(ModelSamples.profileFactWithProvenance)
        try roundTrip(ModelSamples.series)
        try roundTrip(ModelSamples.attendee)
        try roundTrip(ModelSamples.calendarEvent)
        try roundTrip(ModelSamples.summary)
        try roundTrip(ModelSamples.meetingNote)
    }

    // MARK: - Wire-fixture parity

    @Test func meetingFixtureDecodes() throws {
        #expect(try FixtureLoader.decode(Meeting.self, from: "meeting") == ModelSamples.meeting)
    }

    @Test func transcriptFixtureDecodes() throws {
        #expect(
            try FixtureLoader.decode(Transcript.self, from: "transcript") == ModelSamples.transcript
        )
    }

    @Test func speakerFixtureDecodes() throws {
        #expect(try FixtureLoader.decode(Speaker.self, from: "speaker") == ModelSamples.speaker)
    }

    @Test func speakerSegmentFixtureDecodes() throws {
        #expect(
            try FixtureLoader.decode(SpeakerSegment.self, from: "speakerSegment")
                == ModelSamples.speakerSegment
        )
    }

    @Test func personFixtureDecodes() throws {
        #expect(try FixtureLoader.decode(Person.self, from: "person") == ModelSamples.person)
    }

    @Test func profileFactFixtureDecodes() throws {
        // Asserts the `sourceKind` wire key maps to the `origin` property (plan §7.2 rename).
        let fact = try FixtureLoader.decode(ProfileFact.self, from: "profileFact")
        #expect(fact == ModelSamples.profileFact)
        #expect(fact.origin == .selfReported)
    }

    @Test func profileFactSourceFixtureDecodes() throws {
        let source = try FixtureLoader.decode(ProfileFactSource.self, from: "profileFactSource")
        #expect(source == ModelSamples.profileFactSource)
        #expect(source.origin == .selfReported)
    }

    @Test func seriesFixtureDecodes() throws {
        // `ownerPersonId`/`createdAt`/`updatedAt` are Store-port follow-ons (plan §4.7) never
        // present on the frozen engine's wire `SeriesSummary`/`SeriesDetail` — this fixture is
        // synthetic for those three keys, standing in for a Store-persisted `Series` rather than
        // literal captured IPC JSON (see `Series.swift`'s header).
        #expect(try FixtureLoader.decode(Series.self, from: "series") == ModelSamples.series)
    }

    @Test func calendarEventFixtureDecodes() throws {
        #expect(
            try FixtureLoader.decode(CalendarEvent.self, from: "calendarEvent")
                == ModelSamples.calendarEvent
        )
    }
}
