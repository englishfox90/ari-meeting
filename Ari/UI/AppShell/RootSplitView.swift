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
import AriViewModels
import SwiftUI

struct RootSplitView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme

    @State private var selectedSection: SidebarSection = .home
    @State private var path = NavigationPath()
    /// Drives the "import a recording" sheet (docs/plans/audio-import.md).
    @State private var showImportSheet = false

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
                onSelectMeeting: { path.append($0) },
                onSelectPerson: { path.append($0) },
                onSelectSeries: { path.append($0) },
                onImportAudio: { showImportSheet = true }
            )
            .navigationSplitViewColumnWidth(min: 236, ideal: 252, max: 300)
        } detail: {
            NavigationStack(path: $path) {
                rootContent(database: database)
                    .navigationDestination(for: MeetingID.self) { meetingId in
                        MeetingDetailView(database: database, meetingId: meetingId)
                    }
                    // The persistent live-capture pill (plan §4.4): visible from every section
                    // and pushed detail screen while recording — EXCEPT the recording page,
                    // which already carries the Signal (one red glass element per screen).
                    .safeAreaInset(edge: .bottom, alignment: .leading) {
                        if let session = environment.recordingSession,
                           session.isActive, selectedSection != .newMeeting {
                            RecordingIndicator(session: session) {
                                selectedSection = .newMeeting
                            }
                            .padding(.horizontal, MarginaliaSpacing.md.value)
                            .padding(.bottom, MarginaliaSpacing.sm.value)
                        }
                    }
                    .navigationDestination(for: MeetingMoment.self) { moment in
                        MeetingDetailView(
                            database: database,
                            meetingId: moment.meetingId,
                            initialSeek: moment.seconds
                        )
                    }
                    .navigationDestination(for: PersonID.self) { personId in
                        PersonDetailView(database: database, personId: personId)
                    }
                    .navigationDestination(for: SeriesID.self) { seriesId in
                        if let ledgerReducer = environment.seriesLedgerReducer {
                            SeriesDetailView(
                                database: database,
                                seriesId: seriesId,
                                ledgerReducer: ledgerReducer,
                                onOpenMeetingMoment: { path.append(MeetingMoment(meetingId: $0, seconds: $1)) }
                            )
                        }
                    }
            }
        }
        .onChange(of: selectedSection) { _, _ in
            path = NavigationPath()
        }
        // Mount-independent pipeline kickoff (docs/plans/swift-meeting-generation-flow.md,
        // Track 2): fires exactly once per `.saved(meetingId)` transition, regardless of which
        // section/screen is on screen when a recording finishes — `RecordingView`'s own status
        // line (when it happens to be visible) reads the SAME coordinator, never triggers it.
        .onChange(of: environment.recordingSession?.phase) { _, newPhase in
            guard case let .saved(meetingId) = newPhase else { return }
            Task { await environment.processingCoordinator?.begin(meetingId: meetingId) }
        }
        // The import equivalent (docs/plans/audio-import.md): when an import saves, dismiss the
        // sheet, kick the SAME post-recording pipeline, open the new meeting, and reset the session
        // so the sheet reopens clean. Mirrors the recording `.saved` handler above.
        .onChange(of: environment.importSession?.phase) { _, newPhase in
            guard case let .saved(meetingId) = newPhase else { return }
            showImportSheet = false
            Task { await environment.processingCoordinator?.begin(meetingId: meetingId) }
            path.append(meetingId)
            environment.importSession?.reset()
        }
        // Navigation raised from outside the view tree (a tapped notification): a meeting-reminder
        // start routes to the recording section (the session is already primed + capturing); a
        // summary-ready tap pushes that meeting's detail. Cleared immediately so it fires once.
        .onChange(of: environment.pendingNavigation) { _, nav in
            guard let nav else { return }
            switch nav {
            case let .section(section):
                selectedSection = section
            case let .meeting(meetingId):
                path.append(meetingId)
            }
            environment.consumePendingNavigation()
        }
        // The app-level speaker-count prompt (plan "UI integration" #1): presented whenever the
        // pipeline pauses at `.needsSpeakerCount`, from anywhere in the app. Dismissing the stock
        // sheet without an explicit choice (swipe-down, Esc) routes through
        // `skipSpeakerIdentification()`, same as tapping "Skip" — idempotent either way (the
        // coordinator's guard only proceeds from `.needsSpeakerCount`).
        .sheet(isPresented: speakerCountPromptPresented) {
            SpeakerCountPromptSheet(
                onSubmit: { hint in
                    Task { await environment.processingCoordinator?.provideSpeakerCount(hint) }
                },
                onSkip: {
                    Task { await environment.processingCoordinator?.skipSpeakerIdentification() }
                }
            )
        }
        // The import sheet (docs/plans/audio-import.md), raised from the sidebar's "Import audio"
        // action. The session is always present once the shell is `.ready`; the `.saved` handler
        // above owns dismissal + navigation.
        .sheet(isPresented: $showImportSheet) {
            if let importSession = environment.importSession {
                ImportMeetingSheet(
                    session: importSession,
                    onCancel: { showImportSheet = false }
                )
            }
        }
    }

    /// `true` only while the coordinator is paused for a speaker-count input. Dismissing without
    /// an explicit "Identify"/"Skip" choice sets this to `false`, which routes to
    /// `skipSpeakerIdentification()` — a no-op if the coordinator already moved on (mirrors
    /// `RecordingView.consentSheetPresented`'s dismiss-idempotency discipline).
    private var speakerCountPromptPresented: Binding<Bool> {
        Binding(
            get: { environment.processingCoordinator?.phase == .needsSpeakerCount },
            set: { isPresented in
                if !isPresented {
                    Task { await environment.processingCoordinator?.skipSpeakerIdentification() }
                }
            }
        )
    }

    @ViewBuilder
    private func rootContent(database: AppDatabase) -> some View {
        switch selectedSection {
        case .home:
            HomeView(
                database: database,
                calendarSource: environment.calendarSource,
                recordingSession: environment.recordingSession,
                selection: $selectedSection
            )
        case .savedMeetings:
            MeetingsListView(database: database)
        case .series:
            SeriesListView(database: database, onCreated: { path.append($0) })
        case .people:
            PeopleListView(database: database)
        case .newMeeting:
            if let session = environment.recordingSession {
                RecordingView(session: session, onOpenMeeting: { path.append($0) })
            } else {
                placeholder("Recording isn't built yet.")
            }
        case .ask:
            placeholder("Ask meetings isn't ready yet.")
        case .calendar:
            CalendarPageView(
                database: database,
                calendarSource: environment.calendarSource,
                recordingSession: environment.recordingSession,
                selection: $selectedSection,
                onOpenMeeting: { path.append($0) }
            )
        case .settings:
            SettingsView(
                database: database,
                calendarSource: environment.calendarSource,
                notifications: environment.meetingNotifications
            )
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
        .background(MarginaliaCanvasWash(scheme: scheme))
    }
}
