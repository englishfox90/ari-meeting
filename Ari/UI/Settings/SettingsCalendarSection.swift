//
//  SettingsCalendarSection.swift — Calendar settings (docs/plans/settings-ui.md §6,
//  S7 EventKit slice docs/plans/arikit-calendar.md §5).
//
//  Three blocks, all LIVE once `AppEnvironment` injects a real `EventKitCalendarSource` (C4):
//  - "Access" — the Grant button is enabled behind `SettingsDisabledGroup`'s real
//    `grantAccessAvailability` (still honestly `.disabled` for any caller that hasn't injected a
//    source, e.g. a headless preview); the current permission is shown as real state, never
//    assumed.
//  - "Sync" — a Sync Now affordance surfacing the real `CalendarSyncReport` counts or the real
//    error (No-Fake-State — never a fabricated count).
//  - Per-calendar sync toggles — store round-trip is LIVE
//    (`CalendarSettingsViewModel.setSelected` persists via `CalendarEventRepository.setSyncSetting`);
//    the empty-state copy is permission-appropriate ("No access granted" vs. "No calendars
//    found"), never a placeholder row list.
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
                VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                    SettingsDisabledGroup(availability: viewModel.grantAccessAvailability) {
                        HStack {
                            Text(permissionStatusText)
                                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                            Spacer()
                            // Once access is granted there is nothing left to grant — offering
                            // the button anyway would be a fake affordance (No-Fake-State).
                            if viewModel.permission != .granted {
                                Button("Grant Access") {
                                    Task { await viewModel.requestAccess() }
                                }
                                .buttonStyle(.marginalia(.primary, .large, in: scheme))
                            }
                        }
                    }
                }
            }

            SettingsCard(title: "Sync") {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                    HStack {
                        Text(syncStatusText)
                            .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                        Spacer()
                        Button("Sync Now") {
                            Task { await viewModel.syncNow() }
                        }
                        .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                        .disabled(viewModel.permission != .granted)
                    }
                    if let error = viewModel.lastSyncError {
                        MarginaliaBanner(kind: .error, message: error, scheme: scheme)
                    }
                }
            }

            SettingsCard(title: "Calendars") {
                if viewModel.calendars.isEmpty {
                    Text(emptyCalendarsText)
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

    // MARK: - Honest copy (real VM state, never hardcoded stand-ins)

    private var permissionStatusText: String {
        switch viewModel.permission {
        case .notDetermined: "Access not yet requested."
        case .granted: "Access granted."
        case .denied: "Access denied. Enable Calendar access for Ari in System Settings ▸ Privacy & Security."
        }
    }

    private var syncStatusText: String {
        if let report = viewModel.lastSyncReport {
            return "Last sync: \(report.fetched) fetched · \(report.pruned) pruned · \(report.autoLinked) auto-linked."
        }
        // No report this session, but the store remembers when a sync last wrote — show that
        // real timestamp instead of pretending no sync ever ran.
        if let syncedAt = viewModel.lastSyncedAt {
            return "Last synced \(syncedAt.formatted(date: .abbreviated, time: .shortened))."
        }
        return "No sync has run yet."
    }

    /// Permission-appropriate empty-state copy (plan §5) — distinguishes "nothing to show
    /// because access isn't granted" from "access is granted but nothing has synced yet".
    private var emptyCalendarsText: String {
        viewModel.permission == .granted ? "No calendars found." : "No access granted."
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
