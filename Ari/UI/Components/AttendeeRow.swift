//
//  AttendeeRow.swift — shared attendee row (initial-circle avatar + name/email), extracted from
//  `EventDetailSheet` so `LinkedEventCard` (docs/plans/calendar-series-intelligence.md §2.5,
//  Feature 3) can reuse it rather than duplicating the pattern.
//
import AriKit
import SwiftUI

struct AttendeeRow: View {
    let attendee: Attendee
    /// The attendee's real name resolved from a matching `Person` record (`PersonRepository
    /// .findByEmail`), when the app has one on file — preferred over the calendar-supplied
    /// `attendee.name`, which is frequently absent (e.g. many EWS/external attendees).
    var resolvedName: String?
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
                Text(displayName)
                    .marginaliaTextStyle(.body, in: scheme)
                if displayName != attendee.email, let email = attendee.email {
                    Text(email)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
        }
    }

    private var displayName: String {
        resolvedName ?? attendee.name ?? attendee.email ?? "Unknown attendee"
    }

    private var initial: String {
        String(displayName.prefix(1)).uppercased()
    }
}
