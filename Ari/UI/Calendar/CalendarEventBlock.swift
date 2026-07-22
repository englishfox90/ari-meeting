//
//  CalendarEventBlock.swift — one tinted event block (docs/plans/arikit-calendar-ui.md §3).
//
//  Tinted from the source calendar's real EventKit color (`calendarSyncSetting.color`) — real
//  data, not a design token, mirroring the color dot in Calendar settings (same stance as
//  `WeekGrid.tsx:17-32`). No color → an honest neutral Marginalia surface, never a fabricated
//  tint. A thin left accent bar in the raw calendar color keeps overlapping calendars
//  distinguishable even when the wash blends together.
//
import AriKit
import SwiftUI

struct CalendarEventBlock: View {
    let event: CalendarEvent
    /// Timed blocks show a time-range subtitle; all-day blocks (in the pinned all-day row) omit
    /// it — there is no time to show.
    let showsTimeRange: Bool
    let tintHex: String?
    let isLinked: Bool

    @Environment(\.colorScheme) private var scheme

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(event.title)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkBody)
                    .lineLimit(1)
                if isLinked {
                    Image(systemName: "link")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.marginalia(.accent, in: scheme))
                }
            }
            if showsTimeRange {
                Text(timeRangeLabel)
                    .marginaliaTextStyle(.timecode, in: scheme, ink: .inkSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fillColor)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accentColor)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: 1)
        }
    }

    private var timeRangeLabel: String {
        "\(event.startTime.formatted(Self.timeFormat)) – \(event.endTime.formatted(Self.timeFormat))"
    }

    private var accentColor: Color {
        HexColor.color(fromHex: tintHex) ?? Color.marginalia(.inkSecondary, in: scheme)
    }

    private var fillColor: Color {
        guard let tint = HexColor.color(fromHex: tintHex) else {
            return Color.marginalia(.elevated, in: scheme)
        }
        return tint.opacity(scheme == .dark ? 0.24 : 0.14)
    }

    private var strokeColor: Color {
        guard let tint = HexColor.color(fromHex: tintHex) else {
            return Color.marginalia(.hairline, in: scheme)
        }
        return tint.opacity(0.4)
    }
}
