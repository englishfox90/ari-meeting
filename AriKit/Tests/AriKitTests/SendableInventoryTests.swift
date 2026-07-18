//
//  SendableInventoryTests.swift — plan §5 test 7.
//
//  Makes `Sendable` conformance a compile-time guarantee for every domain type (plan §3): if any
//  type ever loses `Sendable`, `requireSendable(_:)` fails to compile. There is no runtime
//  assertion to make — the type-checker is the test.
//
import Foundation
import Testing
@testable import AriKit

@Suite struct SendableInventoryTests {
    private func requireSendable(_: (some Sendable).Type) {}

    @Test func everyDomainTypeIsSendable() {
        // Support layer
        requireSendable(MeetingID.self)
        requireSendable(TranscriptID.self)
        requireSendable(SpeakerID.self)
        requireSendable(SpeakerSegmentID.self)
        requireSendable(PersonID.self)
        requireSendable(ProfileFactID.self)
        requireSendable(ProfileFactSourceID.self)
        requireSendable(SeriesID.self)
        requireSendable(CalendarEventID.self)
        requireSendable(LocalAudioReference.self)

        // Tolerant enums
        requireSendable(EnrollmentState.self)
        requireSendable(SegmentSource.self)
        requireSendable(FactKind.self)
        requireSendable(FactStatus.self)
        requireSendable(FactOrigin.self)
        requireSendable(FactSourceRelation.self)
        requireSendable(CalendarLinkSource.self)

        // Entities
        requireSendable(Meeting.self)
        requireSendable(Transcript.self)
        requireSendable(Speaker.self)
        requireSendable(SpeakerSegment.self)
        requireSendable(Person.self)
        requireSendable(ProfileFact.self)
        requireSendable(ProfileFactSource.self)
        requireSendable(ProfileFactWithProvenance.self)
        requireSendable(Series.self)
        requireSendable(Attendee.self)
        requireSendable(CalendarEvent.self)

        // A trivial assertion so the suite reports a passing check, not just a compile.
        #expect(Bool(true))
    }
}
