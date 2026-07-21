//
//  SidebarSection.swift — the sidebar's top-level WORKBENCH sections (home-centric shell
//  rework; see the home + left-rail layout plan).
//
//  `newMeeting`, `ask`, and `calendar` render honest "coming soon" placeholders today — the
//  capture, recall, and calendar features aren't built yet (No-Fake-State: the sidebar rows
//  exist because the destinations exist, even if the destination is an honest placeholder).
//
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case newMeeting
    case savedMeetings
    case series
    case ask
    case calendar
    case people

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .newMeeting: "New meeting"
        case .savedMeetings: "Saved meetings"
        case .series: "Series"
        case .ask: "Ask meetings"
        case .calendar: "Calendar"
        case .people: "People"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .newMeeting: "mic"
        case .savedMeetings: "text.rectangle.page"
        case .series: "arrow.triangle.2.circlepath"
        case .ask: "sparkle.magnifyingglass"
        case .calendar: "calendar"
        case .people: "person.2"
        }
    }

    /// The WORKBENCH nav list, in display order.
    static var workbench: [SidebarSection] {
        [.home, .newMeeting, .savedMeetings, .series, .ask, .calendar, .people]
    }
}
