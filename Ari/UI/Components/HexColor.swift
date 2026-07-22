//
//  HexColor.swift — shared `#RRGGBB`/`RRGGBB` hex → `Color` parsing (promoted from
//  `SettingsCalendarSection.color(fromHex:)`, docs/plans/arikit-calendar-ui.md §3, so the
//  Calendar settings dot and the week grid's event tints share one implementation).
//
//  Real EventKit calendar colors are plain data, not design tokens — this stays a small internal
//  helper (not part of the Marginalia DesignSystem in AriKit) because it exists to render
//  arbitrary external color strings, not a brand palette.
//
import SwiftUI

enum HexColor {
    /// Parses a `#RRGGBB`/`RRGGBB` hex string into a `Color`. Returns `nil` (never a fabricated
    /// color) for anything unparseable, so callers fall back to an honest neutral swatch.
    static func color(fromHex hex: String?) -> Color? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            return nil
        }
        let red = Double((rgb & 0xFF0000) >> 16) / 255
        let green = Double((rgb & 0x00FF00) >> 8) / 255
        let blue = Double(rgb & 0x0000FF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}
