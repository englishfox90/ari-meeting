//
//  SpeakerCountHintProviding.swift — the hint-source seam (plan §2.6).
//
//  Phase-3.5 conformer is `StoredCalendarHintProvider` (this file's sibling). When live EventKit
//  (S7) lands, its provider conforms to the same protocol — nothing downstream changes.
//
public protocol SpeakerCountHintProviding: Sendable {
    /// Best available hint for a meeting, with provenance for honest UI. `nil` when no signal is
    /// available — never a fabricated default (No-Fake-State).
    func hint(for meetingId: MeetingID) async throws -> ResolvedSpeakerHint?
}

public struct ResolvedSpeakerHint: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        case calendarAttendees
        case userEntered
    }

    public var hint: SpeakerCountHint
    public var origin: Origin

    public init(hint: SpeakerCountHint, origin: Origin) {
        self.hint = hint
        self.origin = origin
    }
}
