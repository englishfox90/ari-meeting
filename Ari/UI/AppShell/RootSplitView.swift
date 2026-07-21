//
//  RootSplitView.swift — the 3-column NavigationSplitView host (plan §6 Navigation model).
//
//  Replaces the S0 `ContentView` as the `WindowGroup` root. Before `AppEnvironment.status ==
//  .ready`, renders `LaunchStatusView` (honest launching/importing/failed) instead of the
//  real shell — never a fake-ready 3-column view over a database that isn't open yet.
//
import AriKit
import SwiftUI

struct RootSplitView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme

    @State private var selectedSection: SidebarSection? = .meetings
    @State private var selectedMeetingId: MeetingID?
    @State private var selectedPersonId: PersonID?
    @State private var selectedSeriesId: SeriesID?

    var body: some View {
        Group {
            if let database = environment.database, environment.status == .ready {
                readyShell(database: database)
            } else {
                LaunchStatusView(status: environment.status)
            }
        }
        .task { await environment.bootstrap() }
    }

    private func readyShell(database: AppDatabase) -> some View {
        NavigationSplitView {
            SidebarView(selection: $selectedSection)
        } content: {
            contentColumn(database: database)
        } detail: {
            detailColumn(database: database)
        }
    }

    @ViewBuilder
    private func contentColumn(database: AppDatabase) -> some View {
        switch selectedSection ?? .meetings {
        case .meetings:
            MeetingsListView(database: database, selection: $selectedMeetingId)
        case .people:
            PeopleListView(database: database, selection: $selectedPersonId)
        case .series:
            SeriesListView(database: database, selection: $selectedSeriesId)
        case .ask:
            // Reserved slot — no Ask screen ships in S6 (plan §6). Unreachable via the
            // sidebar today (`SidebarSection.built` excludes `.ask`), but kept honest rather
            // than falling through to an unrelated screen if the enum is ever driven directly.
            askReservedPlaceholder
        }
    }

    @ViewBuilder
    private func detailColumn(database: AppDatabase) -> some View {
        switch selectedSection ?? .meetings {
        case .meetings:
            if let selectedMeetingId {
                MeetingDetailView(database: database, meetingId: selectedMeetingId)
            } else {
                placeholder("Select a meeting")
            }
        case .people:
            if let selectedPersonId {
                PersonDetailView(database: database, personId: selectedPersonId)
            } else {
                placeholder("Select a person")
            }
        case .series:
            if let selectedSeriesId {
                SeriesDetailView(database: database, seriesId: selectedSeriesId)
            } else {
                placeholder("Select a series")
            }
        case .ask:
            askReservedPlaceholder
        }
    }

    private var askReservedPlaceholder: some View {
        placeholder("Ask is not built yet")
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: MarginaliaSpacing.md.value) {
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 72)
                .foregroundStyle(Color.marginalia(.hairline, in: scheme))
            Text(text)
                .marginaliaTextStyle(.callout, in: scheme)
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.marginalia(.canvas, in: scheme))
    }
}
