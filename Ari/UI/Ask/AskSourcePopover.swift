//
//  AskSourcePopover.swift — the tappable `[S<n>]` citation chip + its source popover
//  (docs/plans/ari-ask-ui.md §7/§8). Resolution against `sources[index - 1]` — and the literal
//  fallback for an out-of-range index — happens in `AskAnswerText`; this view only ever renders
//  a REAL, already-resolved `RecallSource`.
//
import AriKit
import SwiftUI

struct AskSourcePopover: View {
    let index: Int
    let source: RecallSource
    let onOpenMeeting: (String) -> Void
    @State private var isPresented = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MarginaliaBadge("S\(index)", style: .accent, symbol: "text.quote", scheme: scheme) {
            isPresented = true
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AskSourceCard(index: index, source: source, onOpenMeeting: { meetingId in
                isPresented = false
                onOpenMeeting(meetingId)
            })
        }
    }
}
