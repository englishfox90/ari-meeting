//
//  LinkCalendarEventSheet.swift — the linked-event card's picker
//  (docs/plans/calendar-series-intelligence.md §2.5, Feature 3).
//
//  Reuses `LinkMeetingSheet`'s structure, inverted: this sheet picks a CALENDAR EVENT for the
//  current meeting rather than a meeting for a calendar event. Candidates already linked to
//  another meeting show an honest "linked elsewhere" caption — selecting one visibly MOVES the
//  link here (`CalendarEventRepository.setManualLink`'s strict-1:1 steal semantics,
//  calendar-series-intelligence plan §2.1) rather than creating a second link. Presented as its
//  own `.sheet` (not pushed onto a host stack, unlike `LinkMeetingSheet`), so it owns its own
//  `NavigationStack` + Close action, mirroring `IdentifySpeakersSheet`.
//
import AriKit
import SwiftUI

struct LinkCalendarEventSheet: View {
    let loadCandidates: () async -> [CalendarEvent]
    let onSelect: (CalendarEvent) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var candidates: [CalendarEvent] = []
    @State private var query = ""
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MarginaliaSearchField(text: $query, prompt: "Search events", scheme: scheme, size: .compact)
                    .padding(MarginaliaSpacing.md.value)
                Rectangle()
                    .fill(Color.marginalia(.hairline, in: scheme))
                    .frame(height: 1)
                resultsList
            }
            .background(MarginaliaCanvasWash(scheme: scheme))
            .navigationTitle("Link Calendar Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
            }
            .task {
                candidates = await loadCandidates()
                isLoading = false
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    @ViewBuilder
    private var resultsList: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredCandidates.isEmpty {
            Text(emptyText)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredCandidates) { candidate in
                        candidateRow(candidate)
                        if candidate.id != filteredCandidates.last?.id {
                            Divider().overlay(Color.marginalia(.hairline, in: scheme))
                        }
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: CalendarEvent) -> some View {
        Button {
            onSelect(candidate)
        } label: {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(candidate.title)
                    .marginaliaTextStyle(.body, in: scheme)
                    .lineLimit(1)
                Text(CalendarEventFormatting.timeRangeText(for: candidate))
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                if candidate.meetingId != nil {
                    // Honest, load-bearing copy (plan §2.5): linking this row will MOVE its
                    // existing link, never create a second one.
                    Text("Linked elsewhere — selecting this will move the link here.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
            .padding(.vertical, MarginaliaSpacing.sm.value)
            .padding(.horizontal, MarginaliaSpacing.md.value)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyText: String {
        candidates.isEmpty ? "No calendar events near this meeting." : "No events match \"\(query)\"."
    }

    private var filteredCandidates: [CalendarEvent] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }
}
