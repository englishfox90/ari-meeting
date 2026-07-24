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
//  F9 ledger fold (docs/plans/calendar-series-intelligence.md §2.4, feature 2): adding a meeting
//  to a series (manual pick or create-and-join) is the moment its already-finished summary should
//  fold into that series' running ledger — mirroring `SummaryRunner`'s auto-fold-on-generation
//  (`SummaryRunner.swift:200-214`) for the other trigger. `remove` never folds (there is nothing
//  to un-fold; a removed meeting's prior fold simply stays baked into the ledger, matching the
//  Rust incumbent's behavior).
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
    /// Pending-consent `'suggested'` series memberships for the loaded meeting
    /// (calendar-series-intelligence plan §2.4, feature 1) — the suggestion banner's read.
    public private(set) var suggestedSeries: [SeriesSummary] = []
    /// Search query for the existing-series list. Filtering is derived (`filteredSeries`).
    public var searchText: String = ""
    /// The real error text of the last failed read/write, or `nil`. Surfaced honestly in the UI.
    public private(set) var errorMessage: String?
    /// True while a membership mutation is in flight, so the UI can disable its controls.
    public private(set) var isBusy = false
    /// The F9 series-ledger reducer, fired fire-and-forget after a successful add. Settable (not
    /// an `init` parameter) because `MeetingDetailView` constructs this view model in its `init`
    /// (before `@Environment(AppEnvironment.self)` is readable there); the view assigns it once
    /// the environment resolves, mirroring how `MeetingSummaryViewModel` is lazily built from
    /// `environment.summaryRunner` (`MeetingDetailView.swift:646-658`). `nil` disables auto-fold
    /// (e.g. in tests that don't care about series), never blocking or failing the add itself.
    public var ledgerReducer: SeriesLedgerReducer?

    private let database: AppDatabase

    /// The most recently fired fold task, if any. NOT `public` — a test-only synchronization hook
    /// (visible to `@testable import AriViewModels`) so tests can `await` the detached fold
    /// deterministically instead of sleep-polling; production callers never observe or await this
    /// — the fold is genuinely fire-and-forget from the UI's perspective.
    var pendingFoldTask: Task<Void, Never>?

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
            let suggestedIds = Set(try await database.series.suggestedSeriesIds(forMeeting: meetingId))
            allSeries = summaries
            currentSeries = summaries.filter { memberIds.contains($0.id) }
            suggestedSeries = summaries.filter { suggestedIds.contains($0.id) }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Consent transition (the "yes" moment, plan §2.4): confirms a `'suggested'` membership,
    /// reloads, then fires the F9 ledger fold (fire-and-forget — see `fireLedgerFold`) — this is
    /// the moment consented content may enter the ledger.
    public func confirmSuggestion(seriesId: SeriesID, meetingId: MeetingID) async {
        await mutate(meetingId: meetingId, foldAfterSuccess: true) {
            try await self.database.series.confirmSuggestedMember(
                seriesId: seriesId, meetingId: meetingId, at: Date()
            )
        }
    }

    /// Consent transition (the "no" moment, plan §2.4): declines a `'suggested'` membership and
    /// reloads. Never folds.
    public func declineSuggestion(seriesId: SeriesID, meetingId: MeetingID) async {
        await mutate(meetingId: meetingId) {
            try await self.database.series.declineSuggestedMember(
                seriesId: seriesId, meetingId: meetingId, at: Date()
            )
        }
    }

    /// Adds the meeting to an existing series, then reloads so the chips/list reflect the change,
    /// then fires the F9 ledger fold (fire-and-forget — see `fireLedgerFold`).
    public func addToExisting(seriesId: SeriesID, meetingId: MeetingID) async {
        await mutate(meetingId: meetingId, foldAfterSuccess: true) {
            try await self.database.series.addMember(seriesId: seriesId, meetingId: meetingId, linkSource: "manual")
        }
    }

    /// Removes the meeting from a series it currently belongs to. Never folds — there is nothing
    /// to un-fold, and a prior fold for this meeting simply stays baked into the ledger.
    public func remove(seriesId: SeriesID, meetingId: MeetingID) async {
        await mutate(meetingId: meetingId) {
            _ = try await self.database.series.removeMember(seriesId: seriesId, meetingId: meetingId)
        }
    }

    /// Creates a new (ledger-less) series titled `title` and joins the meeting to it in one step,
    /// then fires the F9 ledger fold (fire-and-forget — see `fireLedgerFold`).
    /// A blank/whitespace title is refused (No-Fake-State: never create an untitled series).
    public func createAndAdd(title: String, meetingId: MeetingID) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        let series = Series(id: SeriesID(UUID().uuidString), title: trimmed, createdAt: now, updatedAt: now)
        await mutate(meetingId: meetingId, foldAfterSuccess: true) {
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
    /// `foldAfterSuccess` fires the F9 ledger fold once the write (and reload) succeed — never on
    /// a failed mutation, and never for `remove`.
    private func mutate(meetingId: MeetingID, foldAfterSuccess: Bool = false, _ operation: () async throws -> Void) async {
        isBusy = true
        do {
            try await operation()
            isBusy = false
            await load(meetingId: meetingId)
            if foldAfterSuccess {
                fireLedgerFold(meetingId: meetingId)
            }
        } catch {
            errorMessage = String(describing: error)
            isBusy = false
        }
    }

    /// Fires `ledgerReducer.foldMeeting` fire-and-forget (the `SummaryRunner.swift:204-214`
    /// pattern): detached, best-effort, and never surfaced as `errorMessage` — a failed fold must
    /// never make an otherwise-successful "add to series" look like it failed. No-ops when no
    /// reducer has been assigned (e.g. the environment hasn't finished bootstrapping yet, or a
    /// test doesn't care about series ledgers).
    private func fireLedgerFold(meetingId: MeetingID) {
        guard let ledgerReducer else { return }
        pendingFoldTask = Task.detached(priority: .utility) {
            try? await ledgerReducer.foldMeeting(meetingId: meetingId)
        }
    }
}
