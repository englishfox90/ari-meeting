//
//  SeriesListViewModel.swift — the Series list screen's view model
//  (docs/plans/arikit-native-read-ui.md §2.3/§9 S6f).
//
//  Mirrors `MeetingsListViewModel`'s load pattern: a one-shot `SeriesRepository.all()` read
//  (so a real read failure surfaces as an honest `.failed(String)`), then live updates via
//  `observeAll()`. `.empty` is a first-class, honest state distinct from `.loaded([])`.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class SeriesListViewModel {
    public private(set) var state: LoadState<[Series]> = .loading

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Loads the initial list (honest `.failed` on a real error), then starts consuming the
    /// live series stream for updates. Idempotent-guarded so a re-entrant `.task` doesn't start
    /// a second live observer.
    public func observe() async {
        do {
            let series = try await database.series.all()
            state = series.isEmpty ? .empty : .loaded(series)
        } catch {
            state = .failed(String(describing: error))
            return
        }

        guard observationTask == nil else { return }
        let stream = database.series.observeAll()
        observationTask = Task { [weak self] in
            for await series in stream {
                guard let self else { return }
                state = series.isEmpty ? .empty : .loaded(series)
            }
        }
    }
}
