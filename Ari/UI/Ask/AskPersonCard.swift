//
//  AskPersonCard.swift — the inline "resolved person" entity card rendered above an assistant
//  answer (docs/plans/ask-meetings-tools-and-cards.md §5.2), sibling to `AskSourceCard.swift`.
//  Renders ONLY from a real, deterministically resolved `PersonCardPayload` (Slice B's
//  `RecallTools.findPerson`/`meetings(withPerson:)`) — every field shown is real; a missing
//  `role`/`organization`/`lastMeetingDate` OMITS that line/clause rather than showing a placeholder
//  (No-Fake-State, §5.3). The meeting-involvement count is calendar-attendee-matched, not
//  diarization-verified presence (plan §4.4) — the copy says so explicitly.
//
import AriKit
import SwiftUI

struct AskPersonCard: View {
    let payload: PersonCardPayload
    let onOpenPerson: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text(payload.displayName)
                .marginaliaTextStyle(.headline, in: scheme, ink: .inkHeading)

            // Omitted entirely (not "—"/"Unknown") when both role and organization are absent.
            if let roleOrganization {
                Text(roleOrganization)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }

            Text(metaLine)
                .marginaliaTextStyle(.body, in: scheme)

            Button {
                onOpenPerson(payload.personId)
            } label: {
                Label("Open person", systemImage: "arrow.right")
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

    private var roleOrganization: String? {
        RecallCardDisplay.roleOrganizationLine(role: payload.role, organization: payload.organization)
    }

    /// "N meeting(s) involving them (via calendar), last met `<date>`" — real, un-estimated count;
    /// the "last met" clause is omitted entirely when there's no real `lastMeetingDate`.
    private var metaLine: String {
        RecallCardDisplay.personMetaLine(
            meetingCount: payload.meetingCount,
            lastMeetingDate: payload.lastMeetingDate
        )
    }
}
