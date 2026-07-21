//
//  RootSplitView.swift — the 2-column NavigationSplitView host (home + left-rail rework of the
//  original 3-column read shell).
//
//  Before `AppEnvironment.status == .ready`, renders `LaunchStatusView` (honest
//  launching/importing/failed) instead of the real shell — never a fake-ready shell over a
//  database that isn't open yet.
//
//  Navigation model: the left rail's WORKBENCH selection (`selectedSection`) picks the detail
//  `NavigationStack`'s ROOT content; a shared `NavigationPath` (`path`) drives pushes on top of
//  that root (meeting/person/series detail). Changing `selectedSection` resets `path` to empty
//  — switching workbench sections always lands on that section's root, never mid-stack in a
//  previous section's push history.
//
import AriKit
import SwiftUI

struct RootSplitView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme

    @State private var selectedSection: SidebarSection = .home
    @State private var path = NavigationPath()

    var body: some View {
        Group {
            if let database = environment.database, environment.status == .ready {
                readyShell(database: database)
            } else {
                LaunchStatusView(status: environment.status)
            }
        }
        .tint(Color.marginalia(.accent, in: scheme))
        .task { await environment.bootstrap() }
    }

    private func readyShell(database: AppDatabase) -> some View {
        NavigationSplitView {
            SidebarView(
                selection: $selectedSection,
                database: database,
                onSelectMeeting: { path.append($0) }
            )
            .navigationSplitViewColumnWidth(min: 236, ideal: 252, max: 300)
        } detail: {
            NavigationStack(path: $path) {
                rootContent(database: database)
                    .navigationDestination(for: MeetingID.self) { meetingId in
                        MeetingDetailView(database: database, meetingId: meetingId)
                    }
                    .navigationDestination(for: PersonID.self) { personId in
                        PersonDetailView(database: database, personId: personId)
                    }
                    .navigationDestination(for: SeriesID.self) { seriesId in
                        SeriesDetailView(database: database, seriesId: seriesId)
                    }
            }
        }
        .onChange(of: selectedSection) { _, _ in
            path = NavigationPath()
        }
    }

    @ViewBuilder
    private func rootContent(database: AppDatabase) -> some View {
        switch selectedSection {
        case .home:
            HomeView(database: database, selection: $selectedSection)
        case .savedMeetings:
            MeetingsListView(database: database)
        case .series:
            SeriesListView(database: database)
        case .people:
            PeopleListView(database: database)
        case .newMeeting:
            placeholder("Recording isn't built yet.")
        case .ask:
            placeholder("Ask meetings isn't ready yet.")
        case .calendar:
            placeholder("Calendar isn't connected yet.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: MarginaliaSpacing.md.value) {
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 72)
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
            Text(text)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.marginalia(.canvas, in: scheme))
    }
}
