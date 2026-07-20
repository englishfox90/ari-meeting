//
//  PeopleContext.swift — Phase-2 people/context enrichment for Ask Meetings (plan §5 Slice 7,
//  ← ari-engine/src/recall/context.rs). Two jobs, both pool-only in Rust (runtime-agnostic, no
//  AppHandle needed) and here repository-only (no raw SQLite, plan §2.2):
//    1. `attachPeople`      — stamp each source with the people present in its meeting.
//    2. `peopleContextBlock` — a terse owner/attendee/calendar reference block appended to the
//                              prompt so who-owns-what / who-was-there questions are answerable.
//  Everything stays additive and bounded to avoid prompt bloat (`RecallBounds` §"People-context
//  caps").
//
//  ⚠️ PARTIAL PORT BY DESIGN (plan §5 Slice 7 / §8 "Diarization dependency in People context").
//  The frozen Rust `meeting_people` resolves a meeting's people from TWO data sources, in order:
//    1. Diarization-derived speaker labels (`crate::diarization::labeling::
//       resolve_meeting_speaker_labels`) — identified speakers, highest-confidence signal.
//    2. Only when (1) found nobody: the `meeting_participants` link table via
//       `PersonRepository::list_participants` — the linked calendar/participant roster.
//  NEITHER has a Swift-side equivalent yet: diarization labeling is Phase 3.5 (not yet ported,
//  gated — see `docs/plans/arikit-recall.md` §8), and no `meeting_participants` link table exists
//  in the AriKit Store (only `PersonRepository.owner()/.all()/.find(_:)` were handed to this
//  slice). Per No-Fake-State (plan §7), `attachPeople` below does NOT invent a substitute signal
//  for "who spoke": it leaves `speakers` exactly as supplied (the `RecallSource` default, `[]`)
//  rather than fabricating attendee-derived names under a "speakers" label nobody confirmed.
//  TODO(Phase 3.5): wire `resolve_meeting_speaker_labels` here, then reinstate the participant-
//  roster fallback behind it, matching `context.rs:38-67` exactly.
//
//  `peopleContextBlock`'s meeting-scoped half, by contrast, CAN be ported faithfully today: its
//  calendar-attendee line and its owner block use only data this slice's repositories already
//  hold (`CalendarEventRepository.forMeeting`, `PersonRepository.owner()`). Its per-person "top
//  fact" bullet list is a **documented adaptation**: the Rust source reads it from
//  `PersonRepository::list_participants` (the missing link table); this port substitutes a real,
//  non-fabricated signal instead of a fabricated one — matching this event's attendees to existing
//  `Person` rows by e-mail (the very mechanism F2 already uses to seed identity from calendar
//  invitees, `.claude/context/product.md`'s "identity seeded from calendar emails"). Both the
//  attendee line and the matched-participant list are capped at `RecallBounds.maxPeoplePerMeeting`
//  — a single unified bound in place of the Rust source's two separate literals (`MAX_PEOPLE_PER_
//  MEETING = 8` vs. a hardcoded `.take(6)`), and a deliberate ADDED bound on the raw attendee line
//  itself (the Rust source does not cap it) so a large invite list can never grow the prompt
//  block unbounded (plan principle 6, bounded context).
//
import Foundation

/// Builds the Ask-Meetings people/context block from the Store's person, profile-fact, and
/// calendar repositories. `Sendable` value type over injected repository handles — mirrors
/// `HybridSearch`/`Indexer`'s shape; safe to call from any isolation domain.
public struct PeopleContext: Sendable {
    private let persons: PersonRepository
    private let profileFacts: ProfileFactRepository
    private let calendarEvents: CalendarEventRepository

    public init(
        persons: PersonRepository,
        profileFacts: ProfileFactRepository,
        calendarEvents: CalendarEventRepository
    ) {
        self.persons = persons
        self.profileFacts = profileFacts
        self.calendarEvents = calendarEvents
    }

    // MARK: - attachPeople (← `attach_people`, context.rs:70-79)

    /// Populate `speakers` on every source (cached per meeting in the Rust original). See the
    /// PARTIAL PORT note above: today this is an honest no-op — there is no non-fabricated signal
    /// available yet for "who spoke in this meeting" — until diarization labeling (Phase 3.5)
    /// lands. Kept `async` (no `throws`), mirroring the Rust signature's shape (`attach_people`
    /// swallows its own repository errors internally rather than propagating a `Result`).
    public func attachPeople(_ sources: inout [RecallSource]) async {
        // Intentionally empty — see the file-header PARTIAL PORT note. `sources` is left exactly
        // as the caller supplied it (never inventing a "speakers" label).
        _ = sources
    }

    // MARK: - peopleContextBlock (← `people_context_block`, context.rs:84-181)

    /// Build the terse owner + attendee/calendar reference block for the prompt. Returns `""` when
    /// there is nothing real to add (No-Fake-State — never a header with nothing under it).
    /// `scopedMeetingId` = non-`nil` for a meeting-scoped ask (richer, one meeting), `nil` for
    /// global (per-meeting people lines drawn from `sources.speakers`, ← context.rs:151-171).
    public func peopleContextBlock(
        sources: [RecallSource],
        scopedMeetingId: MeetingID?
    ) async -> String {
        var lines: [String] = []

        // Errors are swallowed here exactly as `if let Ok(Some(owner)) = ...` swallows them in
        // Rust — a DB hiccup means "nothing to add," not a failed prompt assembly.
        if let owner = await (try? persons.owner()) ?? nil {
            var who = owner.displayName
            if let role = Self.trimmedNonEmpty(owner.role) {
                who += ", \(role)"
            }
            if let organization = Self.trimmedNonEmpty(owner.organization) {
                who += " at \(organization)"
            }
            lines.append("Owner (you): \(who).")
        }

        if let scopedMeetingId {
            await appendMeetingScopedLines(&lines, meetingId: scopedMeetingId)
        } else {
            Self.appendGlobalLines(&lines, sources: sources)
        }

        guard !lines.isEmpty else { return "" }
        return "### People & meeting context (reference only; transcript sources remain authoritative)\n"
            + lines.joined(separator: "\n")
    }

    // MARK: - Meeting-scoped half (← context.rs:108-149)

    private func appendMeetingScopedLines(_ lines: inout [String], meetingId: MeetingID) async {
        let events = await (try? calendarEvents.forMeeting(meetingId)) ?? []
        guard let event = events.first else { return }

        // Attendee line — capped at `maxPeoplePerMeeting` (a deliberate ADDED bound, see header).
        let attendeeNames: [String] = event.attendees.compactMap { attendee in
            if let name = Self.trimmedNonEmpty(attendee.name) {
                return name
            }
            return attendee.email
        }
        let cappedAttendeeNames = Array(attendeeNames.prefix(RecallBounds.maxPeoplePerMeeting))
        if !cappedAttendeeNames.isEmpty {
            lines.append(
                "Calendar event \"\(event.title)\": attendees — \(cappedAttendeeNames.joined(separator: ", "))."
            )
        }

        if let notes = Self.trimmedNonEmpty(event.notes) {
            lines.append("Event notes: \(Self.truncateChars(notes, max: RecallBounds.maxNoteChars))")
        }

        // Participant fact bullets — the documented adaptation (see header): match this event's
        // attendees to existing `Person` rows by e-mail (no `meeting_participants` link table
        // exists yet), capped at `maxPeoplePerMeeting`.
        let allPersons = await (try? persons.all()) ?? []
        guard !allPersons.isEmpty else { return }
        var matched = 0
        for attendee in event.attendees {
            guard matched < RecallBounds.maxPeoplePerMeeting else { break }
            guard let email = Self.trimmedNonEmpty(attendee.email)?.lowercased() else { continue }
            guard let person = allPersons.first(where: { $0.email?.lowercased() == email }) else {
                continue
            }
            matched += 1
            guard let facts = try? await profileFacts.activeFacts(for: person.id),
                  let topFact = Self.topFact(facts)
            else {
                continue
            }
            lines
                .append(
                    "- \(person.displayName): \(Self.truncateChars(topFact.factText, max: RecallBounds.maxFactChars))"
                )
        }
    }

    // MARK: - Global half (← context.rs:151-171)

    private static func appendGlobalLines(_ lines: inout [String], sources: [RecallSource]) {
        var seen: Set<String> = []
        for source in sources {
            // `seen.insert` is evaluated unconditionally first, exactly as the Rust
            // `!seen.insert(...) || source.speakers.is_empty()` short-circuit does — a meeting is
            // marked "seen" on its FIRST source regardless of whether that source had speakers.
            guard seen.insert(source.meetingId).inserted else { continue }
            guard !source.speakers.isEmpty else { continue }
            let date = source.meetingDate
                .map { String($0.prefix(10)) }
                .flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            lines.append("- \"\(source.title)\"\(date) — people: \(source.speakers.joined(separator: ", ")).")
        }
    }

    // MARK: - Small helpers (← `truncate_chars`/`short_date`, context.rs:23-34)

    private static func trimmedNonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Unicode-scalar truncation (Rust `chars().count()`), matching `ContextBounding`'s convention.
    private static func truncateChars(_ text: String, max maximum: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Recall.scalars(trimmed)
        if characters.count <= maximum {
            return trimmed
        }
        let head = Recall.string(fromScalars: characters.prefix(maximum))
        return "\(head)…"
    }

    /// Mirrors `top_active_facts`' ordering (`confidence DESC, created_at DESC`) with an implicit
    /// `LIMIT 1` — picks the single most-confident, most-recent active fact.
    private static func topFact(_ facts: [ProfileFact]) -> ProfileFact? {
        facts.max { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence < rhs.confidence
            }
            return lhs.createdAt < rhs.createdAt
        }
    }
}
