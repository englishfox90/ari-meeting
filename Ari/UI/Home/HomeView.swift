//
//  HomeView.swift — the Home screen (home + left-rail rework).
//
//  The "Start a meeting" capture card and the "Recent meetings" rows push/select honestly:
//  capture isn't built yet, so its button routes to the `.newMeeting` placeholder rather than
//  pretending to record (No-Fake-State); recent-meeting rows push the real `MeetingDetailView`
//  via the shared detail `NavigationStack`.
//
import AriKit
import AriViewModels
import SwiftUI

struct HomeView: View {
    let database: AppDatabase
    @Binding var selection: SidebarSection

    @State private var viewModel: HomeViewModel
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, selection: Binding<SidebarSection>) {
        self.database = database
        _selection = selection
        _viewModel = State(initialValue: HomeViewModel(database: database))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xl.value) {
                hero
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                cards
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                recentSection
            }
            .padding(MarginaliaSpacing.xl.value)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.marginalia(.canvas, in: scheme))
        .navigationTitle("Home")
        .task { await viewModel.observe() }
    }

    /// Names the work rather than selling it (finding #7) — the largest type on the page is the
    /// page identity, not a marketing tagline. Library counts below are real data from
    /// `viewModel` (No-Fake-State), not invented.
    private var hero: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text("THIS DEVICE / MEETING WORKBENCH")
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            Text("Home")
                .marginaliaTextStyle(.display, in: scheme)
            Text(libraryCountSummary)
                .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
        }
    }

    private var cards: some View {
        captureCard
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            Image(systemName: "mic")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
            Text("CAPTURE")
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            Text("Start a meeting")
                .marginaliaTextStyle(.title2, in: scheme)
            Text("Record system and microphone audio without adding a bot to the call.")
                .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            Button("New meeting") {
                selection = .newMeeting
            }
            .buttonStyle(.marginalia(.secondary, .large, in: scheme))
        }
        .padding(MarginaliaSpacing.lg.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
                .overlay {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                }
        }
    }

    private var libraryCountSummary: String {
        "\(viewModel.meetingCount) meetings · \(viewModel.personCount) people"
    }

    @ViewBuilder
    private var recentSection: some View {
        HStack {
            SectionHeader(title: "Recent meetings")
            Spacer()
            Button("View all") {
                selection = .savedMeetings
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
        }
        switch viewModel.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(MarginaliaSpacing.lg.value)
        case let .loaded(meetings):
            VStack(spacing: 0) {
                ForEach(meetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        HStack(spacing: MarginaliaSpacing.sm.value) {
                            Image(systemName: "mic")
                                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                            CardRow(
                                title: meeting.title,
                                metadata: meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        case .empty:
            Text("No meetings yet")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                .padding(.horizontal, MarginaliaSpacing.md.value)
        case let .failed(message):
            Text(message)
                .marginaliaTextStyle(.callout, in: scheme, ink: .error)
                .padding(.horizontal, MarginaliaSpacing.md.value)
        }
    }
}
