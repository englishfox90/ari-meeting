//
//  SeriesDetailViewModelTests.swift — ledger present/absent honest; member meetings resolve
//  (docs/plans/arikit-native-read-ui.md §7 Lane 1, S6f).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("SeriesDetailViewModel")
@MainActor
struct SeriesDetailViewModelTests {

    @Test("honest nil ledger when none has been written")
    func honestNilLedger() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let seriesId: SeriesID = "series-1"
        let series = Series(id: seriesId, title: "Weekly 1:1", createdAt: now, updatedAt: now)
        try await database.series.upsert(series)

        let viewModel = SeriesDetailViewModel(database: database)
        await viewModel.load(seriesId)

        #expect(viewModel.series.value?.ledgerMarkdown == nil)
        #expect(viewModel.series.value?.ledgerVersion == nil)
        #expect(viewModel.memberMeetings.isEmpty)
    }

    @Test("resolves ledger and member meetings when present")
    func resolvesLedgerAndMembers() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let seriesId: SeriesID = "series-2"
        var series = Series(id: seriesId, title: "Weekly 1:1", createdAt: now, updatedAt: now)
        series.ledgerMarkdown = "## Open items\n- Follow up"
        series.ledgerVersion = 1
        try await database.series.upsert(series)

        let meetingId: MeetingID = "meeting-1"
        let meeting = Meeting(id: meetingId, title: "1:1 — week 1", createdAt: now, updatedAt: now)
        try await database.meetings.upsert(meeting)
        try await database.series.addMember(seriesId: seriesId, meetingId: meetingId)

        let viewModel = SeriesDetailViewModel(database: database)
        await viewModel.load(seriesId)

        #expect(viewModel.series.value?.ledgerMarkdown == "## Open items\n- Follow up")
        #expect(viewModel.series.value?.ledgerVersion == 1)
        #expect(viewModel.memberMeetings.map(\.id) == [meetingId])
    }

    @Test("honest failed when the series does not exist")
    func honestFailedOnMissingSeries() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = SeriesDetailViewModel(database: database)
        await viewModel.load("does-not-exist")

        guard case .failed = viewModel.series else {
            Issue.record("expected .failed, got \(viewModel.series)")
            return
        }
    }
}
