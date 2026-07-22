//
//  AddToSeriesViewModel.swift — the meeting-detail "Add to series" control's view model.
//
//  Restores the old Rust app's meeting-header affordance: search the existing series, add the
//  current meeting to one, or create a brand-new series (pre-filled with the meeting's title) and
//  join it in one step. Membership is a plain `seriesMember` link (`SeriesRepository`), so this VM
//  is a thin, honest orchestration over that repository — no new persistence concepts.
//
//  Mirrors `SeriesListViewModel`'s shape: a direct `AppDatabase` dependency (the repository layer
//  is already the seam), a one-shot `load` that reads the full series list plus THIS meeting's
//  current memberships, and derived filtering (`filteredSeries`) so the whole list survives a
//  cleared query without a re-read.
//
//  No-Fake-State: `currentSeries`/`allSeries` are honestly empty until `load` runs; a real read or
//  write failure surfaces as `errorMessage` rather than a silent no-op or an invented success.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class AddToSeriesViewModel {
    /// Every existing (non-deleted) series with its member-count aggregate.
    public private(set) var allSeries: [SeriesSummary] = []
    /// The series the loaded meeting currently belongs to (usually zero or one).
    public private(set) var currentSeries: [SeriesSummary] = []
    /// Search query for the existing-series list. Filtering is derived (`filteredSeries`).
    public var searchText: String = ""
    /// The real error text of the last failed read/write, or `nil`. Surfaced honestly in the UI.
    public private(set) var errorMessage: String?
    /// True while a membership mutation is in flight, so the UI can disable its controls.
    public private(set) var isBusy = false

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Existing series the meeting is NOT already in, filtered by `searchText` (case-insensitive
    /// title match). Already-joined series are shown separately as removable chips, so listing them
    /// here too would be a confusing double-entry.
    public var filteredSeries: [SeriesSummary] {
        let joined = Set(currentSeries.map(\.id))
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allSeries
            .filter { !joined.contains($0.id) }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// Loads the full series list plus the meeting's current memberships. Honest `errorMessage` on
    /// a real read failure; leaves the previously loaded lists intact rather than blanking them.
    public func load(meetingId: MeetingID) async {
        do {
            let summaries = try await database.series.allSummaries()
            let memberIds = Set(try await database.series.seriesIds(forMeeting: meetingId))
            allSeries = summaries
            currentSeries = summaries.filter { memberIds.contains($0.id) }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Adds the meeting to an existing series, then reloads so the chips/list reflect the change.
    public func addToExisting(seriesId: SeriesID, meetingId: MeetingID) async {
        await mutate(meetingId: meetingId) {
            try await self.database.series.addMember(seriesId: seriesId, meetingId: meetingId, linkSource: "manual")
        }
    }

    /// Removes the meeting from a series it currently belongs to.
    public func remove(seriesId: SeriesID, meetingId: MeetingID) async {
        await mutate(meetingId: meetingId) {
            _ = try await self.database.series.removeMember(seriesId: seriesId, meetingId: meetingId)
        }
    }

    /// Creates a new (ledger-less) series titled `title` and joins the meeting to it in one step.
    /// A blank/whitespace title is refused (No-Fake-State: never create an untitled series).
    public func createAndAdd(title: String, meetingId: MeetingID) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        let series = Series(id: SeriesID(UUID().uuidString), title: trimmed, createdAt: now, updatedAt: now)
        await mutate(meetingId: meetingId) {
            try await self.database.series.upsert(series)
            try await self.database.series.addMember(seriesId: series.id, meetingId: meetingId, linkSource: "manual")
        }
        if errorMessage == nil {
            searchText = ""
        }
    }

    /// Runs a membership mutation with a busy flag + honest error capture. Reloads the meeting's
    /// series state ONLY on success — a reload after a failure would run `load`, whose successful
    /// read clears `errorMessage`, silently swallowing the write error before the UI shows it.
    private func mutate(meetingId: MeetingID, _ operation: () async throws -> Void) async {
        isBusy = true
        do {
            try await operation()
            isBusy = false
            await load(meetingId: meetingId)
        } catch {
            errorMessage = String(describing: error)
            isBusy = false
        }
    }
}
