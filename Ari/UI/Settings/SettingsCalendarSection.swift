//
//  SettingsCalendarSection.swift — Calendar settings (docs/plans/settings-ui.md §6).
//
//  Two blocks:
//  - "Grant access" — HONEST-DISABLED: no EventKit source exists in the Swift app yet, so the
//    primary button is truly `.disabled` behind `SettingsDisabledGroup`'s real
//    `grantAccessAvailability` reason banner. Never a fake-functional stand-in.
//  - Per-calendar sync toggles — store round-trip is LIVE (`CalendarSettingsViewModel.setSelected`
//    persists via `CalendarEventRepository.setSyncSetting`); the list itself stays honestly empty
//    until a real EventKit sync populates `calendarSyncSetting` (No-Fake-State — no placeholder
//    rows).
//
import AriKit
import AriViewModels
import SwiftUI

struct SettingsCalendarSection: View {
    let viewModel: CalendarSettingsViewModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "Calendar")

            SettingsCard(title: "Access") {
                SettingsDisabledGroup(availability: viewModel.grantAccessAvailability) {
                    Button("Grant Access") {}
                        .buttonStyle(.marginalia(.primary, .large, in: scheme))
                }
            }

            SettingsCard(title: "Calendars") {
                if viewModel.calendars.isEmpty {
                    Text("No calendars yet — Calendar access hasn't been wired into the Swift app.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                } else {
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                        ForEach(viewModel.calendars) { calendar in
                            calendarRow(for: calendar)
                            if calendar.id != viewModel.calendars.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func calendarRow(for calendar: CalendarSettingsViewModel.CalendarSyncRow) -> some View {
        HStack(alignment: .center, spacing: MarginaliaSpacing.sm.value) {
            colorDot(for: calendar.color)
            MarginaliaToggleRow(
                calendar.calendarTitle ?? calendar.calendarId,
                isOn: Binding(
                    get: { calendar.selected },
                    set: { newValue in
                        Task {
                            try? await viewModel.setSelected(newValue, for: calendar.calendarId)
                        }
                    }
                ),
                scheme: scheme
            )
        }
    }

    private func colorDot(for hex: String?) -> some View {
        Circle()
            .fill(color(fromHex: hex) ?? Color.marginalia(.elevated, in: scheme))
            .overlay {
                Circle()
                    .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
            }
            .frame(width: 10, height: 10)
    }

    /// Parses a `#RRGGBB`/`RRGGBB` hex string into a `Color`. Returns `nil` (never a fabricated
    /// color) for anything unparseable so an unrecognized swatch falls back to a neutral dot.
    private func color(fromHex hex: String?) -> Color? {
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
