//
//  SummaryContextAssembler.swift — the "### Meeting context (for the summarizer)" block
//  (← ari-engine/src/persons/commands.rs:425 `summary_context_for_meeting_impl`).
//
//  This is the F3 owner/attendee/calendar context that the Rust/React app prepended to the
//  summary's custom prompt and that the first Swift migration of the summary path DROPPED — the
//  Swift `SummaryRunner` was calling `SummaryService` with the bare transcript, so the model
//  never saw who owns the meeting, who was in the room, the linked calendar event's
//  title/description/attendees, the diarized speakers, or the running series ledger. The visible
//  symptom was summaries that said "Date: Not explicitly stated in the transcript" and were prone
//  to speaker misattribution. This assembler restores that block.
//
//  Faithful port of the Rust impl, with two deliberate deltas:
//    • **Date line ADDED.** The Rust block had no explicit date; we surface the linked event's
//      start instant so the summarizer stops writing "Date: Not explicitly stated" (No-Fake-State:
//      only when a real linked event exists — never a fabricated date).
//    • **Organization** is read from the owner's `organization` field (the Swift store has no
//      host-level `app_config.organization` the Rust command received as a parameter).
//
//  No-Fake-State (plan §7): every line is backed by real Store data. A missing owner + no
//  participants yields `""` (nothing to add, not an empty header). Every repository read is
//  best-effort — a DB hiccup drops that one line and the assembly continues, exactly like the
//  Rust `if let Ok(Some(...))` swallowing. `contextBlock` therefore never throws and never blocks
//  summary generation: the worst case is *less* context, never a failed summary.
//
//  Bounded (plan principle 6): per-person facts capped at `maxPersonFacts`, notes/description
//  truncated, so a large invite list or a chatty notes field can't grow the prompt unbounded.
//
import Foundation

/// Builds the meeting-context prompt block from the Store's person, profile-fact, calendar,
/// speaker, and series repositories. `Sendable` value type over an injected `AppDatabase`
/// (repository-only access, plan §2.2) — safe to call from any isolation domain.
public struct SummaryContextAssembler: Sendable {
    private let database: AppDatabase

    /// ← `MAX_PERSON_FACTS = 4` (commands.rs:375).
    static let maxPersonFacts = 4
    /// ← `MAX_PERSON_NOTES_CHARS = 200` (commands.rs:378).
    static let maxPersonNotesChars = 200
    /// ← the inline `.take(400)` on the calendar event description (commands.rs:512).
    static let maxEventDescriptionChars = 400

    public init(database: AppDatabase) {
        self.database = database
    }

    /// The assembled context block for `meetingId`, or `""` when there is nothing real to add.
    /// Never throws (see file header): every read degrades to "omit that line" on failure.
    public func contextBlock(for meetingId: MeetingID) async -> String {
        let owner = await (try? database.persons.owner()) ?? nil
        // The owner can ALSO be linked as a `meetingParticipant` (e.g. a calendar/speaker link
        // that survives a duplicate-person merge, docs/plans — duplicate-person-merge) — exclude
        // them here so they never render as both "Owner:" and their own "Participants:" entry.
        // Scoped to this call site rather than `PersonRepository.participants(inMeeting:)` itself:
        // that method has other callers (diarization, extraction/reconciliation, calendar sync)
        // that legitimately reason about the owner as a participant link, and changing its
        // semantics repository-wide is a larger, riskier change than this prompt-assembly fix
        // calls for.
        var participants = await (try? database.persons.participants(inMeeting: meetingId)) ?? []
        if let ownerId = owner?.id {
            participants.removeAll { $0.id == ownerId }
        }

        // ← commands.rs:441-443: nothing to anchor the block on → empty string, not a bare header.
        guard owner != nil || !participants.isEmpty else { return "" }

        var block = "### Meeting context (for the summarizer)\n"

        // Organization (owner-derived; see header). Everyone below works there unless noted.
        if let organization = Self.trimmedNonEmpty(owner?.organization) {
            block += "Organization: \(organization) (everyone below works at \(organization) unless noted).\n"
        }

        // The current meeting's own series membership gates fact eligibility below (bleed fix,
        // docs/plans — see `factsClause`): only facts sourced from THIS meeting or another meeting
        // in the same series are ever injected. A previous "include everything, just label it
        // unrelated" approach still leaked into Action Items on a real run (a 4B model ignored the
        // label), so relevance is now a whitelist, not a caveat.
        let currentSeriesIds = await Set((try? database.series.seriesIds(forMeeting: meetingId)) ?? [])

        if let owner {
            block += await ownerLine(owner, meetingId: meetingId, currentSeriesIds: currentSeriesIds) + "\n"
        }

        if !participants.isEmpty {
            block += "Participants:\n"
            for participant in participants {
                block += await participantLine(
                    participant,
                    meetingId: meetingId,
                    currentSeriesIds: currentSeriesIds
                ) + "\n"
            }
        }

        await appendCalendarEvent(&block, meetingId: meetingId)
        await appendSpeakersPresent(&block, meetingId: meetingId)
        await appendSeriesLedger(&block, meetingId: meetingId)
        await appendGlossary(&block)

        return block.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Owner / participants (← commands.rs:454-496)

    private func ownerLine(_ owner: Person, meetingId: MeetingID, currentSeriesIds: Set<SeriesID>) async -> String {
        var line = "Owner: \(owner.displayName)"
        if let role = Self.trimmedNonEmpty(owner.role) {
            line += ", \(role)"
        }
        if let domain = Self.trimmedNonEmpty(owner.domain) {
            line += " — \(domain)"
        }
        if let clause = await factsClause(
            for: owner.id,
            currentMeetingId: meetingId,
            currentSeriesIds: currentSeriesIds
        ) {
            line += ": \(clause)"
        }
        if let notes = Self.injectableNotes(owner.notes) {
            line += ". \(notes)"
        }
        return line
    }

    private func participantLine(
        _ participant: Person,
        meetingId: MeetingID,
        currentSeriesIds: Set<SeriesID>
    ) async -> String {
        var line = "- \(participant.displayName)"
        if let role = Self.trimmedNonEmpty(participant.role) {
            line += " (\(role))"
        }
        if let domain = Self.trimmedNonEmpty(participant.domain) {
            line += " — \(domain)"
        }
        if let clause = await factsClause(
            for: participant.id,
            currentMeetingId: meetingId,
            currentSeriesIds: currentSeriesIds
        ) {
            line += ": \(clause)"
        }
        if let notes = Self.injectableNotes(participant.notes) {
            line += ". \(notes)"
        }
        return line
    }

    // MARK: - Linked calendar event (← commands.rs:498-543)

    private func appendCalendarEvent(_ block: inout String, meetingId: MeetingID) async {
        let events = await (try? database.calendarEvents.forMeeting(meetingId)) ?? []
        guard let event = events.first else { return }

        block += "### Calendar event (authoritative attendee roster)\n"
        block += "Title: \(event.title)\n"
        // Date line — the Swift-added line that directly answers "when was this meeting" (see header).
        block += "Date: \(Self.eventDateFormatter.string(from: event.startTime))\n"

        if let notes = Self.trimmedNonEmpty(event.notes) {
            block += "Description: \(Self.truncateChars(notes, max: Self.maxEventDescriptionChars))\n"
        }

        let attendeeStrings: [String] = event.attendees.compactMap { attendee in
            let name = Self.trimmedNonEmpty(attendee.name)
            let email = Self.trimmedNonEmpty(attendee.email)
            switch (name, email) {
            case let (name?, email?): return "\(name) <\(email)>"
            case let (name?, nil): return name
            case let (nil, email?): return email
            case (nil, nil): return nil
            }
        }
        if !attendeeStrings.isEmpty {
            block += "Attendees: \(attendeeStrings.joined(separator: ", "))\n"
        }
    }

    // MARK: - Speakers present (← commands.rs:545-583)

    private func appendSpeakersPresent(_ block: inout String, meetingId: MeetingID) async {
        let speakers = await (try? database.speakers.forMeeting(meetingId)) ?? []
        guard !speakers.isEmpty else { return }

        var identifiedNames: [String] = []
        var unidentified = 0
        for speaker in speakers {
            // Identified == links to a resolvable person; otherwise it's a provisional voice.
            let name: String? = if let personId = speaker.personId {
                await (try? database.persons.find(personId))??.displayName
            } else {
                nil
            }
            if let name {
                identifiedNames.append(name)
            } else {
                unidentified += 1
            }
        }

        var parts = identifiedNames
        // No-Fake-State: unidentified voices are COUNTED, never given a fabricated name.
        if unidentified == 1 {
            parts.append("1 unidentified speaker")
        } else if unidentified > 1 {
            parts.append("\(unidentified) unidentified speakers")
        }

        if !parts.isEmpty {
            block += "Speakers present: \(parts.joined(separator: ", "))\n"
        }
    }

    // MARK: - Series ledger (← commands.rs:585-605)

    private func appendSeriesLedger(_ block: inout String, meetingId: MeetingID) async {
        guard let seriesId = await (try? database.series.seriesIds(forMeeting: meetingId))?.first,
              let series = await (try? database.series.find(seriesId)) ?? nil,
              let ledger = Self.trimmedNonEmpty(series.ledgerMarkdown)
        else { return }

        block += "### Series ledger (running context from prior meetings in this series)\n"
        block += ledger + "\n"
    }

    // MARK: - Glossary (docs/plans/custom-vocabulary.md §2.4/§4 Step 4)

    /// Appends the "### Glossary" sub-section, global (not per-meeting) vocabulary terms. Reuses
    /// the same best-effort convention as the other appenders: a DB failure or an empty/disabled
    /// vocabulary drops this section entirely, never blocking the rest of the block. Zero enabled
    /// terms produces no heading at all (`VocabularyGlossary.block` returns `""`).
    private func appendGlossary(_ block: inout String) async {
        let terms = await (try? database.vocabulary.enabledTerms()) ?? []
        let glossary = VocabularyGlossary.block(for: terms)
        guard !glossary.isEmpty else { return }
        block += glossary + "\n"
    }

    // MARK: - Facts (← `person_facts_clause`, commands.rs:398-414)

    /// The person's top *eligible* active facts joined into one clause, or `nil` when there are
    /// none. Eligibility is a whitelist (see `eligibleDateText`), not a label: a previous approach
    /// included every fact and merely labelled cross-meeting ones "(unrelated background)", but a
    /// real regenerate showed a 4B model promoting labelled owner facts straight into Action Items
    /// anyway (docs/plans bleed-fix history) — so facts that can't be shown to belong to this
    /// meeting or its series are dropped from the prompt entirely, not just flagged.
    private func factsClause(
        for personId: PersonID,
        currentMeetingId: MeetingID,
        currentSeriesIds: Set<SeriesID>
    ) async -> String? {
        guard let facts = try? await database.profileFacts.activeFacts(for: personId), !facts.isEmpty else {
            return nil
        }

        var eligible: [(fact: ProfileFact, dateText: String)] = []
        for fact in facts {
            guard let dateText = await eligibleDateText(
                for: fact,
                currentMeetingId: currentMeetingId,
                currentSeriesIds: currentSeriesIds
            ) else { continue }
            eligible.append((fact, dateText))
        }

        // ← `top_active_facts` ordering (confidence DESC, created_at DESC), capped at `maxPersonFacts`.
        let top = eligible
            .sorted { lhs, rhs in
                if lhs.fact.confidence != rhs.fact.confidence {
                    return lhs.fact.confidence > rhs.fact.confidence
                }
                return lhs.fact.createdAt > rhs.fact.createdAt
            }
            .prefix(Self.maxPersonFacts)
            .map { Self.renderFact($0.fact, dateText: $0.dateText) }

        return top.isEmpty ? nil : top.joined(separator: "; ")
    }

    /// Provable-relevance eligibility gate. A fact is eligible for prompt injection ONLY if its
    /// `sourceMeetingId` resolves to a real meeting row that is either the meeting currently being
    /// summarized or a member of one of its series (`currentSeriesIds`). Returns that source
    /// meeting's date text (for the `(background, from <date>)` framing) when eligible, `nil`
    /// otherwise.
    ///
    /// Unlike the other best-effort reads in this file, unresolvable provenance — a nil/empty
    /// `sourceMeetingId`, or one that doesn't resolve to an existing meeting row (both real shapes
    /// seen in the store: blank ids and dangling legacy `meeting-`-prefixed ids) — degrades to
    /// EXCLUDED, never included. The old code treated "can't prove it's unrelated" as "assume
    /// relevant", which is backwards for prompt safety: the failure mode of over-inclusion is a
    /// small model promoting unrelated facts into Action Items (see `factsClause` above).
    private func eligibleDateText(
        for fact: ProfileFact,
        currentMeetingId: MeetingID,
        currentSeriesIds: Set<SeriesID>
    ) async -> String? {
        guard let sourceMeetingId = fact.sourceMeetingId,
              let sourceMeeting = try? await database.meetings.find(sourceMeetingId) ?? nil
        else { return nil }

        let isEligible: Bool = if sourceMeetingId == currentMeetingId {
            true
        } else if let sourceSeriesIds = try? await database.series.seriesIds(forMeeting: sourceMeetingId) {
            !currentSeriesIds.isDisjoint(with: sourceSeriesIds)
        } else {
            false
        }
        guard isEligible else { return nil }

        return Self.factDateFormatter.string(from: sourceMeeting.createdAt)
    }

    /// Renders one eligible fact as a dated background clause, e.g.
    /// `"training on X (background, from Jul 14, 2026)"`. The date is always present here —
    /// `eligibleDateText` only returns non-nil once it has already resolved a real source meeting.
    private static func renderFact(_ fact: ProfileFact, dateText: String) -> String {
        "\(fact.factText) (background, from \(dateText))"
    }

    // MARK: - Small helpers (← commands.rs:382-395)

    /// One consistent, human-readable date rendering for the added `Date:` line. Medium date +
    /// short time in the current locale/timezone (e.g. "Jul 22, 2026 at 3:33 PM").
    static let eventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Date-only rendering for a fact's background provenance (e.g. "Jul 14, 2026") — no time
    /// component, since a fact's origin day is what matters for "is this today or old news".
    static let factDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// `public` (Slice A, docs/plans/summary-pipeline-completion.md Gap 1): `SummaryRunner`
    /// (`AriViewModels`) reuses this for its own bounded calendar-context string rather than
    /// duplicating the trim rule.
    public static func trimmedNonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// ← `injectable_notes`: trimmed, truncated to `maxPersonNotesChars` with an ellipsis, or `nil`.
    static func injectableNotes(_ notes: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(notes) else { return nil }
        return truncateChars(trimmed, max: maxPersonNotesChars)
    }

    /// Unicode-scalar truncation with an ellipsis suffix (Rust `chars().take(n)`). `public` — see
    /// `trimmedNonEmpty` above for the same cross-module reuse rationale (Slice A, Gap 1).
    public static func truncateChars(_ text: String, max maximum: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maximum {
            return trimmed
        }
        return String(trimmed.prefix(maximum)) + "…"
    }
}
