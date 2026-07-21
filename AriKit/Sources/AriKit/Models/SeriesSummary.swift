//
//  SeriesSummary.swift — a list-row view of a series: identity + classification + the two
//  aggregates the list needs (member count and most-recent member date).
//
//  This is the `SeriesSummary` DTO the `Series` domain type deliberately excludes (see
//  `Series.swift` — `meetingCount`/`lastMeetingTime` are computed join aggregates that must not
//  live on the row-shaped domain type). It's read-only and produced only by
//  `SeriesRepository.allSummaries()`/`observeSummaries()`, never persisted. `lastMeetingTime` is
//  honestly `nil` for a series with no (non-deleted) member meetings — never a fabricated date
//  (No-Fake-State).
//
import Foundation

public struct SeriesSummary: Identifiable, Hashable, Sendable {
    public let id: SeriesID
    public let title: String
    public let detectedType: String?
    public let cadence: String?
    public let meetingCount: Int
    public let lastMeetingTime: Date?

    public init(
        id: SeriesID,
        title: String,
        detectedType: String? = nil,
        cadence: String? = nil,
        meetingCount: Int,
        lastMeetingTime: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detectedType = detectedType
        self.cadence = cadence
        self.meetingCount = meetingCount
        self.lastMeetingTime = lastMeetingTime
    }
}
