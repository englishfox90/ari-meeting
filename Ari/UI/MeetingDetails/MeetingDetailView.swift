//
//  MeetingDetailView.swift — Transcript / Summary / Notes sections + audio playback
//  (plan §2.2 MeetingDetails).
//
import AriKit
import AriViewModels
import SwiftUI

private enum DetailSection: String, CaseIterable, Identifiable {
    case transcript
    case summary
    case notes

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .notes: "Notes"
        }
    }
}

struct MeetingDetailView: View {
    let database: AppDatabase
    let meetingId: MeetingID

    @State private var viewModel: MeetingDetailViewModel
    @State private var audioController = AudioPlayerController()
    @State private var selectedSection: DetailSection = .transcript
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, meetingId: MeetingID) {
        self.database = database
        self.meetingId = meetingId
        _viewModel = State(initialValue: MeetingDetailViewModel(database: database))
    }

    var body: some View {
        StateContainer(
            state: viewModel.meeting,
            emptyTitle: "No meeting",
            emptyMessage: nil
        ) { meeting in
            VStack(spacing: 0) {
                header(for: meeting)
                sectionSwitcher
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                sectionContent
                audioBar
            }
        }
        .background(Color.marginalia(.canvas, in: scheme))
        .navigationTitle(viewModel.meeting.value?.title ?? "Meeting")
        .task(id: meetingId) {
            // Reset first: the detail view is REUSED across meetings in the split detail column
            // (no per-meeting `.id`), so a previous meeting's player must be stopped before the
            // new one loads — otherwise selecting a meeting with missing/absent audio would leave
            // the prior meeting audible with no visible transport to stop it.
            audioController.reset()
            await viewModel.load(meetingId)
            if case let .available(url) = viewModel.audio {
                audioController.load(url: url)
            }
        }
        .onDisappear { audioController.reset() }
    }

    private func header(for meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(meeting.title)
                .marginaliaTextStyle(.title1, in: scheme)
            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                .marginaliaTextStyle(.callout, in: scheme)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MarginaliaSpacing.md.value)
    }

    private var sectionSwitcher: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            ForEach(DetailSection.allCases) { section in
                Button(section.title) {
                    selectedSection = section
                }
                .buttonStyle(.marginalia(section == selectedSection ? .secondary : .quiet, .regular, in: scheme))
            }
            Spacer()
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.bottom, MarginaliaSpacing.sm.value)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .transcript:
            TranscriptListView(
                transcript: viewModel.transcript,
                displayName: viewModel.displayName(for:),
                onSeek: { audioController.seek(toSeconds: $0) }
            )
        case .summary:
            SummaryView(summary: viewModel.summary)
        case .notes:
            NotesReadView(notes: viewModel.notes)
        }
    }

    @ViewBuilder
    private var audioBar: some View {
        // A `nil` audioReference means "the bar is absent" (plan §5) — the missing-file
        // reason text is reserved for a REAL reference that just didn't resolve to a file.
        if viewModel.meeting.value?.audioReference == nil {
            EmptyView()
        } else {
            switch viewModel.audio {
            case .available:
                AudioPlayerBar(controller: audioController)
            case let .missing(reason):
                Text(reason)
                    .marginaliaTextStyle(.caption, in: scheme)
                    .padding(MarginaliaSpacing.sm.value)
            case .unresolved:
                EmptyView()
            }
        }
    }
}
