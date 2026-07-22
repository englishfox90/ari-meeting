//
//  AddToSeriesViewModelTests.swift — the meeting-detail "Add to series" control's view model.
//
//  Exercises the real `AppDatabase` in-memory store through `SeriesRepository` (the same pattern
//  as `SeriesListViewModelTests`): load, add-to-existing, create-and-add, remove, and the derived
//  `filteredSeries` (already-joined series excluded; case-insensitive title match).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("AddToSeriesViewModel")
@MainActor
struct AddToSeriesViewModelTests {
    private let meetingId: MeetingID = "meeting-1"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDatabase() async throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(id: meetingId, title: "Preston 1:1", createdAt: now, updatedAt: now))
        return db
    }

    private func makeSeries(_ db: AppDatabase, id: String, title: String) async throws {
        try await db.series.upsert(Series(id: SeriesID(id), title: title, createdAt: now, updatedAt: now))
    }

    @Test("load reflects existing series and current membership honestly")
    func loadReflectsState() async throws {
        let db = try await makeDatabase()
        try await makeSeries(db, id: "s-a", title: "Brian 1:1")
        try await makeSeries(db, id: "s-b", title: "Brian Sync")
        try await db.series.addMember(seriesId: SeriesID("s-a"), meetingId: meetingId, at: now)

        let vm = AddToSeriesViewModel(database: db)
        await vm.load(meetingId: meetingId)

        #expect(vm.allSeries.count == 2)
        #expect(vm.currentSeries.map(\.id) == [SeriesID("s-a")])
        // Already-joined series are excluded from the add list.
        #expect(vm.filteredSeries.map(\.id) == [SeriesID("s-b")])
        #expect(vm.errorMessage == nil)
    }

    @Test("filteredSeries applies a case-insensitive title query and excludes joined series")
    func filteredSeriesQuery() async throws {
        let db = try await makeDatabase()
        try await makeSeries(db, id: "s-a", title: "Brian 1:1")
        try await makeSeries(db, id: "s-b", title: "Hailey Sync")
        try await db.series.addMember(seriesId: SeriesID("s-a"), meetingId: meetingId, at: now)

        let vm = AddToSeriesViewModel(database: db)
        await vm.load(meetingId: meetingId)
        vm.searchText = "hail"
        #expect(vm.filteredSeries.map(\.id) == [SeriesID("s-b")])
        vm.searchText = "brian" // joined → still excluded even on a match
        #expect(vm.filteredSeries.isEmpty)
    }

    @Test("addToExisting links the meeting and refreshes currentSeries")
    func addToExisting() async throws {
        let db = try await makeDatabase()
        try await makeSeries(db, id: "s-a", title: "Brian 1:1")

        let vm = AddToSeriesViewModel(database: db)
        await vm.load(meetingId: meetingId)
        await vm.addToExisting(seriesId: SeriesID("s-a"), meetingId: meetingId)

        #expect(vm.currentSeries.map(\.id) == [SeriesID("s-a")])
        #expect(try await db.series.seriesIds(forMeeting: meetingId) == [SeriesID("s-a")])
    }

    @Test("createAndAdd creates a new series, joins it, and clears the query")
    func createAndAdd() async throws {
        let db = try await makeDatabase()
        let vm = AddToSeriesViewModel(database: db)
        await vm.load(meetingId: meetingId)
        vm.searchText = "Preston"

        await vm.createAndAdd(title: "  Preston 1:1  ", meetingId: meetingId)

        #expect(vm.currentSeries.count == 1)
        #expect(vm.currentSeries.first?.title == "Preston 1:1") // trimmed
        #expect(vm.searchText.isEmpty)
        let all = try await db.series.allSummaries()
        #expect(all.contains { $0.title == "Preston 1:1" && $0.meetingCount == 1 })
    }

    @Test("createAndAdd refuses a blank title (never creates an untitled series)")
    func createAndAddRefusesBlank() async throws {
        let db = try await makeDatabase()
        let vm = AddToSeriesViewModel(database: db)
        await vm.load(meetingId: meetingId)

        await vm.createAndAdd(title: "   ", meetingId: meetingId)

        #expect(vm.currentSeries.isEmpty)
        #expect(try await db.series.allSummaries().isEmpty)
    }

    @Test("remove unlinks the meeting from a series")
    func remove() async throws {
        let db = try await makeDatabase()
        try await makeSeries(db, id: "s-a", title: "Brian 1:1")
        try await db.series.addMember(seriesId: SeriesID("s-a"), meetingId: meetingId, at: now)

        let vm = AddToSeriesViewModel(database: db)
        await vm.load(meetingId: meetingId)
        #expect(vm.currentSeries.map(\.id) == [SeriesID("s-a")])

        await vm.remove(seriesId: SeriesID("s-a"), meetingId: meetingId)
        #expect(vm.currentSeries.isEmpty)
        #expect(try await db.series.seriesIds(forMeeting: meetingId).isEmpty)
    }
}
