//
//  SeriesListViewModelTests.swift — loaded, honest `.empty`, honest `.failed`
//  (docs/plans/arikit-native-read-ui.md §7 Lane 1, S6f).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("SeriesListViewModel")
@MainActor
struct SeriesListViewModelTests {

    @Test("honest empty when there are no series")
    func honestEmpty() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = SeriesListViewModel(database: database)
        await viewModel.observe()
        guard case .empty = viewModel.state else {
            Issue.record("expected .empty, got \(viewModel.state)")
            return
        }
    }

    @Test("loaded series")
    func loadedSeries() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let series = Series(
            id: "series-1", title: "Weekly 1:1", createdAt: now, updatedAt: now
        )
        try await database.series.upsert(series)

        let viewModel = SeriesListViewModel(database: database)
        await viewModel.observe()

        guard case let .loaded(all) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(all.map(\.id) == [series.id])
    }

    @Test("honest failed on a real read error")
    func honestFailed() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.dbWriter.write { db in
            try db.execute(sql: "DROP TABLE series")
        }

        let viewModel = SeriesListViewModel(database: database)
        await viewModel.observe()

        guard case let .failed(message) = viewModel.state else {
            Issue.record("expected .failed, got \(viewModel.state)")
            return
        }
        #expect(!message.isEmpty)
    }
}
