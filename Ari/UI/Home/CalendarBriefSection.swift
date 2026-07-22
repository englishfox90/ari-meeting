//
//  CalendarBriefSection.swift — Home's "From your calendar" brief (the Swift port of the frozen
//  Rust `UpcomingMeetingsPanel`).
//
//  A short list of the meetings happening now or about to start, each with a one-tap "Record"
//  that hands off to the recording page pre-named after the event (same handoff the Calendar page
//  uses). Every row is a real, decoded `CalendarEvent` from `CalendarBriefViewModel` — the section
//  renders nothing at all when the brief is empty (No-Fake-State: no "nothing coming up" card, no
//  fabricated rows; an empty brief is simply absent, exactly like the Rust panel).
//
//  The Signal stays on Home's one Primary (the capture hero's "New meeting"): these Record buttons
//  are `.secondary` (the flat tonal + hairline "outline" analog the Rust panel used), so the brief
//  reads as a convenience shelf, not a second call to action competing for the amber.
//
import AriKit
import AriViewModels
import SwiftUI

struct CalendarBriefSection: View {
    let viewModel: CalendarBriefViewModel
    let scheme: ColorScheme
    /// `false` while the shared session is missing (pre-bootstrap) or already recording — the
    /// Record buttons stay honestly disabled rather than pretending a second start is possible.
    let canRecord: Bool
    let onRecord: (CalendarEvent) -> Void

    var body: some View {
        if !viewModel.events.isEmpty {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                Text("From your calendar")
                    .marginaliaTextStyle(.title2, in: scheme)
                card
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.events.enumerated()), id: \.element.id) { index, event in
                if index > 0 {
                    Rectangle()
                        .fill(Color.marginalia(.hairline, in: scheme))
                        .frame(height: 1)
                }
                row(event)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.surface, in: scheme))
                .overlay {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                }
        }
    }

    private func row(_ event: CalendarEvent) -> some View {
        HStack(alignment: .center, spacing: MarginaliaSpacing.md.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(event.title)
                    .marginaliaTextStyle(.headline, in: scheme)
                    .lineLimit(1)
                timing(event)
            }
            Spacer(minLength: MarginaliaSpacing.sm.value)
            Button {
                onRecord(event)
            } label: {
                Label("Record", systemImage: "mic")
            }
            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
            .disabled(!canRecord)
        }
        .padding(MarginaliaSpacing.md.value)
    }

    /// The sub-line: a live "Now" badge for an in-progress meeting, otherwise the start time; then
    /// the real attendee count when there is one. `Date()` here is the honest render-time clock —
    /// a display concern, distinct from the VM's injected filter clock.
    @ViewBuilder
    private func timing(_ event: CalendarEvent) -> some View {
        let inProgress = CalendarBriefViewModel.isInProgress(event, now: Date())
        HStack(spacing: MarginaliaSpacing.sm.value) {
            if inProgress {
                MarginaliaBadge("Now", style: .accent, scheme: scheme)
            } else {
                Text(event.startTime.formatted(date: .omitted, time: .shortened))
                    .marginaliaTextStyle(.timecode, in: scheme, ink: .inkSecondary)
            }
            if !event.attendees.isEmpty {
                Label("\(event.attendees.count)", systemImage: "person.2")
                    .labelStyle(.titleAndIcon)
                    .marginaliaTextStyle(.timecode, in: scheme, ink: .inkSecondary)
            }
        }
    }
}
