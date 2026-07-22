//
//  LinkMeetingSheet.swift — the meeting picker for manual calendar-event linking
//  (docs/plans/arikit-calendar-ui.md §2/§3, Slice 2).
//
//  Pushed onto `EventDetailSheet`'s own `NavigationStack` (no modal-on-modal). Meetings load via
//  `meetingsForPicker()` (already newest-first, `MeetingRepository.all()`'s own ordering) and are
//  filtered locally by title as the user types — no additional query.
//
import AriKit
import SwiftUI

struct LinkMeetingSheet: View {
    let loadMeetings: () async -> [Meeting]
    let onSelect: (Meeting) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var meetings: [Meeting] = []
    @State private var query = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            MarginaliaTextField(text: $query, prompt: "Search meetings", scheme: scheme)
                .padding(MarginaliaSpacing.md.value)
            Rectangle()
                .fill(Color.marginalia(.hairline, in: scheme))
                .frame(height: 1)
            resultsList
        }
        .background(MarginaliaCanvasWash(scheme: scheme))
        .navigationTitle("Link Meeting")
        .task {
            meetings = await loadMeetings()
            isLoading = false
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredMeetings.isEmpty {
            Text(emptyText)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredMeetings) { meeting in
                        Button {
                            onSelect(meeting)
                        } label: {
                            CardRow(
                                title: meeting.title,
                                metadata: meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                        .buttonStyle(.plain)
                        if meeting.id != filteredMeetings.last?.id {
                            Divider().overlay(Color.marginalia(.hairline, in: scheme))
                        }
                    }
                }
            }
        }
    }

    private var emptyText: String {
        meetings.isEmpty ? "No meetings yet." : "No meetings match \"\(query)\"."
    }

    private var filteredMeetings: [Meeting] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return meetings }
        return meetings.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }
}
