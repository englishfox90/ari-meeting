//
//  AskMeetingCard.swift — the inline "resolved meeting" entity card rendered above an assistant
//  answer (docs/plans/ask-meetings-tools-and-cards.md §5.2), sibling to `AskSourceCard.swift` and
//  reusing its exact Marginalia visual conventions. Renders ONLY from a real, deterministically
//  resolved `MeetingCardPayload` — there is no synthesized/placeholder state (No-Fake-State, §5.3).
//
import AriKit
import SwiftUI

struct AskMeetingCard: View {
    let payload: MeetingCardPayload
    let onOpenMeeting: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text(payload.title)
                .marginaliaTextStyle(.headline, in: scheme, ink: .inkHeading)

            // Omitted entirely (not a placeholder) when the meeting has no real date.
            if let friendlyDate {
                Text(friendlyDate)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }

            Button {
                onOpenMeeting(payload.meetingId)
            } label: {
                Label("Open meeting", systemImage: "arrow.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    private var friendlyDate: String? {
        RecallCardDisplay.friendlyDate(payload.meetingDate)
    }
}
