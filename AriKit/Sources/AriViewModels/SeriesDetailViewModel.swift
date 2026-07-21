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
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class SeriesDetailViewModel {
    public private(set) var series: LoadState<Series> = .loading
    public private(set) var memberMeetings: [Meeting] = []

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func load(_ id: SeriesID) async {
        do {
            guard let resolved = try await database.series.find(id) else {
                series = .failed("Series not found.")
                return
            }
            series = .loaded(resolved)

            let memberIds = try await database.series.meetingIds(inSeries: id)
            var meetings: [Meeting] = []
            for meetingId in memberIds {
                if let meeting = try await database.meetings.find(meetingId) {
                    meetings.append(meeting)
                }
            }
            memberMeetings = meetings
        } catch {
            series = .failed(String(describing: error))
        }
    }
}
