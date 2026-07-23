//
//  NotchTestSupport.swift — shared test doubles for the Notch overlay suites
//  (docs/plans/notch-panel-absorption.md §7).
//
import AriKit
import Foundation
import Observation
@testable import AriViewModels

/// A settable `NotchUpcomingProviding` conformer — the Phase-3.2 scheduler seam has no live
/// conformer in this feature, so tests drive one directly.
@MainActor
@Observable
final class FakeNotchUpcomingProvider: NotchUpcomingProviding {
    var current: NotchUpcomingMeeting?
    init(current: NotchUpcomingMeeting? = nil) {
        self.current = current
    }
}

/// Records every call so the consent-invariant test can assert `session.stop()`'s underlying
/// `CaptureService.start()` was never reached via anything other than the sanctioned edges.
@MainActor
final class SpyOpenAppRecorder {
    private(set) var openAppCallCount = 0
    private(set) var recordedEventIds: [CalendarEventID] = []

    func openApp() {
        openAppCallCount += 1
    }

    func recordEvent(_ eventId: CalendarEventID) {
        recordedEventIds.append(eventId)
    }
}
