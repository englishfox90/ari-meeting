//
//  SidebarSection.swift — the sidebar's top-level sections (plan §6 Navigation model).
//
//  `ask` is reserved for the future Ask/recall UI (out of scope for S6 — no screen ships)
//  so the enum shape doesn't need to change when that lands.
//
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case meetings
    case people
    case series
    case ask

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .meetings: "Meetings"
        case .people: "People"
        case .series: "Series"
        case .ask: "Ask"
        }
    }

    var symbolName: String {
        switch self {
        case .meetings: "list.bullet.rectangle"
        case .people: "person.2"
        case .series: "arrow.triangle.2.circlepath"
        case .ask: "sparkle.magnifyingglass"
        }
    }

    /// Sections actually rendered in S6 — `ask` is reserved but ships no screen yet.
    static var built: [SidebarSection] {
        [.meetings, .people, .series]
    }
}
