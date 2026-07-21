//
//  HomeViewModel.swift — the Home screen's view model (home + left-rail rework).
//
//  Mirrors `MeetingsListViewModel`'s load pattern (one-shot read for an honest `.failed`, then
//  live updates via `observeAll()`), but bounds the exposed list to the `recentLimit` most
//  recent meetings — Home shows a short "Recent meetings" rail, not the full library (that's
//  `MeetingsListViewModel`/the Saved-meetings screen). `meetingCount`/`personCount`/
//  `seriesCount` are real, unbounded counts from the repositories — No-Fake-State: never a
//  fabricated library size.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class HomeViewModel {
    /// How many recent meetings Home surfaces — a display bound, not a query limit; the
    /// underlying read still fetches the full (repository-ordered) list so `meetingCount`
    /// reflects the true library size.
    public static let recentLimit = 5

    public private(set) var state: LoadState<[Meeting]> = .loading
    public private(set) var meetingCount: Int = 0
    public private(set) var personCount: Int = 0
    public private(set) var seriesCount: Int = 0
    /// The owner's display name from the persons table (`isOwner`), if one exists — real
    /// profile data for Home's greeting, never a fabricated name.
    public private(set) var ownerName: String?

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Loads the initial counts + recent meetings (honest `.failed` on a real meetings-read
    /// error), then starts consuming the live meetings stream for updates. Idempotent-guarded
    /// so a re-entrant `.task` doesn't start a second live observer.
    public func observe() async {
        do {
            let meetings = try await database.meetings.all()
            meetingCount = meetings.count
            state = Self.recentState(from: meetings)
        } catch {
            state = .failed(String(describing: error))
            return
        }

        do {
            let persons = try await database.persons.all()
            personCount = persons.count
            ownerName = persons.first(where: \.isOwner)?.displayName
        } catch {
            // personCount is a secondary readout; a person-table failure shouldn't blank the
            // already-loaded meetings state. Leave it at its last honest value.
        }

        do {
            seriesCount = try await database.series.all().count
        } catch {
            // Same tolerance as personCount: a secondary readout, never worth failing Home over.
        }

        guard observationTask == nil else { return }
        let stream = database.meetings.observeAll()
        observationTask = Task { [weak self] in
            for await meetings in stream {
                guard let self else { return }
                meetingCount = meetings.count
                state = Self.recentState(from: meetings)
            }
        }
    }

    private static func recentState(from meetings: [Meeting]) -> LoadState<[Meeting]> {
        meetings.isEmpty ? .empty : .loaded(Array(meetings.prefix(recentLimit)))
    }
}
