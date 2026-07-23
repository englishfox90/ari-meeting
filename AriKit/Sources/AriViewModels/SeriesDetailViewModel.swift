//
//  SeriesDetailViewModel.swift — the Series detail screen's view model
//  (docs/plans/arikit-native-read-ui.md §2.3/§9 S6f).
//
//  One-shot read (no live observation, mirroring `MeetingDetailViewModel`'s detail-VM pattern).
//  Member meetings resolve via `SeriesRepository.meetingIds(inSeries:)` →
//  `MeetingRepository.find(_:)`, skipping any member id that fails to resolve (a stale link
//  rather than a fabricated row). `ledgerMarkdown`/`ledgerVersion` are honestly `nil` when the
//  series has never had a ledger written (plan §4.7 — the `seriesLedger` row may not exist yet).
//
//  Series management (docs/plans/glittery-humming-truffle.md Part 3): rename / delete / merge, and
//  manual ledger rebuild via the injected `SeriesLedgerReducer`. All mutations are honest — a real
//  failure surfaces via `errorMessage` rather than a silent no-op (No-Fake-State).
//
import AriKit
import Foundation
import Observation
import os

@MainActor
@Observable
public final class SeriesDetailViewModel {
    private nonisolated static let log = Logger(subsystem: "com.arivo.ari.AriViewModels", category: "series.detail")

    public private(set) var series: LoadState<Series> = .loading
    public private(set) var memberMeetings: [Meeting] = []
    /// Every other non-deleted series — the "Merge into…" picker's candidate list.
    public private(set) var mergeTargets: [SeriesSummary] = []

    /// True while a ledger rebuild is in flight, so the UI can show progress + disable the button.
    public private(set) var isRebuildingLedger = false
    /// True while a rename/delete/merge mutation is in flight.
    public private(set) var isBusy = false
    /// The real error text of the last failed operation, or `nil`. Surfaced honestly (No-Fake-State).
    public private(set) var errorMessage: String?

    private let database: AppDatabase
    private let ledgerReducer: SeriesLedgerReducer
    private var currentId: SeriesID?

    public init(database: AppDatabase, ledgerReducer: SeriesLedgerReducer) {
        self.database = database
        self.ledgerReducer = ledgerReducer
    }

    public func load(_ id: SeriesID) async {
        currentId = id
        await reload()
    }

    /// Re-runs the series + member-meetings + merge-targets read. Called on first load and after
    /// every mutation (rename/merge/delete/rebuild) so the view reflects the new state.
    public func reload() async {
        guard let id = currentId else { return }
        do {
            guard let resolved = try await database.series.find(id) else {
                series = .failed("Series not found.")
                return
            }
            series = .loaded(resolved)

            let memberIds = try await database.series.orderedMeetingIds(inSeries: id)
            var meetings: [Meeting] = []
            for meetingId in memberIds {
                if let meeting = try await database.meetings.find(meetingId) {
                    meetings.append(meeting)
                }
            }
            memberMeetings = meetings

            let allSummaries = try await database.series.allSummaries()
            mergeTargets = allSummaries.filter { $0.id != id }
        } catch {
            series = .failed(String(describing: error))
        }
    }

    /// Renames the series. A blank/whitespace title is refused (No-Fake-State).
    ///
    /// Clears `errorMessage` first (M1) so a stale message from a DIFFERENT action (e.g. a failed
    /// merge) never bleeds into this sheet.
    public func rename(to title: String) async {
        errorMessage = nil
        guard let id = currentId else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Give the series a title."
            return
        }
        await mutate {
            try await self.database.series.rename(id, to: trimmed)
        }
    }

    /// Deletes the series (tombstone + member detach). Returns `true` on success so the view can
    /// pop the navigation stack. Clears `errorMessage` first (M1).
    @discardableResult
    public func delete() async -> Bool {
        errorMessage = nil
        guard let id = currentId else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await database.series.deleteSeries(id)
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    /// Absorbs this series into `target`: re-points membership (fast), then tombstones this
    /// series. Returns `target` immediately on success so the view can dismiss without waiting on
    /// the LLM (M2) — the target's ledger rebuild is kicked off fire-and-forget in a DETACHED task
    /// (mirrors `SummaryRunner.generate`'s auto-fold: logged, errors swallowed, never blocks or
    /// fails the merge the user is waiting on). Clears `errorMessage` first (M1).
    @discardableResult
    public func merge(into target: SeriesID) async -> SeriesID? {
        errorMessage = nil
        guard let id = currentId else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            try await database.series.merge(source: id, into: target)
            errorMessage = nil
            let ledgerReducer = ledgerReducer
            Task.detached(priority: .utility) {
                do {
                    _ = try await ledgerReducer.rebuildLedger(seriesId: target)
                } catch {
                    Self.log.error(
                        "Series merge: target ledger rebuild FAILED for \(target.rawValue, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
            return target
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Rebuilds the whole ledger from every member's finished summary. Honest empty-state message
    /// when there's nothing to build from yet (No-Fake-State — never fabricates a ledger). Clears
    /// `errorMessage` first (M1).
    public func rebuildLedger() async {
        errorMessage = nil
        guard let id = currentId else { return }
        isRebuildingLedger = true
        defer { isRebuildingLedger = false }
        do {
            let result = try await ledgerReducer.rebuildLedger(seriesId: id)
            if result == nil {
                errorMessage = "No summarized meetings yet — nothing to build a ledger from."
            } else {
                errorMessage = nil
            }
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Clears `errorMessage` — called when a sheet (rename/merge) is presented, so a stale message
    /// from a previous, different action never renders under the freshly opened sheet (M1).
    public func clearError() {
        errorMessage = nil
    }

    /// Runs a rename/delete-adjacent mutation with a busy flag + honest error capture, reloading
    /// on success only (mirrors `AddToSeriesViewModel.mutate` — a reload after failure would run a
    /// successful read that clears `errorMessage` before the UI shows it).
    private func mutate(_ operation: () async throws -> Void) async {
        isBusy = true
        do {
            try await operation()
            isBusy = false
            errorMessage = nil
            await reload()
        } catch {
            errorMessage = String(describing: error)
            isBusy = false
        }
    }
}
