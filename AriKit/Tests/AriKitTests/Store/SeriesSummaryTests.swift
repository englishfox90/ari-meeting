//
//  SeriesSummaryTests.swift — SeriesRepository.allSummaries() aggregates + ordering.
//
import Foundation
import Testing
@testable import AriKit

@Suite("SeriesRepository.allSummaries")
struct SeriesSummaryTests {

    private func makeSeries(_ db: AppDatabase, id: String, title: String, at date: Date) async throws {
        try await db.series.upsert(Series(id: SeriesID(id), title: title, createdAt: date, updatedAt: date))
    }

    private func addMeeting(
        _ db: AppDatabase, seriesId: String, meetingId: String, at date: Date
    ) async throws {
        try await db.meetings.upsert(
            Meeting(id: MeetingID(meetingId), title: "m-\(meetingId)", createdAt: date, updatedAt: date)
        )
        try await db.series.addMember(seriesId: SeriesID(seriesId), meetingId: MeetingID(meetingId), at: date)
    }

    @Test("summaries carry member count and most-recent meeting date, sorted case-insensitively by title")
    func aggregatesAndOrdering() async throws {
        let db = try AppDatabase.makeInMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Insert out of alphabetical order to prove the ORDER BY, and mix casing.
        try await makeSeries(db, id: "s-taylor", title: "Taylor Sync", at: base)
        try await makeSeries(db, id: "s-brian", title: "Brian 1:1", at: base)
        try await makeSeries(db, id: "s-lunch", title: "lunchies", at: base)

        // Taylor: two meetings — the later date must win as lastMeetingTime.
        let older = base.addingTimeInterval(-3600)
        let newer = base.addingTimeInterval(3600)
        try await addMeeting(db, seriesId: "s-taylor", meetingId: "m1", at: older)
        try await addMeeting(db, seriesId: "s-taylor", meetingId: "m2", at: newer)
        // Brian: one meeting. lunchies: none.
        try await addMeeting(db, seriesId: "s-brian", meetingId: "m3", at: base)

        let summaries = try await db.series.allSummaries()

        // Case-insensitive alphabetical: Brian, lunchies, Taylor.
        #expect(summaries.map(\.title) == ["Brian 1:1", "lunchies", "Taylor Sync"])

        let taylor = try #require(summaries.first { $0.id == SeriesID("s-taylor") })
        #expect(taylor.meetingCount == 2)
        #expect(taylor.lastMeetingTime == newer)

        let lunch = try #require(summaries.first { $0.id == SeriesID("s-lunch") })
        #expect(lunch.meetingCount == 0)
        #expect(lunch.lastMeetingTime == nil)
    }

    @Test("a soft-deleted series is excluded; a soft-deleted meeting doesn't count")
    func excludesDeleted() async throws {
        let db = try AppDatabase.makeInMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try await makeSeries(db, id: "s-live", title: "Live Series", at: base)
        try await makeSeries(db, id: "s-gone", title: "Gone Series", at: base)
        try await addMeeting(db, seriesId: "s-live", meetingId: "m-live", at: base)
        try await addMeeting(db, seriesId: "s-live", meetingId: "m-dead", at: base)

        try await db.series.softDelete(SeriesID("s-gone"), at: base)
        try await db.meetings.softDelete(MeetingID("m-dead"), at: base)

        let summaries = try await db.series.allSummaries()
        #expect(summaries.map(\.id) == [SeriesID("s-live")])
        #expect(summaries[0].meetingCount == 1)
    }

    @Test("seriesIds(forMeeting:) is the reverse of membership, oldest link first")
    func reverseMembershipLookup() async throws {
        let db = try AppDatabase.makeInMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try await makeSeries(db, id: "s-a", title: "Alpha", at: base)
        try await makeSeries(db, id: "s-b", title: "Beta", at: base)
        try await makeSeries(db, id: "s-c", title: "Gamma", at: base)
        try await db.meetings.upsert(Meeting(id: MeetingID("m1"), title: "m1", createdAt: base, updatedAt: base))
        try await db.meetings.upsert(Meeting(id: MeetingID("m2"), title: "m2", createdAt: base, updatedAt: base))

        // m1 joins Beta then Alpha; m2 joins Gamma only.
        try await db.series.addMember(seriesId: SeriesID("s-b"), meetingId: MeetingID("m1"), at: base)
        try await db.series.addMember(seriesId: SeriesID("s-a"), meetingId: MeetingID("m1"), at: base.addingTimeInterval(60))
        try await db.series.addMember(seriesId: SeriesID("s-c"), meetingId: MeetingID("m2"), at: base)

        let m1 = try await db.series.seriesIds(forMeeting: MeetingID("m1"))
        #expect(m1 == [SeriesID("s-b"), SeriesID("s-a")]) // oldest link first
        let m2 = try await db.series.seriesIds(forMeeting: MeetingID("m2"))
        #expect(m2 == [SeriesID("s-c")])

        // Removing a link drops it from the reverse lookup.
        _ = try await db.series.removeMember(seriesId: SeriesID("s-b"), meetingId: MeetingID("m1"))
        #expect(try await db.series.seriesIds(forMeeting: MeetingID("m1")) == [SeriesID("s-a")])
    }
}
