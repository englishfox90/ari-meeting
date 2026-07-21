//
//  MeetingsListViewModel.swift — the Meetings list screen's view model
//  (docs/plans/arikit-native-read-ui.md §2.3).
//
//  The initial load is a one-shot `MeetingRepository.all()` read — `try/throws`, so a real
//  read failure surfaces as an honest `.failed(String)` (No-Fake-State: never a fake ready).
//  `MeetingRepository.observeAll()`'s `AsyncStream` swallows `ValueObservation` failures by
//  ending the stream (see that method's own doc comment), so it cannot itself drive an
//  honest `.failed` state — the one-shot read is what makes `.failed` observable/testable.
//  After a successful initial load, `observe()` starts consuming `observeAll()` for live
//  updates (imported/recorded/deleted meetings), ordered `createdAt` desc (the repository's
//  own ordering — this view model never re-sorts). `.empty` is a first-class, honest state
//  distinct from `.loaded([])` — a genuinely empty library shows honest copy, never a fake
//  loading spinner.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class MeetingsListViewModel {
    public private(set) var state: LoadState<[Meeting]> = .loading

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Loads the initial list (honest `.failed` on a real error), then starts consuming the
    /// live meetings stream for updates. Idempotent-guarded so a re-entrant `.task` (e.g. on
    /// view re-appear) doesn't start a second live observer.
    public func observe() async {
        do {
            let meetings = try await database.meetings.all()
            state = meetings.isEmpty ? .empty : .loaded(meetings)
        } catch {
            state = .failed(String(describing: error))
            return
        }

        guard observationTask == nil else { return }
        let stream = database.meetings.observeAll()
        observationTask = Task { [weak self] in
            for await meetings in stream {
                guard let self else { return }
                state = meetings.isEmpty ? .empty : .loaded(meetings)
            }
        }
    }
}
