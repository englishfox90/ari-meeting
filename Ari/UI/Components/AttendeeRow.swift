//
//  AttendeeRow.swift — shared attendee row (initial-circle avatar + name/email), extracted from
//  `EventDetailSheet` so `LinkedEventCard` (docs/plans/calendar-series-intelligence.md §2.5,
//  Feature 3) can reuse it rather than duplicating the pattern.
//
import AriKit
import SwiftUI

struct AttendeeRow: View {
    let attendee: Attendee
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Circle()
                .fill(Color.marginalia(.elevated, in: scheme))
                .frame(width: 22, height: 22)
                .overlay {
                    Text(initial)
                        .marginaliaTextStyle(.caption, in: scheme)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(attendee.name ?? attendee.email ?? "Unknown attendee")
                    .marginaliaTextStyle(.body, in: scheme)
                if attendee.name != nil, let email = attendee.email {
                    Text(email)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
        }
    }

    private var initial: String {
        let source = attendee.name ?? attendee.email ?? "?"
        return String(source.prefix(1)).uppercased()
    }
}
