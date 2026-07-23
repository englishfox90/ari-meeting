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
    @Environment(\.openWindow) private var openWindow

    @State private var selectedSection: SidebarSection = .home
    @State private var path = NavigationPath()
    /// Drives the "import a recording" sheet (docs/plans/audio-import.md).
    @State private var showImportSheet = false
    /// Tracks "the meeting/series currently in view" alongside `path` (docs/plans/ari-ask-ui.md
    /// §7) — `NavigationPath` has no public way to peek at its own top element's concrete type,
    /// so we keep a parallel STACK of nav keys: every `path.append` site pushes one entry, and
    /// `.onChange(of: path.count)` truncates it whenever the path pops (system back button,
    /// swipe). The top of the stack is therefore always the node actually on screen — so the Ask
    /// FAB never stays scoped to a meeting the user has navigated away from. Reset with `path`.
    @State private var askNavStack: [AskNavKey] = []
    private var askNavKey: AskNavKey {
        askNavStack.last ?? .none
    }

    /// Drives the first-run install/education flow (docs/plans/onboarding-install-flow.md §6) —
    /// an additive covering layer over the ready shell, checked once per launch after `.ready`.
    /// Starts `false` (never shown) until the honest read below flips it — never presented
    /// optimistically before the real flag is known.
    @State private var showOnboarding = false

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
        // Capture the scene-backed `OpenWindowAction` (docs/plans/notch-panel-absorption.md §11
        // R4) — `AppEnvironment.activateApp()` uses it to reopen the main window when every
        // window has been closed (a plain `NSHostingView`, like the notch panel, has none of its
        // own).
        .onAppear { environment.registerOpenWindowAction(openWindow) }
    }

    private func readyShell(database: AppDatabase) -> some View {
        NavigationSplitView {
            SidebarView(
                selection: $selectedSection,
                database: database,
                onSelectMeeting: { path.append($0); askNavStack.append(.meeting($0)) },
                onSelectPerson: { path.append($0); askNavStack.append(.none) },
                onSelectSeries: { path.append($0); askNavStack.append(.series($0)) },
                onImportAudio: { showImportSheet = true }
            )
            .navigationSplitViewColumnWidth(min: 236, ideal: 252, max: 300)
        } detail: {
            NavigationStack(path: $path) {
                rootContent(database: database)
                    .navigationDestination(for: MeetingID.self) { meetingId in
                        MeetingDetailView(
                            database: database,
                            meetingId: meetingId,
                            recallIndexTrigger: environment.recallIndexTrigger
                        )
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
                            initialSeek: moment.seconds,
                            recallIndexTrigger: environment.recallIndexTrigger
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
                                onOpenMeetingMoment: { meetingId, seconds in
                                    path.append(MeetingMoment(meetingId: meetingId, seconds: seconds))
                                    askNavStack.append(.meeting(meetingId))
                                }
                            )
                        }
                    }
            }
        }
        // The app-wide "Ask" FAB is overlaid on the WHOLE split view, not inside the detail
        // column: on macOS a NavigationStack hosts pushed destinations (meeting/series detail) in a
        // layer that escapes SwiftUI overlays/ZStacks placed inside the detail closure, so the FAB
        // vanished there. At the split-view level it stays top-most in every navigation state, and
        // bottom-trailing is the detail area, so it still never covers the sidebar rail.
        .overlay(alignment: .bottomTrailing) {
            AskOverlayHost(
                database: database,
                recallEngine: environment.recallEngine,
                selectedSection: selectedSection,
                navKey: askNavKey,
                isRecordingActive: environment.recordingSession?.isActive ?? false,
                onOpenMeeting: { path.append($0); askNavStack.append(.meeting($0)) },
                onOpenPerson: { path.append($0); askNavStack.append(.none) },
                onOpenSeries: { path.append($0); askNavStack.append(.series($0)) },
                onOpenSettings: { selectedSection = .settings }
            )
        }
        .onChange(of: selectedSection) { _, _ in
            path = NavigationPath()
            askNavStack = []
        }
        // Keep the nav-key stack in lockstep with `path` when it POPS (back button / swipe): each
        // push already appended its key, so on a push `path.count == askNavStack.count` and this is
        // a no-op; on a pop `path.count` drops below the stack and we truncate to match, so the top
        // key always reflects the visible node (fixes stale Ask scope after back-navigation).
        .onChange(of: path.count) { _, newCount in
            if askNavStack.count > newCount {
                askNavStack.removeLast(askNavStack.count - newCount)
            }
        }
        // Mount-independent pipeline kickoff (docs/plans/swift-meeting-generation-flow.md,
        // Track 2): fires exactly once per `.saved(meetingId)` transition, regardless of which
        // section/screen is on screen when a recording finishes — `RecordingView`'s own status
        // line (when it happens to be visible) reads the SAME coordinator, never triggers it.
        .onChange(of: environment.recordingSession?.phase) { _, newPhase in
            switch newPhase {
            case let .saved(meetingId):
                Task { await environment.processingCoordinator?.begin(meetingId: meetingId) }
            case .recording:
                // Courtesy "recording started" alert (gated by the Recording-alerts setting inside
                // `recordingStarted`). Fired here, mount-independently, so it posts regardless of
                // which screen is visible — the non-blocking successor to the consent prompt.
                let title = environment.recordingSession?.pendingTitle
                Task { await environment.meetingNotifications?.recordingStarted(meetingTitle: title) }
            default:
                break
            }
        }
        // The import equivalent (docs/plans/audio-import.md): when an import saves, dismiss the
        // sheet, kick the SAME post-recording pipeline, open the new meeting, and reset the session
        // so the sheet reopens clean. Mirrors the recording `.saved` handler above.
        .onChange(of: environment.importSession?.phase) { _, newPhase in
            guard case let .saved(meetingId) = newPhase else { return }
            showImportSheet = false
            Task { await environment.processingCoordinator?.begin(meetingId: meetingId) }
            path.append(meetingId)
            askNavStack.append(.meeting(meetingId))
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
                askNavStack.append(.meeting(meetingId))
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
        // The first-run install/education flow (docs/plans/onboarding-install-flow.md §6) — a
        // NEW, small, additive branch, not a rework of the pre-ready states above. Checked once
        // per launch, after the real shell is constructible: an absent/false
        // `.onboardingCompleted` flag shows the flow; `true` (set by either "Continue" or "Skip
        // for now" — resolved decision: never re-nag) means it never appears again.
        .task {
            guard let value = try? await database.settings.bool(forKey: .onboardingCompleted) else {
                showOnboarding = true
                return
            }
            showOnboarding = (value != true)
        }
        .sheet(isPresented: $showOnboarding) {
            if let onboardingViewModel = environment.onboardingViewModel {
                OnboardingView(viewModel: onboardingViewModel, onFinished: { showOnboarding = false })
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
            MeetingsListView(database: database, recallIndexTrigger: environment.recallIndexTrigger)
        case .series:
            SeriesListView(database: database, onCreated: { path.append($0); askNavStack.append(.series($0)) })
        case .people:
            PeopleListView(database: database)
        case .newMeeting:
            if let session = environment.recordingSession {
                RecordingView(session: session, onOpenMeeting: { path.append($0); askNavStack.append(.meeting($0)) })
            } else {
                placeholder("Recording isn't built yet.")
            }
        case .ask:
            AskPageView(
                onOpenMeeting: { path.append($0); askNavStack.append(.meeting($0)) },
                onOpenPerson: { path.append($0); askNavStack.append(.none) },
                onOpenSeries: { path.append($0); askNavStack.append(.series($0)) },
                onOpenSettings: { selectedSection = .settings }
            )
        case .calendar:
            CalendarPageView(
                database: database,
                calendarSource: environment.calendarSource,
                recordingSession: environment.recordingSession,
                selection: $selectedSection,
                onOpenMeeting: { path.append($0); askNavStack.append(.meeting($0)) }
            )
        case .settings:
            SettingsView(
                database: database,
                calendarSource: environment.calendarSource,
                notifications: environment.meetingNotifications,
                recordingSession: environment.recordingSession
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
