//
//  SeriesDetector.swift — F9 series auto-detection, consent-aware (calendar-series-intelligence
//  plan §2.2). Port-with-divergence of `detect_series_for_event` (Rust `detection.rs:22-84`): the
//  guards, find-or-create-by-key, and idempotency parity are ported; the consent affordance
//  (`'suggested'` membership + per-series `autoAddMode`) is net-new product behavior the frozen
//  Rust build does not have.
//
//  Deliberate divergence from Rust (plan §2.1): `upsert_member` (`meeting_series.rs:198-199`)
//  overwrites `link_source` on conflict, so Rust detection can silently downgrade a manual
//  membership to `auto`. This port never writes over an existing `seriesMember` row of ANY
//  `linkSource` — an existing membership (however it got there) always means `.skipped`.
//
import Foundation

/// F9 series detection, consent-aware (← `detect_series_for_event`, `detection.rs:22-84`).
public struct SeriesDetector: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Guards failed, existing membership (any `linkSource`), `autoAddMode == 'never'`, or a
        /// tombstoned series holds the key — nothing written.
        case skipped
        /// A new `'suggested'` membership was written (`autoAddMode == 'ask'`) — pending consent.
        case suggested(SeriesID)
        /// A new `'auto'` membership was written (`autoAddMode == 'always'`) — consented already.
        case autoAdded(SeriesID)
    }

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Guards (parity `detection.rs:26-36`): the event must be linked to a meeting, must carry
    /// `hasRecurrence == true`, and must carry a non-blank `seriesKey`. Then find-or-create the
    /// series by key and, per its `autoAddMode`, either skip, write a `'suggested'` member, or
    /// write an `'auto'` member. `occurrenceTime` prefers `occurrenceDate`, falling back to
    /// `startTime` (parity `detection.rs:67-71`), stored as an RFC3339 string.
    public func detect(for event: CalendarEvent, at now: Date) async throws -> Outcome {
        guard let meetingId = event.meetingId,
              event.hasRecurrence == true,
              let seriesKey = event.seriesKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !seriesKey.isEmpty
        else {
            return .skipped
        }

        let seriesId: SeriesID
        let autoAddMode: String
        if let existing = try await database.series.findByKeyIncludingDeleted(seriesKey) {
            // A tombstoned series holding this key was deliberately deleted by the user — never
            // resurrect it (consent-first, plan §2.5).
            guard !existing.isDeleted else { return .skipped }
            seriesId = existing.id
            autoAddMode = existing.autoAddMode
        } else {
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            seriesId = try await database.series.createSeriesForDetection(
                seriesKey: seriesKey,
                title: title.isEmpty ? "Recurring meeting" : title,
                at: now
            )
            autoAddMode = "ask"
        }

        let occurrenceTime = RFC3339.string(from: event.occurrenceDate ?? event.startTime)

        // "never" needs no write at all, so it's resolved before the single check-then-act
        // transaction below — an existing membership of ANY `linkSource` still means `.skipped`
        // for the other two modes, but `never` skips regardless of whether one already exists.
        guard autoAddMode != "never" else { return .skipped }

        let linkSource = autoAddMode == "always" ? "auto" : "suggested" // "ask"/unrecognized → ask.

        // Idempotent, never overwrite, and race-free (M2 fix): the existence check + insert happen
        // in ONE write transaction (`insertMemberIfAbsent`), so the transaction outcome — not a
        // separate prior read — is the source of truth for `.skipped` vs `.suggested`/`.autoAdded`.
        // An existing membership row for (series, meeting) of ANY `linkSource` — including one
        // another series holds for this meeting, which is irrelevant here since this is a per-
        // `(series, meeting)` check — means `.skipped`.
        let wrote = try await database.series.insertMemberIfAbsent(
            seriesId: seriesId, meetingId: meetingId,
            occurrenceTime: occurrenceTime, linkSource: linkSource, at: now
        )
        guard wrote else { return .skipped }

        return autoAddMode == "always" ? .autoAdded(seriesId) : .suggested(seriesId)
    }
}
