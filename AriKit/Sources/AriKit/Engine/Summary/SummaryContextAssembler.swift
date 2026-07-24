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
        let participants = await (try? database.persons.participants(inMeeting: meetingId)) ?? []

        // ← commands.rs:441-443: nothing to anchor the block on → empty string, not a bare header.
        guard owner != nil || !participants.isEmpty else { return "" }

        var block = "### Meeting context (for the summarizer)\n"

        // Organization (owner-derived; see header). Everyone below works there unless noted.
        if let organization = Self.trimmedNonEmpty(owner?.organization) {
            block += "Organization: \(organization) (everyone below works at \(organization) unless noted).\n"
        }

        if let owner {
            block += await ownerLine(owner) + "\n"
        }

        if !participants.isEmpty {
            block += "Participants:\n"
            for participant in participants {
                block += await participantLine(participant) + "\n"
            }
        }

        await appendCalendarEvent(&block, meetingId: meetingId)
        await appendSpeakersPresent(&block, meetingId: meetingId)
        await appendSeriesLedger(&block, meetingId: meetingId)
        await appendGlossary(&block)

        return block.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Owner / participants (← commands.rs:454-496)

    private func ownerLine(_ owner: Person) async -> String {
        var line = "Owner: \(owner.displayName)"
        if let role = Self.trimmedNonEmpty(owner.role) {
            line += ", \(role)"
        }
        if let domain = Self.trimmedNonEmpty(owner.domain) {
            line += " — \(domain)"
        }
        if let clause = await factsClause(for: owner.id) {
            line += ": \(clause)"
        }
        if let notes = Self.injectableNotes(owner.notes) {
            line += ". \(notes)"
        }
        return line
    }

    private func participantLine(_ participant: Person) async -> String {
        var line = "- \(participant.displayName)"
        if let role = Self.trimmedNonEmpty(participant.role) {
            line += " (\(role))"
        }
        if let domain = Self.trimmedNonEmpty(participant.domain) {
            line += " — \(domain)"
        }
        if let clause = await factsClause(for: participant.id) {
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

    /// The person's top active facts joined into one clause, or `nil` when there are none.
    private func factsClause(for personId: PersonID) async -> String? {
        guard let facts = try? await database.profileFacts.activeFacts(for: personId), !facts.isEmpty else {
            return nil
        }
        // ← `top_active_facts` ordering (confidence DESC, created_at DESC), capped at `maxPersonFacts`.
        let top = facts
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(Self.maxPersonFacts)
            .map(\.factText)
        return top.isEmpty ? nil : top.joined(separator: ", ")
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
