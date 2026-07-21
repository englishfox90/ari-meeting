//
//  PeopleListViewModel.swift — the People list screen's view model
//  (docs/plans/arikit-native-read-ui.md §2.3/§9 S6e).
//
//  Mirrors `MeetingsListViewModel`'s load pattern: a one-shot `PersonRepository.all()` read
//  (so a real read failure surfaces as an honest `.failed(String)`), then live updates via
//  `observeAll()`. `.empty` is a first-class, honest state distinct from `.loaded([])`.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class PeopleListViewModel {
    public private(set) var state: LoadState<[Person]> = .loading

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Loads the initial list (honest `.failed` on a real error), then starts consuming the
    /// live persons stream for updates. Idempotent-guarded so a re-entrant `.task` doesn't
    /// start a second live observer.
    public func observe() async {
        do {
            let people = try await database.persons.all()
            state = people.isEmpty ? .empty : .loaded(people)
        } catch {
            state = .failed(String(describing: error))
            return
        }

        guard observationTask == nil else { return }
        let stream = database.persons.observeAll()
        observationTask = Task { [weak self] in
            for await people in stream {
                guard let self else { return }
                state = people.isEmpty ? .empty : .loaded(people)
            }
        }
    }
}
