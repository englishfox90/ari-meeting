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

    /// Renames a meeting. The live `observeAll()` stream (started in `observe()`) re-emits the
    /// updated list, so this view model never mutates `state` by hand — the row refreshes itself.
    /// A blank/whitespace-only title is rejected (kept as a no-op) so the list can't show an
    /// empty row. Throws on a real write failure so the caller can surface it (No-Fake-State:
    /// never a silent success).
    public func rename(_ meeting: Meeting, to newTitle: String) async throws {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meeting.title else { return }
        try await database.meetings.rename(meeting.id, to: trimmed, at: Date())
    }

    /// Soft-deletes (tombstones) a meeting — it disappears from every list but stays recoverable
    /// in the DB. The live `observeAll()` stream drops the tombstoned row automatically. Throws on
    /// a real write failure so the caller can surface it.
    public func delete(_ meeting: Meeting) async throws {
        try await database.meetings.softDelete(meeting.id, at: Date())
    }
}
