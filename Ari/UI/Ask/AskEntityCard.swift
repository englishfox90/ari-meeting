//
//  AskEntityCard.swift — dispatches a resolved `RecallCardPayload` to the matching entity card view
//  (docs/plans/ask-meetings-tools-and-cards.md §5.2). `AskConsoleView` renders this above the
//  answer prose, inside the same bordered assistant-row container, only when a non-nil card is
//  present (No-Fake-State, §5.3).
//
import AriKit
import SwiftUI

struct AskEntityCard: View {
    let card: RecallCardPayload
    let onOpenMeeting: (String) -> Void
    let onOpenPerson: (String) -> Void
    let onOpenSeries: (String) -> Void

    var body: some View {
        switch card {
        case let .meeting(payload):
            AskMeetingCard(payload: payload, onOpenMeeting: onOpenMeeting)
        case let .person(payload):
            AskPersonCard(payload: payload, onOpenPerson: onOpenPerson)
        case let .series(payload):
            AskSeriesCard(payload: payload, onOpenSeries: onOpenSeries)
        }
    }
}
