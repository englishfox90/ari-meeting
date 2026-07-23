//
//  SeriesLedgerReducer.swift — the series ledger reduce (F9), ported from
//  `ari-engine/src/meeting_series/ledger.rs`.
//
//  Each meeting series keeps ONE living "ledger" — a compact running memory that is
//  (a) UPDATED here after each meeting's summary is generated, and (b) INJECTED into the next
//  meeting's summary prompt (`SummaryContextAssembler`).
//
//  This owns the REDUCE step: it folds a meeting's summary markdown into the rolling ledger for
//  its series via a single bounded LLM call, then persists the merged result through
//  `SeriesRepository` only (never a raw SQLite handle — plan principle 3). Best-effort by
//  construction — the caller (`SummaryRunner`) fires this off and logs any error; a failed ledger
//  update must never affect the summary flow.
//
//  No-Fake-State: if a meeting is not in a series, or has no finished summary, nothing is
//  touched — we never fabricate content or wipe an existing ledger.
//
import Foundation
import os

public struct SeriesLedgerReducer: Sendable {
    private static let log = Logger(subsystem: "com.arivo.ari.AriKit", category: "series.ledger")

    /// Soft cap for the reduced ledger. Enforced by *instruction* to the model (it is injected
    /// into every future summary prompt, so it must stay terse). We don't hard-truncate the model
    /// output — truncating markdown mid-section would corrupt it.
    private static let ledgerWordCap = 500

    private let db: AppDatabase
    private let settings: any SettingsReading
    private let secrets: any SecretsReading
    private let clientFactory: @Sendable (ProviderConfig) throws -> any LLMClient

    public init(
        db: AppDatabase,
        settings: any SettingsReading,
        secrets: any SecretsReading,
        clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = {
            try ProviderFactory.make(config: $0)
        }
    ) {
        self.db = db
        self.settings = settings
        self.secrets = secrets
        self.clientFactory = clientFactory
    }

    // MARK: - Public entry points

    /// Rebuild the ENTIRE ledger for a series from scratch, folding every member meeting's
    /// existing finished summary in chronological order (← `rebuild_ledger_for_series`).
    ///
    /// This is the on-demand counterpart to the incremental per-meeting reduce: it lets a
    /// hand-curated series — whose members were summarized BEFORE they were linked — build a
    /// ledger without re-generating any summary. Rebuilding from an EMPTY ledger (rather than
    /// patching the current one) guarantees no meeting is double-counted.
    ///
    /// No-Fake-State: if NO member has a usable summary, returns `nil` and does NOT touch any
    /// existing ledger — we never fabricate or blank one.
    @discardableResult
    public func rebuildLedger(seriesId: SeriesID) async throws -> String? {
        guard let series = try await db.series.find(seriesId) else {
            throw LLMError.notConfigured("Series \(seriesId.rawValue) not found")
        }

        // Members come back ordered chronologically.
        let memberIds = try await db.series.orderedMeetingIds(inSeries: seriesId)
        let memberCount = memberIds.count

        var accumulated: String?
        var lastFoldedMeeting: MeetingID?
        var foldedCount = 0

        for (index, meetingId) in memberIds.enumerated() {
            // 1-based position in the chronological member list — this is the `N` that maps to
            // the member's spot in the timeline. It comes from the FULL member ordering (skipped,
            // summary-less members still consume an index), so a badge always resolves to the
            // correct meeting.
            let memberIndex = index + 1

            guard let summary = try await db.summaries.forMeeting(meetingId),
                  !summary.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                // Skip members without a usable summary — don't stall the rebuild.
                continue
            }

            let qualified = SeriesLedgerCitations.qualifyRefs(summary.bodyMarkdown, memberIndex: memberIndex)
            let (meetingTitle, meetingDate) = try await meetingTitleAndDate(meetingId)

            let next: String
            do {
                next = try await reduce(
                    seriesTitle: series.title,
                    currentLedger: accumulated ?? "",
                    summaryMarkdown: qualified,
                    meetingTitle: meetingTitle,
                    meetingDate: meetingDate
                )
            } catch {
                Self.log.error(
                    """
                    📒 Series ledger rebuild: reduce failed while folding meeting \
                    \(meetingId.rawValue, privacy: .public): \(String(describing: error), privacy: .public)
                    """
                )
                throw error
            }

            guard !next.isEmpty else {
                // Model produced nothing for this fold — keep what we have and move on rather
                // than blanking the accumulated ledger.
                Self.log.warning(
                    """
                    📒 Series ledger rebuild: reduce produced empty output for meeting \
                    \(meetingId.rawValue, privacy: .public); skipping it.
                    """
                )
                continue
            }

            accumulated = next
            lastFoldedMeeting = meetingId
            foldedCount += 1
        }

        guard let finalLedger = accumulated, foldedCount > 0 else {
            // No member had a usable summary — leave any existing ledger untouched.
            Self.log.info(
                """
                📒 Series ledger rebuild: no summarized meetings in series '\(series.title, privacy: .public)' \
                (\(seriesId.rawValue, privacy: .public)); leaving any existing ledger untouched.
                """
            )
            return nil
        }

        // No-Fake-State: drop any out-of-range `@mref` the reduce invented/mangled.
        let validated = SeriesLedgerCitations.validateQualifiedRefs(finalLedger, memberCount: memberCount)

        try await db.series.updateLedger(
            seriesId: seriesId,
            ledgerMarkdown: validated,
            structuredJson: nil,
            updatedFromMeetingId: lastFoldedMeeting,
            ledgerVersion: (series.ledgerVersion ?? 0) + 1,
            at: Date()
        )

        Self.log.info(
            """
            📒 Series ledger rebuilt for series '\(series.title, privacy: .public)' (\(
                seriesId.rawValue,
                privacy: .public
            )) \
            from \(foldedCount, privacy: .public) summarized meeting(s), \(
                validated.count,
                privacy: .public
            ) chars
            """
        )
        return validated
    }

    /// Fold ONE meeting's finished summary into the running ledger for its series (←
    /// `rebuild_ledger_for_meeting`). No-op (never wipes) when the meeting is in no series, or
    /// has no finished summary.
    public func foldMeeting(meetingId: MeetingID) async throws {
        // 1. Which series does this meeting belong to?
        guard let seriesId = try await db.series.seriesIds(forMeeting: meetingId).first else {
            // Not in a series — nothing to fold. This is the common case for one-off meetings.
            return
        }

        // 2. Load the finished summary markdown for this meeting.
        guard let summary = try await db.summaries.forMeeting(meetingId),
              !summary.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            // No usable summary yet — don't wipe an existing ledger, just skip.
            Self.log.info(
                """
                📒 Series ledger: no finished summary for meeting \(meetingId.rawValue, privacy: .public); \
                skipping ledger update.
                """
            )
            return
        }

        // Meeting-attributed citations (F9): rewrite this meeting's `@ref(<TS>)` tokens into
        // `@mref(m<N>@<TS>)` BEFORE folding, where N is this meeting's 1-based position in the
        // series' chronological member ordering. `memberCount` bounds the valid N range for the
        // post-reduce validation below.
        //
        // L2 known limitation: `orderedMeetingIds` sorts by `meeting.createdAt` — a stable but not
        // immutable ordering. `@mref(mN@…)` tokens baked into an ALREADY-FOLDED ledger are stored
        // verbatim and never renumbered as new members are added. If a later-added member has an
        // EARLIER `createdAt` than one already folded (e.g. a backdated/imported meeting linked
        // after the fact), every subsequent incremental fold's member index shifts, and any
        // previously stored in-range `@mref` can silently point at the wrong member until the
        // series' ledger is manually rebuilt (`rebuildLedger`, which re-derives every index from
        // scratch). This is a known, accepted gap — not a correctness bug in this fold itself.
        let memberIds = try await db.series.orderedMeetingIds(inSeries: seriesId)
        let memberCount = memberIds.count
        let memberIndex = memberIds.firstIndex(of: meetingId).map { $0 + 1 } ?? 0
        let qualifiedSummary = memberIndex >= 1
            ? SeriesLedgerCitations.qualifyRefs(summary.bodyMarkdown, memberIndex: memberIndex)
            : summary.bodyMarkdown

        // 3. Current ledger markdown (nil/absent → empty "no prior context").
        guard let series = try await db.series.find(seriesId) else { return }
        let currentLedger = series.ledgerMarkdown ?? ""

        // Meeting title + date for provenance inside the reduce prompt.
        let (meetingTitle, meetingDate) = try await meetingTitleAndDate(meetingId)

        // 4. Run the reduce through the configured LLM provider.
        let newMarkdown = try await reduce(
            seriesTitle: series.title,
            currentLedger: currentLedger,
            summaryMarkdown: qualifiedSummary,
            meetingTitle: meetingTitle,
            meetingDate: meetingDate
        )

        guard !newMarkdown.isEmpty else {
            // Model returned nothing usable — keep the prior ledger rather than blanking it.
            Self.log.warning(
                """
                📒 Series ledger: reduce produced empty output for series \(seriesId.rawValue, privacy: .public); \
                keeping prior ledger.
                """
            )
            return
        }

        // No-Fake-State: drop any `@mref` the reduce mangled/invented to an out-of-range meeting
        // index, degrading it to plain time text so no dead badge ever reaches the series page.
        let validated = SeriesLedgerCitations.validateQualifiedRefs(newMarkdown, memberCount: memberCount)

        try await db.series.updateLedger(
            seriesId: seriesId,
            ledgerMarkdown: validated,
            structuredJson: nil,
            updatedFromMeetingId: meetingId,
            ledgerVersion: (series.ledgerVersion ?? 0) + 1,
            at: Date()
        )

        Self.log.info(
            """
            📒 Series ledger updated for series '\(series.title, privacy: .public)' (\(
                seriesId.rawValue,
                privacy: .public
            )) \
            from meeting \(meetingId.rawValue, privacy: .public) (\(validated.count, privacy: .public) chars)
            """
        )
    }

    // MARK: - Meeting metadata

    /// Meeting title (fallback "Untitled meeting") + `yyyy-MM-dd` date string for the reduce
    /// prompt's provenance line.
    private func meetingTitleAndDate(_ meetingId: MeetingID) async throws -> (title: String, date: String) {
        guard let meeting = try await db.meetings.find(meetingId) else {
            return ("Untitled meeting", "")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return (meeting.title, formatter.string(from: meeting.createdAt))
    }

    // MARK: - LLM reduce call

    /// Fold ONE meeting's summary markdown into the running ledger via a single bounded LLM
    /// reduce, returning the merged ledger markdown (trimmed; empty string if the model produced
    /// nothing usable). Pure with respect to the DB — it never persists; the caller owns the
    /// upsert. `currentLedger` empty/blank means "no prior context".
    private func reduce(
        seriesTitle: String,
        currentLedger: String,
        summaryMarkdown: String,
        meetingTitle: String,
        meetingDate: String
    ) async throws -> String {
        guard let modelConfig = try await settings.summaryModelConfig() else {
            throw LLMError.notConfigured("No summarization model is configured. Choose one in Settings.")
        }

        let config = try await ProviderConfigResolution.resolve(
            providerKey: modelConfig.providerKey,
            modelName: modelConfig.model,
            settings: settings,
            secrets: secrets
        )
        let client = try clientFactory(config)

        let (system, user) = Self.buildReducePrompt(
            seriesTitle: seriesTitle,
            currentLedger: currentLedger,
            newSummaryMarkdown: summaryMarkdown,
            meetingTitle: meetingTitle,
            meetingDate: meetingDate
        )

        let out = try await client.generate(LLMRequest(system: system, user: user))
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt building (← `build_reduce_prompt`)

    /// Builds the (system, user) prompt pair for the reduce. The instructions pin EXACTLY the
    /// four sections the read-side injection expects, enforce merge-not-append semantics, and cap
    /// the total length so the ledger stays cheap to inject into future summary prompts.
    static func buildReducePrompt(
        seriesTitle: String,
        currentLedger: String,
        newSummaryMarkdown: String,
        meetingTitle: String,
        meetingDate: String
    ) -> (system: String, user: String) {
        let system = """
        You maintain a compact, living "series ledger" — a running memory shared across all meetings in a recurring series. Your job is to MERGE the newest meeting's summary into the existing ledger and output an updated ledger.

        Output ONLY valid markdown with EXACTLY these four sections, in this order:

        ## Open action items
        ## Decisions
        ## Recurring themes
        ## Per-person threads

        Rules:
        - MERGE, do not just append. Reconcile the new meeting against the existing ledger.
        - Open action items: carry each forward with its owner and a status marker — (new), (still open), (done), or (dropped). REMOVE items that are clearly completed, resolved, or superseded by the new meeting; do not let the list grow without bound.
        - Decisions: keep durable decisions that hold across the series.
        - Recurring themes: topics that keep coming up across meetings.
        - Per-person threads: for each NAMED participant, their ongoing goals, commitments, and trajectory over time.
        - NEVER invent facts. Only use information present in the existing ledger or the new summary.
        - Preserve any @mref(...) citation tokens EXACTLY and verbatim — never alter, split, merge, or invent them; attach the relevant one to the action item or decision it supports.
        - If a section has nothing, write exactly: _None yet._
        - Keep the WHOLE ledger under \(
            ledgerWordCap
        ) words. Be terse. Drop stale or low-signal items to stay within budget. This ledger is injected into future meeting prompts, so brevity matters.
        - Output the markdown ledger only — no preamble, no commentary, no code fences.
        """

        let ledgerBlock = currentLedger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(No prior ledger — this is the first entry for the series. Build it from the new meeting summary alone.)"
            : currentLedger.trimmingCharacters(in: .whitespacesAndNewlines)

        let dateSuffix = meetingDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : " (\(meetingDate))"

        let user = """
        Series: \(seriesTitle)

        === EXISTING LEDGER ===
        \(ledgerBlock)

        === NEW MEETING SUMMARY: \(meetingTitle)\(dateSuffix) ===
        \(newSummaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))

        Produce the updated series ledger now.
        """

        return (system, user)
    }
}
