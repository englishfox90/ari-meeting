//
//  AskCalendarEventCard.swift — the inline "resolved calendar event" entity card rendered above an
//  assistant answer (docs/plans/ask-meetings-tools-and-cards.md §5.2, calendar-aware lookup fix,
//  2026-07-23). Renders ONLY from a real `CalendarEventCardPayload` (`RecallTools.
//  calendarEventsToday(matchingAttendeeName:)`) — every field shown is real.
//
//  Deliberately visually/textually distinct from `AskMeetingCard`: a calendar event means
//  "scheduled," never "recorded" or "discussed" — this card never implies transcript/summary
//  content exists unless `isLinkedToRecordedMeeting` is true, in which case it offers to open the
//  linked recorded meeting (a SEPARATE, real fact, not implied by the calendar event alone).
//
import AriKit
import SwiftUI

struct AskCalendarEventCard: View {
    let payload: CalendarEventCardPayload
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Label("Scheduled", systemImage: "calendar")
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)

            Text(payload.title)
                .marginaliaTextStyle(.headline, in: scheme, ink: .inkHeading)

            if let friendly = RecallCardDisplay.friendlyDate(payload.startTime) {
                Text(friendly)
                    .marginaliaTextStyle(.body, in: scheme)
            }

            if !payload.attendeeNames.isEmpty {
                Text(payload.attendeeNames.joined(separator: ", "))
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }

            // Stated only when REAL — never implied otherwise (No-Fake-State: a calendar entry
            // alone is never "recorded or discussed"). No "open" action yet: the payload does not
            // carry the linked meeting's id, so wiring a real navigation action is a Slice C
            // follow-up once that field exists.
            if payload.isLinkedToRecordedMeeting {
                Text("A recorded meeting is linked to this event.")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }
}
