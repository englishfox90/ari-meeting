//
//  SidebarSearchViewModel.swift — the rail's global search (sidebar rework).
//
//  Honest scope: this searches what the store can actually match today — meeting titles,
//  person names/emails/organizations, and series titles. It is NOT transcript-content
//  search (that's the F7/Ask recall surface). The library is small and local, so each
//  query is a fetch-all + in-memory filter, mirroring the list view models' read pattern;
//  a failed read surfaces as a real `failureMessage`, never as silently empty results
//  (No-Fake-State).
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class SidebarSearchViewModel {
    /// One query's matches, grouped the way the rail renders them.
    public struct Results: Sendable {
        public var meetings: [Meeting] = []
        public var persons: [Person] = []
        public var series: [Series] = []

        public var isEmpty: Bool {
            meetings.isEmpty && persons.isEmpty && series.isEmpty
        }
    }

    /// How many matches each group surfaces in the rail — a display bound so one broad
    /// term can't turn the sidebar into an unbounded list.
    public static let groupLimit = 8

    public private(set) var results = Results()
    public private(set) var failureMessage: String?

    private let database: AppDatabase
    private var searchTask: Task<Void, Never>?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Re-runs the search for `query`, cancelling any in-flight one. An empty/whitespace
    /// query clears the results immediately.
    public func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = Results()
            failureMessage = nil
            return
        }

        searchTask = Task { [database] in
            do {
                let meetings = try await database.meetings.all()
                let persons = try await database.persons.all()
                let series = try await database.series.all()
                guard !Task.isCancelled else { return }

                var matched = Results()
                matched.meetings = Array(
                    meetings.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
                        .prefix(Self.groupLimit)
                )
                matched.persons = Array(
                    persons.filter { person in
                        person.displayName.localizedCaseInsensitiveContains(trimmed)
                            || person.email?.localizedCaseInsensitiveContains(trimmed) == true
                            || person.organization?.localizedCaseInsensitiveContains(trimmed) == true
                    }
                    .prefix(Self.groupLimit)
                )
                matched.series = Array(
                    series.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
                        .prefix(Self.groupLimit)
                )
                results = matched
                failureMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = Results()
                failureMessage = String(describing: error)
            }
        }
    }
}
