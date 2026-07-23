//
//  NotchPresentationTests.swift — the exhaustive Phase → IslandPresentation map
//  (docs/plans/notch-panel-absorption.md §7 suite 4).
//
//  `RecordingSession.Phase` is intentionally not `Sendable` (it's a `@MainActor`-only enum), so
//  these are plain per-case `@Test` functions rather than a parameterized `arguments:` table —
//  storing phase values in a static array would require `Sendable`.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("NotchPresentation")
struct NotchPresentationTests {
    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - No upcoming meeting: only .recording/.stopping expand

    @Test("idle, no upcoming → hidden")
    func idleNoUpcomingIsHidden() {
        #expect(IslandPresentation.derive(phase: .idle, hasUpcoming: false) == .hidden)
    }

    @Test("consentPrompt, no upcoming → hidden")
    func consentPromptNoUpcomingIsHidden() {
        #expect(IslandPresentation.derive(phase: .consentPrompt, hasUpcoming: false) == .hidden)
    }

    @Test("starting, no upcoming → hidden")
    func startingNoUpcomingIsHidden() {
        #expect(IslandPresentation.derive(phase: .starting, hasUpcoming: false) == .hidden)
    }

    @Test("recording, no upcoming → expanded")
    func recordingNoUpcomingIsExpanded() {
        #expect(
            IslandPresentation.derive(phase: .recording(startedAt: Self.referenceDate), hasUpcoming: false)
                == .expanded
        )
    }

    @Test("stopping, no upcoming → expanded (honest 'Stopping…', not hidden mid-drain)")
    func stoppingNoUpcomingIsExpanded() {
        #expect(IslandPresentation.derive(phase: .stopping, hasUpcoming: false) == .expanded)
    }

    @Test("saved, no upcoming → hidden")
    func savedNoUpcomingIsHidden() {
        #expect(IslandPresentation.derive(phase: .saved(MeetingID("meeting-1")), hasUpcoming: false) == .hidden)
    }

    @Test("failed, no upcoming → hidden")
    func failedNoUpcomingIsHidden() {
        #expect(IslandPresentation.derive(phase: .failed("boom"), hasUpcoming: false) == .hidden)
    }

    // MARK: - Any phase + an upcoming meeting → expanded (plan §4: "unless hasUpcoming → .expanded")

    @Test("idle with an upcoming meeting → expanded")
    func idleWithUpcomingIsExpanded() {
        #expect(IslandPresentation.derive(phase: .idle, hasUpcoming: true) == .expanded)
    }

    @Test("consentPrompt with an upcoming meeting → expanded")
    func consentPromptWithUpcomingIsExpanded() {
        #expect(IslandPresentation.derive(phase: .consentPrompt, hasUpcoming: true) == .expanded)
    }

    @Test("starting with an upcoming meeting → expanded")
    func startingWithUpcomingIsExpanded() {
        #expect(IslandPresentation.derive(phase: .starting, hasUpcoming: true) == .expanded)
    }

    @Test("recording with an upcoming meeting → still expanded")
    func recordingWithUpcomingIsExpanded() {
        #expect(
            IslandPresentation.derive(phase: .recording(startedAt: Self.referenceDate), hasUpcoming: true)
                == .expanded
        )
    }

    @Test("stopping with an upcoming meeting → still expanded")
    func stoppingWithUpcomingIsExpanded() {
        #expect(IslandPresentation.derive(phase: .stopping, hasUpcoming: true) == .expanded)
    }

    @Test("saved with an upcoming meeting → expanded")
    func savedWithUpcomingIsExpanded() {
        #expect(IslandPresentation.derive(phase: .saved(MeetingID("meeting-1")), hasUpcoming: true) == .expanded)
    }

    @Test("failed with an upcoming meeting → expanded")
    func failedWithUpcomingIsExpanded() {
        #expect(IslandPresentation.derive(phase: .failed("boom"), hasUpcoming: true) == .expanded)
    }

    // MARK: - .collapsed is reserved

    @Test(".collapsed is reserved — derive() never returns it, for any phase")
    func collapsedIsNeverDerived() {
        let phases: [RecordingSession.Phase] = [
            .idle, .consentPrompt, .starting,
            .recording(startedAt: Self.referenceDate), .stopping,
            .saved(MeetingID("meeting-1")), .failed("boom"),
        ]
        for phase in phases {
            #expect(IslandPresentation.derive(phase: phase, hasUpcoming: false) != .collapsed)
            #expect(IslandPresentation.derive(phase: phase, hasUpcoming: true) != .collapsed)
        }
    }
}
