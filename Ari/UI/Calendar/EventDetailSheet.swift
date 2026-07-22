//
//  EventDetailSheet.swift — event detail + actions (docs/plans/arikit-calendar-ui.md §2/§3,
//  Slice 2 + Slice 3's Start action).
//
//  Every field is real, decoded data — title, time range, location, notes, organizer, the real
//  `[Attendee]` array — nothing fabricated. The linked-meeting row renders ONLY from a persisted
//  `event.meetingId` (never from an in-flight intent): "Linked" is a fact about the store, not a
//  UI optimism. "Link meeting" pushes `LinkMeetingSheet` on this sheet's own `NavigationStack`
//  rather than presenting a nested modal (no modal-on-modal, mirrors `IdentifySpeakersSheet`'s
//  push-based "Assign person" destination).
//
import AriKit
import AriViewModels
import SwiftUI

struct EventDetailSheet: View {
    let event: CalendarEvent
    /// The linked meeting's title, from `CalendarPageViewModel.linkedMeetingTitles` — `nil` when
    /// `event.meetingId` is `nil`, OR when the title hasn't resolved yet (falls back to a plain
    /// "Meeting" label rather than blocking the row on a lookup).
    let linkedMeetingTitle: String?
    /// `nil` until `AppEnvironment.bootstrap()` constructs the real session — Start stays
    /// honestly disabled until then, same posture as the rest of the app's optional-source VMs.
    let recordingSession: RecordingSession?
    let onLink: (MeetingID) async -> Void
    let onUnlink: () async -> Void
    let onOpenMeeting: (MeetingID) -> Void
    let onStartMeeting: () -> Void
    let meetingsForPicker: () async -> [Meeting]
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var showLinkPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
                    header
                    detailRows
                    attendeesSection
                    linkedMeetingSection
                    actions
                }
                .padding(MarginaliaSpacing.lg.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(MarginaliaCanvasWash(scheme: scheme))
            .navigationTitle(event.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
            }
            .navigationDestination(isPresented: $showLinkPicker) {
                LinkMeetingSheet(
                    loadMeetings: meetingsForPicker,
                    onSelect: { meeting in
                        Task {
                            await onLink(meeting.id)
                            showLinkPicker = false
                        }
                    }
                )
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(event.title)
                .marginaliaTextStyle(.title2, in: scheme)
            Text(timeRangeText)
                .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
        }
    }

    private var timeRangeText: String {
        if event.isAllDay {
            return "All day"
        }
        let sameDay = Calendar.current.isDate(event.startTime, inSameDayAs: event.endTime)
        let start = event.startTime.formatted(date: .abbreviated, time: .shortened)
        let end = sameDay
            ? event.endTime.formatted(date: .omitted, time: .shortened)
            : event.endTime.formatted(date: .abbreviated, time: .shortened)
        return "\(start) – \(end)"
    }

    // MARK: - Location / organizer / notes

    @ViewBuilder
    private var detailRows: some View {
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let organizer = event.organizer?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        if [location, organizer, notes].contains(where: { !($0 ?? "").isEmpty }) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                if let location, !location.isEmpty {
                    detailRow(icon: "mappin.and.ellipse", text: location)
                }
                if let organizer, !organizer.isEmpty {
                    detailRow(icon: "person", text: organizer)
                }
                if let notes, !notes.isEmpty {
                    // Google/Loom/Meet embed raw HTML in descriptions — parse it into styled
                    // text (bold/links/entities) instead of showing markup verbatim.
                    detailRow(icon: "note.text", attributed: RichNotes.attributed(from: notes))
                }
            }
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        detailRow(icon: icon, attributed: AttributedString(text))
    }

    private func detailRow(icon: String, attributed: AttributedString) -> some View {
        HStack(alignment: .top, spacing: MarginaliaSpacing.sm.value) {
            Image(systemName: icon)
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                .frame(width: 18)
            Text(attributed)
                .marginaliaTextStyle(.body, in: scheme)
                .tint(Color.marginalia(.accent, in: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: - Attendees (the real decoded array — CalendarEventRepository never surfaces less)

    @ViewBuilder
    private var attendeesSection: some View {
        if !event.attendees.isEmpty {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                SectionHeader(title: "ATTENDEES (\(event.attendees.count))")
                VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                    ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, attendee in
                        attendeeRow(attendee)
                    }
                }
            }
        }
    }

    private func attendeeRow(_ attendee: Attendee) -> some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Circle()
                .fill(Color.marginalia(.elevated, in: scheme))
                .frame(width: 22, height: 22)
                .overlay {
                    Text(initial(for: attendee))
                        .marginaliaTextStyle(.caption, in: scheme)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(attendee.name ?? attendee.email ?? "Unknown attendee")
                    .marginaliaTextStyle(.body, in: scheme)
                if attendee.name != nil, let email = attendee.email {
                    Text(email)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
        }
    }

    private func initial(for attendee: Attendee) -> String {
        let source = attendee.name ?? attendee.email ?? "?"
        return String(source.prefix(1)).uppercased()
    }

    // MARK: - Linked meeting (renders ONLY from real `event.meetingId`)

    @ViewBuilder
    private var linkedMeetingSection: some View {
        if let meetingId = event.meetingId {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                SectionHeader(title: "LINKED MEETING")
                HStack {
                    Text(linkedMeetingTitle ?? "Meeting")
                        .marginaliaTextStyle(.body, in: scheme)
                    Spacer()
                    Button("Open") { onOpenMeeting(meetingId) }
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            linkUnlinkButton
            startMeetingSection
        }
    }

    private var linkUnlinkButton: some View {
        Group {
            if event.meetingId != nil {
                Button("Unlink meeting") {
                    Task { await onUnlink() }
                }
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
            } else {
                Button("Link meeting…") {
                    showLinkPicker = true
                }
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
            }
        }
    }

    private var startMeetingSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Button("Start meeting") {
                onStartMeeting()
                onDismiss()
            }
            .buttonStyle(.marginalia(.primary, .large, in: scheme))
            .disabled(!canStartMeeting)
            if let reason = startDisabledReason {
                Text(reason)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            }
        }
    }

    private var canStartMeeting: Bool {
        guard let recordingSession else { return false }
        return !recordingSession.isActive
    }

    private var startDisabledReason: String? {
        guard let recordingSession else {
            return "Recording isn't available."
        }
        if recordingSession.isActive {
            return "A recording is already in progress."
        }
        return nil
    }
}
