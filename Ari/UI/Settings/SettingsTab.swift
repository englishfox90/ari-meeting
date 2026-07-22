//
//  SettingsTab.swift — the 5 Settings sections, switched via the toolbar's stock segmented
//  Picker (docs/plans/settings-ui.md §6). Sentence-case titles — stock Picker labels, never
//  uppercased eyebrow copy.
//
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case recordings
    case intelligence
    case calendar

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .general: "General"
        case .recordings: "Recordings"
        case .intelligence: "Intelligence"
        case .calendar: "Calendar"
        }
    }
}
