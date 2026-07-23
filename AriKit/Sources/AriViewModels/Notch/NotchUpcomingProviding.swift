//
//  NotchUpcomingProviding.swift — the seam for the upcoming-meeting alert
//  (docs/plans/notch-panel-absorption.md §2, §4).
//
//  Driven live by `NotchUpcomingScheduler` (the ported `notch/scheduler.rs` brain,
//  Amendment A §A.3). The protocol remains a test seam — `NotchOverlayModel` accepts any
//  conformer so it can compile, unit-test, and preview against fakes without depending on the
//  live scheduler's calendar/DB reads.
//
import AriKit
import Foundation
import Observation

/// A single upcoming-meeting alert's presentation data — the successor of the sidecar wire
/// model's `UpcomingMeeting` struct, expressed against real app types (`CalendarEventID`, `Date`)
/// instead of decoded JSON.
public struct NotchUpcomingMeeting: Equatable, Sendable {
    public var eventId: CalendarEventID
    public var title: String
    public var startDate: Date
    public var attendeeCount: Int
    public var alreadyRecording: Bool

    public init(
        eventId: CalendarEventID,
        title: String,
        startDate: Date,
        attendeeCount: Int,
        alreadyRecording: Bool
    ) {
        self.eventId = eventId
        self.title = title
        self.startDate = startDate
        self.attendeeCount = attendeeCount
        self.alreadyRecording = alreadyRecording
    }
}

/// The seam a Phase-3.2 scheduler conformer will implement. `@Observable`-constrained so
/// `NotchOverlayModel`'s own Observation tracking on `current` re-derives `presentation` whenever
/// the provider updates — exactly like it already tracks `RecordingSession.phase`.
@MainActor
public protocol NotchUpcomingProviding: AnyObject, Observable {
    var current: NotchUpcomingMeeting? { get }
}
