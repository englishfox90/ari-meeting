//
//  Series.swift — a recurring meeting series (F9), reconciled from Rust `SeriesSummary` ⊕
//  `SeriesDetail` (meeting_series/models.rs) into one row-shaped domain type.
//
//  Reconciliation (plan include table + No-Fake-State §6): this is the reconciled
//  `SeriesSummary` ⊕ `SeriesDetail` **IPC surface** — identity, classification, and the ledger.
//  It is NOT a 1:1 mirror of the `meeting_series` DB row. Deliberately excluded because they are
//  computed view aggregates / joins that must not live on a domain type:
//    - `meetingCount`, `lastMeetingTime` (SeriesSummary count-view) → a later `SeriesSummary` DTO;
//    - `members` / `occurrenceTime` (SeriesDetail) → a later `SeriesMember` DTO;
//    - `position` / `total` / adjacency (SeriesForMeeting) → a later navigation DTO.
//  Store-port deltas (real stored columns the IPC DTOs don't expose, to add when the Store
//  persists this): `owner_person_id` (→ `ownerPersonId: PersonID?`) and the series' own
//  `created_at`/`updated_at`. `ledgerMarkdown`/`ledgerVersion` live on a SEPARATE `series_ledger`
//  table — the `seriesLedger`-split is deferred to the Store (plan §4); consider
//  `ledgerVersion: Int?` there (nil = no ledger yet, vs. the wire's ambiguous `0`).
//
//  `cadence` and `detectedType` stay `String` (plan decision 0.5): open sets, no closed case
//  list to invent.
//
//  Store-port follow-ons (docs/plans/arikit-store.md §4.7, added when the Store slice landed):
//  `ownerPersonId` (a real stored column the IPC DTOs never exposed) and the series' own
//  `createdAt`/`updatedAt`. `ledgerVersion` becomes `Int?` (`nil` = no ledger yet — the Store's
//  `seriesLedger` row may not exist until a first summary lands), resolving the wire DTO's
//  ambiguous `0`. None of these five fields appear in the frozen engine's wire JSON (confirmed:
//  `SeriesSummary`/`SeriesDetail` carry no timestamps/owner), so `Store/Records/SeriesRecord.swift`
//  is the only place that populates them today.
//
import Foundation

/// Typed identifier for a `Series` (plan §7.4).
public typealias SeriesID = Identifier<Series>

public struct Series: Codable, Hashable, Sendable, Identifiable {
    public var id: SeriesID
    public var title: String
    /// Stable recurrence key (EventKit `calendarItemExternalIdentifier`), if known.
    public var seriesKey: String?
    /// Detected meeting type (open set, kept as `String`).
    public var detectedType: String?
    /// Cadence label (open set, kept as `String`).
    public var cadence: String?
    /// The recording owner's `Person`, if attributed (Store-port follow-on, plan §4.7).
    public var ownerPersonId: PersonID?
    /// The series ledger markdown (F9), folded onto the row in the frozen engine.
    public var ledgerMarkdown: String?
    /// `nil` = no ledger yet (the Store's `seriesLedger` row has never been written).
    public var ledgerVersion: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: SeriesID,
        title: String,
        seriesKey: String? = nil,
        detectedType: String? = nil,
        cadence: String? = nil,
        ownerPersonId: PersonID? = nil,
        ledgerMarkdown: String? = nil,
        ledgerVersion: Int? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.seriesKey = seriesKey
        self.detectedType = detectedType
        self.cadence = cadence
        self.ownerPersonId = ownerPersonId
        self.ledgerMarkdown = ledgerMarkdown
        self.ledgerVersion = ledgerVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
