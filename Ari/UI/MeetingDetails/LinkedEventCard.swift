//
//  LinkedEventCard.swift — the meeting-detail right rail's linked-calendar-event surface
//  (docs/plans/calendar-series-intelligence.md §2.5, Feature 3).
//
//  Renders ONLY from `LinkedCalendarEventViewModel.event` — real, persisted data
//  (`CalendarEventRepository.linkedEvent(forMeeting:)`). When there is no linked event, the card
//  still appears, but only as an honest "Link calendar event…" affordance — never a placeholder
//  pretending a link exists (No-Fake-State). Sits near `SourceRecordPanel` in the right rail,
//  matching its plain-caption-header + padded-rows shape.
//
import AriKit
import AriViewModels
import SwiftUI

struct LinkedEventCard: View {
    let viewModel: LinkedCalendarEventViewModel
    let meeting: Meeting

    @Environment(\.colorScheme) private var scheme
    @State private var showingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text("Calendar event")
                .marginaliaTextStyle(.caption, in: scheme)
            if let event = viewModel.event {
                linkedContent(event)
            } else {
                unlinkedContent
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .error)
            }
        }
        .padding(MarginaliaSpacing.md.value)
        .sheet(isPresented: $showingPicker) {
            LinkCalendarEventSheet(
                loadCandidates: {
                    await viewModel.loadCandidates(around: meeting.createdAt)
                    return viewModel.candidateEvents
                },
                onSelect: { candidate in
                    Task {
                        await viewModel.link(eventId: candidate.id, meetingId: meeting.id)
                        showingPicker = false
                    }
                },
                onDismiss: { showingPicker = false }
            )
        }
    }

    @ViewBuilder
    private func linkedContent(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(event.title)
                    .marginaliaTextStyle(.body, in: scheme)
                Text(CalendarEventFormatting.timeRangeText(for: event))
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                if let calendarTitle = event.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !calendarTitle.isEmpty {
                    Text(calendarTitle)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
            if !event.attendees.isEmpty {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, attendee in
                        AttendeeRow(attendee: attendee)
                    }
                }
            }
            Button("Unlink") {
                Task { await viewModel.unlink() }
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
            .disabled(viewModel.isBusy)
        }
    }

    private var unlinkedContent: some View {
        Button {
            showingPicker = true
        } label: {
            Label("Link calendar event…", systemImage: "calendar.badge.plus")
        }
        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
        .disabled(viewModel.isBusy)
    }
}
