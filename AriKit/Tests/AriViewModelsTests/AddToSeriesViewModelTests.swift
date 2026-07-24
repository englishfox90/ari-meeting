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

    // MARK: - F9 ledger fold (docs/plans/calendar-series-intelligence.md §5, tests 21-24)

    private let cannedLedger = "## Open action items\n_None yet._\n\n## Decisions\n_None yet._\n\n## Recurring themes\n_None yet._\n\n## Per-person threads\n_None yet._"

    /// Builds a `SeriesLedgerReducer` whose LLM call is a canned/erroring `StubLLMClient` — the
    /// same test double `SummaryRunnerTests`' F9 auto-fold tests use.
    private func makeReducer(db: AppDatabase, error: LLMError? = nil) -> SeriesLedgerReducer {
        SeriesLedgerReducer(
            db: db,
            settings: StubSettingsReading(
                summaryModelConfigValue: SummaryModelConfig(providerKey: "mlx", model: "test-model")
            ),
            secrets: StubSecretsReading(),
            clientFactory: { _ in StubLLMClient(cannedResponse: self.cannedLedger, error: error) }
        )
    }

    @Test("addToExisting on a meeting WITH a finished summary folds exactly once with validated @mrefs")
    func addToExistingFoldsWithFinishedSummary() async throws {
        let db = try await makeDatabase()
        try await makeSeries(db, id: "s-a", title: "Brian 1:1")
        try await db.summaries.upsert(Summary(
            id: SummaryID("summary-1"),
            meetingId: meetingId,
            bodyMarkdown: "- Ship the beta @ref(04:21)",
            createdAt: now,
            updatedAt: now
        ))

        let vm = AddToSeriesViewModel(database: db)
        vm.ledgerReducer = makeReducer(db: db)
        await vm.load(meetingId: meetingId)
        await vm.addToExisting(seriesId: SeriesID("s-a"), meetingId: meetingId)
        await vm.pendingFoldTask?.value

        let series = try await db.series.find(SeriesID("s-a"))
        #expect(series?.ledgerMarkdown == cannedLedger)
        // Pins "exactly once": a double-fold would bump this past 1.
        #expect(series?.ledgerVersion == 1)
        #expect(vm.errorMessage == nil)
    }

    @Test("addToExisting on a meeting WITHOUT a summary writes membership but leaves the ledger untouched")
    func addToExistingWithoutSummaryDoesNotFold() async throws {
        let db = try await makeDatabase()
        try await makeSeries(db, id: "s-a", title: "Brian 1:1")

        let vm = AddToSeriesViewModel(database: db)
        vm.ledgerReducer = makeReducer(db: db)
        await vm.load(meetingId: meetingId)
        await vm.addToExisting(seriesId: SeriesID("s-a"), meetingId: meetingId)
        await vm.pendingFoldTask?.value

        #expect(vm.currentSeries.map(\.id) == [SeriesID("s-a")])
        let series = try await db.series.find(SeriesID("s-a"))
        #expect(series?.ledgerMarkdown == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test("createAndAdd folds like addToExisting; remove never folds")
    func createAndAddFoldsRemoveNeverFolds() async throws {
        let db = try await makeDatabase()
        try await db.summaries.upsert(Summary(
            id: SummaryID("summary-1"),
            meetingId: meetingId,
            bodyMarkdown: "- Ship the beta",
            createdAt: now,
            updatedAt: now
        ))

        let vm = AddToSeriesViewModel(database: db)
        vm.ledgerReducer = makeReducer(db: db)
        await vm.load(meetingId: meetingId)
        await vm.createAndAdd(title: "Preston 1:1", meetingId: meetingId)
        await vm.pendingFoldTask?.value

        let seriesId = vm.currentSeries.first?.id
        var created: Series?
        if let seriesId {
            created = try await db.series.find(seriesId)
        }
        #expect(created?.ledgerMarkdown == cannedLedger)

        // Now remove: the ledger must be untouched by the removal itself (no fold fired).
        vm.pendingFoldTask = nil
        guard let seriesId else {
            Issue.record("createAndAdd did not join a series")
            return
        }
        await vm.remove(seriesId: seriesId, meetingId: meetingId)
        #expect(vm.pendingFoldTask == nil)
        #expect(vm.currentSeries.isEmpty)
    }

    @Test("a throwing fold client leaves membership written and errorMessage nil — best-effort, never poisons the UI write")
    func throwingFoldNeverSurfacesAsErrorMessage() async throws {
        let db = try await makeDatabase()
        try await makeSeries(db, id: "s-a", title: "Brian 1:1")
        try await db.summaries.upsert(Summary(
            id: SummaryID("summary-1"),
            meetingId: meetingId,
            bodyMarkdown: "- Ship the beta",
            createdAt: now,
            updatedAt: now
        ))

        let vm = AddToSeriesViewModel(database: db)
        vm.ledgerReducer = makeReducer(db: db, error: .notConfigured("boom"))
        await vm.load(meetingId: meetingId)
        await vm.addToExisting(seriesId: SeriesID("s-a"), meetingId: meetingId)
        await vm.pendingFoldTask?.value

        #expect(vm.currentSeries.map(\.id) == [SeriesID("s-a")])
        #expect(try await db.series.seriesIds(forMeeting: meetingId) == [SeriesID("s-a")])
        #expect(vm.errorMessage == nil)
        let series = try await db.series.find(SeriesID("s-a"))
        #expect(series?.ledgerMarkdown == nil)
    }

    // MARK: - F9 consent (calendar-series-intelligence plan §5, test 25)

    @Test("confirmSuggestion folds; declineSuggestion never folds")
    func confirmSuggestionFoldsDeclineNeverFolds() async throws {
        let db = try await makeDatabase()
        try await makeSeries(db, id: "s-a", title: "Brian 1:1")
        try await db.series.addMember(
            seriesId: SeriesID("s-a"), meetingId: meetingId, linkSource: "suggested", at: now
        )
        try await db.summaries.upsert(Summary(
            id: SummaryID("summary-1"),
            meetingId: meetingId,
            bodyMarkdown: "- Ship the beta",
            createdAt: now,
            updatedAt: now
        ))

        let vm = AddToSeriesViewModel(database: db)
        vm.ledgerReducer = makeReducer(db: db)
        await vm.load(meetingId: meetingId)
        #expect(vm.suggestedSeries.map(\.id) == [SeriesID("s-a")])
        #expect(vm.currentSeries.isEmpty) // suggested ≠ current membership

        await vm.confirmSuggestion(seriesId: SeriesID("s-a"), meetingId: meetingId)
        await vm.pendingFoldTask?.value

        #expect(vm.suggestedSeries.isEmpty)
        #expect(vm.currentSeries.map(\.id) == [SeriesID("s-a")])
        let series = try await db.series.find(SeriesID("s-a"))
        #expect(series?.ledgerMarkdown == cannedLedger)

        // A second series, declined — no fold, no membership.
        try await makeSeries(db, id: "s-b", title: "Hailey Sync")
        try await db.series.addMember(
            seriesId: SeriesID("s-b"), meetingId: meetingId, linkSource: "suggested", at: now
        )
        await vm.load(meetingId: meetingId)
        vm.pendingFoldTask = nil

        await vm.declineSuggestion(seriesId: SeriesID("s-b"), meetingId: meetingId)

        #expect(vm.pendingFoldTask == nil)
        #expect(!vm.currentSeries.contains { $0.id == SeriesID("s-b") })
        // Left with zero member rows — tombstoned (excluded from a non-including-deleted read).
        let live = try await db.series.all()
        #expect(!live.contains { $0.id == SeriesID("s-b") })
        let includingDeleted = try await db.series.all(includingDeleted: true)
        #expect(includingDeleted.contains { $0.id == SeriesID("s-b") })
    }
}
