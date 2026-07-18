//
//  ModelSamples.swift — canonical sample instances of every domain type (test support).
//
//  Not a test suite — a shared factory reused across the Models suites (round-trip, audio-split
//  reflection, Sendable inventory). Dates are constructed from integer epoch seconds so they
//  round-trip exactly through the millisecond-precision RFC3339 strategy.
//
import Foundation
@testable import AriKit

enum ModelSamples {
    /// A fixed instant with zero sub-second component, so encode→decode is bit-exact.
    static let instant = Date(timeIntervalSince1970: 1_700_000_000)
    static let laterInstant = Date(timeIntervalSince1970: 1_700_003_600)

    static let meeting = Meeting(
        id: "meeting-1",
        title: "Weekly sync",
        createdAt: instant,
        updatedAt: laterInstant,
        audioReference: LocalAudioReference(path: "/Users/owner/Recordings/meeting-1"),
        transcriptionProvider: "parakeet",
        transcriptionModel: "parakeet-tdt-0.6b-v3-int8",
        summaryProvider: "anthropic",
        summaryModel: "claude"
    )

    static let transcript = Transcript(
        id: "transcript-1",
        meetingId: "meeting-1",
        transcript: "Hello everyone, let's begin.",
        timestamp: "00:00:03",
        summary: "Greeting",
        actionItems: "None",
        keyPoints: "Kickoff",
        audioStartTime: 3.0,
        audioEndTime: 5.5,
        duration: 2.5,
        speakerId: "speaker-1"
    )

    static let speaker = Speaker(
        id: "speaker-1",
        personId: "person-1",
        label: "Owner",
        centroid: Data([0x01, 0x02, 0x03, 0x04]),
        embeddingModel: "wespeaker-v2",
        dim: 256,
        samples: 12,
        enrollmentState: .owner,
        totalSpeechSecs: 480.0,
        createdAt: instant,
        updatedAt: laterInstant
    )

    static let speakerSegment = SpeakerSegment(
        id: "segment-1",
        meetingId: "meeting-1",
        speakerId: "speaker-1",
        clusterKey: "cluster-a",
        startTime: 3.0,
        endTime: 5.5,
        source: .import,
        embedding: Data([0x0A, 0x0B, 0x0C]),
        createdAt: instant
    )

    static let person = Person(
        id: "person-1",
        email: "owner@example.com",
        displayName: "Owner Person",
        role: "Engineer",
        organization: "Arivo",
        domain: "example.com",
        notes: "Recording owner",
        isOwner: true,
        createdAt: instant,
        updatedAt: laterInstant
    )

    static let profileFact = ProfileFact(
        id: "fact-1",
        personId: "person-1",
        factText: "Leads the migration project.",
        factKind: .project,
        sourceMeetingId: "meeting-1",
        sourceMeetingTitle: "Weekly sync",
        sourceSegmentRef: "seg:3.0-5.5",
        origin: .selfReported,
        confidence: 0.82,
        sourceCount: 2,
        status: .active,
        supersededBy: nil,
        createdAt: instant
    )

    static let profileFactSource = ProfileFactSource(
        id: "factsource-1",
        factId: "fact-1",
        meetingId: "meeting-1",
        meetingTitle: "Weekly sync",
        segmentRef: "seg:3.0-5.5",
        origin: .selfReported,
        relation: .origin,
        confidence: 0.82,
        observedAt: instant
    )

    static let profileFactWithProvenance = ProfileFactWithProvenance(
        fact: profileFact,
        sources: [profileFactSource]
    )

    static let series = Series(
        id: "series-1",
        title: "Weekly sync",
        seriesKey: "ext-abc-123",
        detectedType: "one_on_one",
        cadence: "weekly",
        ledgerMarkdown: "# Ledger\n- kicked off",
        ledgerVersion: 3
    )

    static let attendee = Attendee(name: "Guest", email: "guest@example.com")

    static let calendarEvent = CalendarEvent(
        id: "event-1",
        calendarId: "cal-1",
        calendarTitle: "Work",
        title: "Weekly sync",
        startTime: instant,
        endTime: laterInstant,
        isAllDay: false,
        location: "Room 4",
        notes: "Agenda attached",
        organizer: "owner@example.com",
        attendees: [attendee],
        meetingId: "meeting-1",
        linkSource: .calendar
    )
}
