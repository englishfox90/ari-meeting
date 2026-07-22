//
//  CalendarWeekGrid.swift — the week grid: hour rows, day columns, now line, all-day row
//  (docs/plans/arikit-calendar-ui.md §2/§3). Ports the layout behaviors of
//  `WeekGrid.tsx:118-260` visually into Marginalia (ink/canvas/hairline tokens, our type ramp) —
//  not a clone of Apple Calendar or the Rust page's shadcn styling.
//
//  ONE shared scroll container (plan risk (a) — `WeekGrid.tsx:144-148`'s own lesson): the sticky
//  day header + all-day row and the scrolling hour grid live in the same `ScrollView`, as a
//  pinned `Section` header inside a `LazyVStack`, so both share the exact same column widths —
//  a separately-positioned header would drift once a scrollbar appears.
//
import AriKit
import AriViewModels
import SwiftUI

struct CalendarWeekGrid: View {
    let weekDays: [Date]
    /// The visible week's events (both timed and all-day) — pure data, laid out here via
    /// `CalendarWeekLayout`.
    let events: [CalendarEvent]
    let calendarColors: [String: String]
    let linkedMeetingTitles: [MeetingID: String]
    let now: Date
    let calendar: Calendar
    let onSelectEvent: (CalendarEvent) -> Void

    @Environment(\.colorScheme) private var scheme

    private static let hourHeight: CGFloat = 48
    private static let gutterWidth: CGFloat = 44
    private static let initialScrollHour = 7

    private var timedByDay: [[CalendarWeekLayout.PositionedEvent]] {
        weekDays.map { CalendarWeekLayout.timedLayout(for: $0, events: events, calendar: calendar) }
    }

    private var allDayByDay: [[CalendarEvent]] {
        weekDays.map { CalendarWeekLayout.allDayEvents(for: $0, events: events, calendar: calendar) }
    }

    private var hasAnyAllDay: Bool {
        allDayByDay.contains { !$0.isEmpty }
    }

    private var todayIndex: Int? {
        weekDays.firstIndex { calendar.isDate($0, inSameDayAs: now) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        hourGrid
                    } header: {
                        stickyHeader
                    }
                }
            }
            .background(Color.marginalia(.surface, in: scheme))
            .task {
                proxy.scrollTo(Self.initialScrollHour, anchor: .top)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
        }
    }

    // MARK: - Pinned header: day-of-week row + all-day row

    private var stickyHeader: some View {
        VStack(spacing: 0) {
            dayHeaderRow
            if hasAnyAllDay {
                allDayRow
            }
            Rectangle()
                .fill(Color.marginalia(.hairline, in: scheme))
                .frame(height: 1)
        }
        .background(Color.marginalia(.surface, in: scheme))
    }

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutterWidth)
            ForEach(Array(weekDays.enumerated()), id: \.offset) { index, day in
                dayHeaderCell(day: day, isToday: index == todayIndex)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) { columnDivider }
            }
        }
        .padding(.vertical, MarginaliaSpacing.sm.value)
    }

    private func dayHeaderCell(day: Date, isToday: Bool) -> some View {
        VStack(spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .marginaliaTextStyle(.caption, in: scheme)
            Text(day.formatted(.dateTime.day()))
                .marginaliaTextStyle(.subheadline, in: scheme, ink: isToday ? .canvas : .inkBody)
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(isToday ? Color.marginalia(.accent, in: scheme) : Color.clear)
                }
        }
    }

    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("All day")
                .marginaliaTextStyle(.caption, in: scheme)
                .frame(width: Self.gutterWidth, alignment: .trailing)
                .padding(.trailing, MarginaliaSpacing.xs.value)
            ForEach(Array(weekDays.enumerated()), id: \.offset) { index, _ in
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    ForEach(allDayByDay[index]) { event in
                        Button {
                            onSelectEvent(event)
                        } label: {
                            CalendarEventBlock(
                                event: event,
                                showsTimeRange: false,
                                tintHex: calendarColors[event.calendarId],
                                isLinked: event.meetingId != nil
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .overlay(alignment: .leading) { columnDivider }
            }
        }
        .padding(.vertical, MarginaliaSpacing.xs.value)
        .background(Color.marginalia(.elevated, in: scheme).opacity(0.5))
    }

    // MARK: - Scrolling hour grid

    private var hourGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            hourGutter
            ForEach(Array(weekDays.enumerated()), id: \.offset) { index, day in
                dayColumn(index: index, day: day)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) { columnDivider }
            }
        }
    }

    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< 24, id: \.self) { hour in
                hourLabel(hour)
                    .frame(width: Self.gutterWidth, height: Self.hourHeight, alignment: .topTrailing)
                    .id(hour)
            }
        }
    }

    @ViewBuilder
    private func hourLabel(_ hour: Int) -> some View {
        if hour == 0 {
            Color.clear
        } else {
            Text(hourLabelText(hour))
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                .offset(y: -6)
                .padding(.trailing, 4)
        }
    }

    private func hourLabelText(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return date.formatted(.dateTime.hour())
    }

    private func dayColumn(index: Int, day: Date) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                hourSeparators
                ForEach(timedByDay[index], id: \.event.id) { positioned in
                    let columnWidth = proxy.size.width / CGFloat(positioned.columnCount)
                    Button {
                        onSelectEvent(positioned.event)
                    } label: {
                        CalendarEventBlock(
                            event: positioned.event,
                            showsTimeRange: true,
                            tintHex: calendarColors[positioned.event.calendarId],
                            isLinked: positioned.event.meetingId != nil
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(columnWidth - 3, 8), height: blockHeight(positioned))
                    .position(
                        x: columnWidth * CGFloat(positioned.column) + columnWidth / 2,
                        y: blockTop(positioned) + blockHeight(positioned) / 2
                    )
                }
                if index == todayIndex {
                    nowLine
                }
            }
        }
        .frame(height: Self.hourHeight * 24)
    }

    private var hourSeparators: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< 24, id: \.self) { hour in
                Color.clear
                    .frame(height: Self.hourHeight)
                    .overlay(alignment: .top) {
                        if hour != 0 {
                            Rectangle()
                                .fill(Color.marginalia(.hairline, in: scheme).opacity(0.6))
                                .frame(height: 1)
                        }
                    }
            }
        }
    }

    private var nowLine: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.marginalia(.accent, in: scheme))
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.marginalia(.accent, in: scheme))
                .frame(height: 1)
        }
        .offset(y: CGFloat(nowMinutes) / 60 * Self.hourHeight - 3)
    }

    private var nowMinutes: Int {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        return min(24 * 60, max(0, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color.marginalia(.hairline, in: scheme))
            .frame(width: 1)
    }

    private func blockTop(_ positioned: CalendarWeekLayout.PositionedEvent) -> CGFloat {
        CGFloat(positioned.startMinutes) / 60 * Self.hourHeight
    }

    private func blockHeight(_ positioned: CalendarWeekLayout.PositionedEvent) -> CGFloat {
        max(CGFloat(positioned.endMinutes - positioned.startMinutes) / 60 * Self.hourHeight, 20)
    }
}
