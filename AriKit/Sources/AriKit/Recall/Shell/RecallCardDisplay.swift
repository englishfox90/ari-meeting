//
//  RecallCardDisplay.swift — pure, testable display-string helpers for the Slice C inline entity
//  cards (`docs/plans/ask-meetings-tools-and-cards.md` §5.2). Factored out of the app-target
//  `AskSourceCard`/`AskMeetingCard`/`AskPersonCard`/`AskSeriesCard` views so the honesty rules
//  (No-Fake-State: never a placeholder for a missing/nil field, never an estimated count) are unit
//  tested here without needing a SwiftUI test target for the `Ari` app.
//
//  `friendlyDate` mirrors `AskSourceCard`'s pre-existing private `friendlyDate`/`parseISO` helpers
//  exactly (tolerant of both fractional and whole-second RFC3339/ISO-8601 forms; falls back to the
//  raw string rather than dropping it when unparseable) — this is the single shared implementation
//  all four card views now call, rather than four private copies.
//
import Foundation

/// Pure, `Sendable` display-string helpers for recall entity cards. No SwiftUI dependency — safe
/// to unit test directly.
public enum RecallCardDisplay: Sendable {
    /// A meeting/RFC3339 date rendered in a human format ("Jul 22, 2026, 3:45 PM"). `nil` in, `nil`
    /// out (never a placeholder). An unparseable non-empty string falls back to itself verbatim
    /// (never dropped, never blanked) — the value is still real, just not in a format we can parse.
    public static func friendlyDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let date = parseISO(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Just the day portion ("Jul 22, 2026") — used where a card shows "last on `<date>`" without
    /// a time-of-day (the plan's series/person card copy, §5.2). Same nil/fallback discipline as
    /// `friendlyDate`.
    public static func friendlyDayOnly(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let date = parseISO(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func parseISO(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// "1 meeting" / "N meetings" — correct singular/plural, never a vague "several"/"many"
    /// (No-Fake-State: the real integer is always shown).
    public static func meetingCountLabel(_ count: Int) -> String {
        count == 1 ? "1 meeting" : "\(count) meetings"
    }

    /// The person-card meta line (plan §5.2): "N meeting(s) involving them, last met (via
    /// calendar) `<date>`" — the "(via calendar)" framing matches
    /// `RecallEngine+Tools.resolvePersonMeetings`'s existing prompt-context wording (§4.4 honesty
    /// requirement: this signal is calendar-attendee matching, not diarization-verified presence).
    /// The trailing "last met" clause is OMITTED ENTIRELY when `lastMeetingDate` is `nil` — never a
    /// placeholder "—"/"unknown" in its place.
    public static func personMetaLine(meetingCount: Int, lastMeetingDate: String?) -> String {
        let base = "\(meetingCountLabel(meetingCount)) involving them (via calendar)"
        guard let friendly = friendlyDayOnly(lastMeetingDate) else { return base }
        return "\(base), last met \(friendly)"
    }

    /// The series-card meta line (plan §5.2): "N meeting(s), last on `<date>`" — the "last on"
    /// clause is OMITTED ENTIRELY when `lastMeetingDate` is `nil`.
    public static func seriesMetaLine(meetingCount: Int, lastMeetingDate: String?) -> String {
        let base = meetingCountLabel(meetingCount)
        guard let friendly = friendlyDayOnly(lastMeetingDate) else { return base }
        return "\(base), last on \(friendly)"
    }

    /// The person-card role/organization line: "Role, Organization" / "Role" / "Organization" /
    /// `nil` when both are absent — never a placeholder for a missing field, and never a stray
    /// separator when only one is present.
    public static func roleOrganizationLine(role: String?, organization: String?) -> String? {
        let parts = [role, organization].compactMap { $0?.isEmpty == false ? $0 : nil }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }
}
