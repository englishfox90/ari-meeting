//
//  RecallCardDisplayTests.swift — plan §8 Slice C card-view content tests
//  (`ask-meetings-tools-and-cards.md` §5.2/§5.3), against the pure display-string helpers the
//  `Ari` app's `AskMeetingCard`/`AskPersonCard`/`AskSeriesCard` SwiftUI views call. There is no
//  SwiftUI test target for the `Ari` app itself, so the No-Fake-State honesty rules (never a
//  placeholder for a missing field, never an estimated count) are proven here against the exact
//  logic those views use.
//
import Foundation
import Testing
@testable import AriKit

@Suite("RecallCardDisplay — pure card display-string helpers (No-Fake-State honesty)")
struct RecallCardDisplayTests {

    // MARK: - friendlyDate / friendlyDayOnly

    @Test("friendlyDate returns nil for a nil or empty raw value — never a placeholder")
    func friendlyDateNilForMissingValue() {
        #expect(RecallCardDisplay.friendlyDate(nil) == nil)
        #expect(RecallCardDisplay.friendlyDate("") == nil)
    }

    @Test("friendlyDate parses a fractional-second RFC3339 instant into a human format")
    func friendlyDateParsesFractionalInstant() {
        let friendly = RecallCardDisplay.friendlyDate("2026-07-18T15:30:00.000Z")
        #expect(friendly != nil)
        #expect(friendly != "2026-07-18T15:30:00.000Z")
    }

    @Test("friendlyDate falls back to the raw string verbatim when unparseable — never dropped")
    func friendlyDateFallsBackToRawWhenUnparseable() {
        #expect(RecallCardDisplay.friendlyDate("not-a-date") == "not-a-date")
    }

    @Test("friendlyDayOnly mirrors friendlyDate's nil/fallback discipline")
    func friendlyDayOnlyDiscipline() {
        #expect(RecallCardDisplay.friendlyDayOnly(nil) == nil)
        #expect(RecallCardDisplay.friendlyDayOnly("") == nil)
        #expect(RecallCardDisplay.friendlyDayOnly("garbage") == "garbage")
        #expect(RecallCardDisplay.friendlyDayOnly("2026-07-18T00:00:00Z") != nil)
    }

    // MARK: - Timezone conversion (live 2026-07-23 Ask-Meetings bug)

    @Test("friendlyDate converts a UTC instant to the injected LOCAL time — 14:46 UTC is 8:46 AM MDT, never 2:46 PM")
    func friendlyDateConvertsUTCToLocalTime() throws {
        let denver = try #require(TimeZone(identifier: "America/Denver")) // UTC-6 in July (MDT)
        let enUS = Locale(identifier: "en_US")
        let raw = try #require(
            RecallCardDisplay.friendlyDate("2026-07-23T14:46:29Z", timeZone: denver, locale: enUS)
        )
        // `Date.FormatStyle` puts a narrow no-break space (U+202F) before AM/PM — normalize it.
        let friendly = raw
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        #expect(friendly.contains("8:46 AM"))
        #expect(!friendly.contains("2:46 PM")) // the raw-digit relabel the model produced live
        #expect(!friendly.contains("14:46"))
        #expect(friendly.contains("Jul 23, 2026"))
    }

    @Test(
        "friendlyDayOnly returns the real LOCAL day across a UTC-midnight boundary — 05:30 UTC is still Jul 22 in MDT"
    )
    func friendlyDayOnlyCrossesUTCMidnight() throws {
        let denver = try #require(TimeZone(identifier: "America/Denver")) // UTC-6 in July (MDT)
        let enUS = Locale(identifier: "en_US")
        // 2026-07-23T05:30:00Z is 2026-07-22 23:30 MDT — the UTC-prefix trick would say "Jul 23".
        let friendly = try #require(
            RecallCardDisplay.friendlyDayOnly("2026-07-23T05:30:00Z", timeZone: denver, locale: enUS)
        )
        #expect(friendly == "Jul 22, 2026")
    }

    // MARK: - meetingCountLabel — real integer, correct singular/plural, never vague

    @Test("meetingCountLabel pluralizes correctly and shows the exact real integer")
    func meetingCountLabelPluralizes() {
        #expect(RecallCardDisplay.meetingCountLabel(0) == "0 meetings")
        #expect(RecallCardDisplay.meetingCountLabel(1) == "1 meeting")
        #expect(RecallCardDisplay.meetingCountLabel(2) == "2 meetings")
        #expect(RecallCardDisplay.meetingCountLabel(42) == "42 meetings")
    }

    // MARK: - personMetaLine — the (via calendar) honesty framing (plan §4.4/§5.2)

    @Test("personMetaLine includes '(via calendar)' framing and the exact real meeting count")
    func personMetaLineHonestFraming() {
        let line = RecallCardDisplay.personMetaLine(meetingCount: 3, lastMeetingDate: nil)
        #expect(line.contains("via calendar"))
        #expect(line.contains("3 meetings"))
    }

    @Test("personMetaLine OMITS the 'last met' clause entirely when lastMeetingDate is nil — never a placeholder")
    func personMetaLineOmitsLastMetWhenNil() {
        let line = RecallCardDisplay.personMetaLine(meetingCount: 5, lastMeetingDate: nil)
        #expect(!line.contains("last met"))
        #expect(!line.contains("—"))
        #expect(!line.contains("unknown"))
        #expect(!line.contains("Unknown"))
    }

    @Test("personMetaLine includes a real 'last met' clause when lastMeetingDate is present")
    func personMetaLineIncludesLastMetWhenPresent() {
        let line = RecallCardDisplay.personMetaLine(meetingCount: 5, lastMeetingDate: "2026-07-10T00:00:00Z")
        #expect(line.contains("last met"))
    }

    @Test("personMetaLine never estimates/rounds the meeting count")
    func personMetaLineNeverEstimatesCount() {
        #expect(RecallCardDisplay.personMetaLine(meetingCount: 1, lastMeetingDate: nil).contains("1 meeting "))
        #expect(RecallCardDisplay.personMetaLine(meetingCount: 17, lastMeetingDate: nil).contains("17 meetings"))
    }

    // MARK: - seriesMetaLine

    @Test("seriesMetaLine OMITS the 'last on' clause entirely when lastMeetingDate is nil")
    func seriesMetaLineOmitsLastOnWhenNil() {
        let line = RecallCardDisplay.seriesMetaLine(meetingCount: 4, lastMeetingDate: nil)
        #expect(!line.contains("last on"))
        #expect(line.contains("4 meetings"))
    }

    @Test("seriesMetaLine includes a real 'last on' clause when lastMeetingDate is present")
    func seriesMetaLineIncludesLastOnWhenPresent() {
        let line = RecallCardDisplay.seriesMetaLine(meetingCount: 4, lastMeetingDate: "2026-07-01T00:00:00Z")
        #expect(line.contains("last on"))
    }

    // MARK: - roleOrganizationLine — omit entirely, never a placeholder, no stray separator

    @Test("roleOrganizationLine is nil when both role and organization are absent")
    func roleOrganizationLineNilWhenBothAbsent() {
        #expect(RecallCardDisplay.roleOrganizationLine(role: nil, organization: nil) == nil)
        #expect(RecallCardDisplay.roleOrganizationLine(role: "", organization: "") == nil)
    }

    @Test("roleOrganizationLine shows only role when organization is absent, no stray separator")
    func roleOrganizationLineRoleOnly() {
        #expect(RecallCardDisplay.roleOrganizationLine(role: "PM", organization: nil) == "PM")
    }

    @Test("roleOrganizationLine shows only organization when role is absent")
    func roleOrganizationLineOrganizationOnly() {
        #expect(RecallCardDisplay.roleOrganizationLine(role: nil, organization: "Arivo") == "Arivo")
    }

    @Test("roleOrganizationLine joins both with a comma-space when both are present")
    func roleOrganizationLineBoth() {
        #expect(RecallCardDisplay.roleOrganizationLine(role: "PM", organization: "Arivo") == "PM, Arivo")
    }
}
