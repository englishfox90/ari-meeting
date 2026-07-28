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
    @State private var showingAllAttendees = false

    /// How many attendees show before the list collapses behind a disclosure. Large invites
    /// (all-hands, room resources) would otherwise grow the card without limit and starve the
    /// rail's transcript list of height — the card sits above it in a plain `VStack`.
    private static let attendeePreviewLimit = 5
    /// Ceiling on the expanded list, so "show all" scrolls inside the card instead of pushing
    /// the transcript off-screen.
    private static let attendeeListMaxHeight: CGFloat = 260

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
                attendeeSection(event.attendees)
            }
            Button("Unlink") {
                Task { await viewModel.unlink() }
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
            .disabled(viewModel.isBusy)
        }
    }

    /// The attendee list, bounded in both states: collapsed to the first
    /// `attendeePreviewLimit` rows, or expanded into a height-capped scroll area. The count in the
    /// header is the real attendee count — no truncation happens silently.
    @ViewBuilder
    private func attendeeSection(_ attendees: [Attendee]) -> some View {
        let isOverflowing = attendees.count > Self.attendeePreviewLimit
        let visible = isOverflowing && !showingAllAttendees
            ? Array(attendees.prefix(Self.attendeePreviewLimit))
            : attendees

        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text("Attendees (\(attendees.count))")
                .marginaliaTextStyle(.caption, in: scheme)
            if showingAllAttendees {
                ScrollView {
                    attendeeRows(visible)
                }
                .frame(maxHeight: Self.attendeeListMaxHeight)
            } else {
                attendeeRows(visible)
            }
            if isOverflowing {
                Button(showingAllAttendees ? "Show fewer" : "Show all \(attendees.count)") {
                    showingAllAttendees.toggle()
                }
                .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
            }
        }
    }

    private func attendeeRows(_ attendees: [Attendee]) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            ForEach(Array(attendees.enumerated()), id: \.offset) { _, attendee in
                AttendeeRow(
                    attendee: attendee,
                    resolvedName: attendee.email.flatMap { viewModel.resolvedAttendeeNames[$0.lowercased()] }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
