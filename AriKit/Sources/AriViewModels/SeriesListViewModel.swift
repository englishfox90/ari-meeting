//
//  SeriesListViewModel.swift — the Series list screen's view model
//  (docs/plans/arikit-native-read-ui.md §2.3/§9 S6f).
//
//  Mirrors `MeetingsListViewModel`'s load pattern: a one-shot `SeriesRepository.allSummaries()`
//  read (so a real read failure surfaces as an honest `.failed(String)`), then live updates via
//  `observeSummaries()`. `.empty` is a first-class, honest state distinct from `.loaded([])`.
//
//  Rows carry the member count + most-recent-meeting aggregates (`SeriesSummary`), and the list
//  is filtered client-side by `searchText` (title match) so a long series list stays navigable.
//  Sort order (alphabetical by title) is the repository's job, so it survives live updates.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class SeriesListViewModel {
    public private(set) var state: LoadState<[SeriesSummary]> = .loading
    /// The current search query. Filtering is derived (`filtered`); the underlying `state` is left
    /// whole so clearing the query restores the full list without a re-read.
    public var searchText: String = ""
    /// The real error text of the last failed create, or `nil`. Surfaced honestly in the UI
    /// (No-Fake-State) rather than a silent no-op.
    public private(set) var errorMessage: String?

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// The loaded series filtered by `searchText` (case-insensitive title match). Empty unless the
    /// state is `.loaded`. Trimmed so a stray space doesn't hide everything.
    public var filtered: [SeriesSummary] {
        guard case let .loaded(all) = state else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// True when the user has a non-empty query that matches no loaded series — an honest
    /// "no matches" state distinct from "no series exist at all" (`state == .empty`).
    public var hasNoMatches: Bool {
        guard case let .loaded(all) = state, !all.isEmpty else { return false }
        return filtered.isEmpty
    }

    /// Loads the initial list (honest `.failed` on a real error), then starts consuming the live
    /// series stream for updates. Idempotent-guarded so a re-entrant `.task` doesn't start a
    /// second live observer.
    public func observe() async {
        do {
            let summaries = try await database.series.allSummaries()
            state = summaries.isEmpty ? .empty : .loaded(summaries)
        } catch {
            state = .failed(String(describing: error))
            return
        }

        guard observationTask == nil else { return }
        let stream = database.series.observeSummaries()
        observationTask = Task { [weak self] in
            for await summaries in stream {
                guard let self else { return }
                state = summaries.isEmpty ? .empty : .loaded(summaries)
            }
        }
    }

    /// Creates a new, meeting-less series (the list screen's "+" affordance). A blank/whitespace
    /// title is refused (No-Fake-State: never create an untitled series) — `errorMessage` is set
    /// and `nil` returned rather than silently no-oping. The live `observeSummaries()` stream
    /// already started by `observe()` refreshes the list on success, so this doesn't re-read.
    public func createSeries(title: String) async -> SeriesID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Give the series a title."
            return nil
        }
        do {
            let id = try await database.series.createSeries(title: trimmed)
            errorMessage = nil
            return id
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }
}
