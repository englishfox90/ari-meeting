//
//  MenuBarContentView.swift — the `MenuBarExtra` panel (docs/plans/menu-bar-item.md).
//
//  The Swift port of the frozen Rust tray menu (`frontend/src-tauri/src/tray.rs`): start/stop a
//  recording, see the "happening now / about to start" calendar brief and record one pre-named,
//  open the app, jump to Settings, quit. Additive + opt-in — `AriApp` only inserts this scene when
//  the `MenuBarVisibilityStore` key is on.
//
//  Reuses the app's real seams rather than re-deriving anything: `RecordingSession` (the app-wide,
//  mount-independent recording brain) for start/stop + state, and `CalendarBriefViewModel` /
//  `CalendarBriefSection` (verbatim from Home) for the upcoming list + the record handoff. Every
//  state is honest (No-Fake-State): no Pause/Resume (the Swift session has no pause phase yet), an
//  empty brief simply renders nothing, and Record is disabled while a recording is already active.
//
import AppKit
import AriKit
import AriViewModels
import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    /// Built once the shell is `.ready` (a real `database` exists). Local-DB-first like Home's
    /// brief — no live EventKit call, no permission prompt; the 15-min background sync keeps it
    /// fresh, and `load()` re-filters against a fresh `now` each time the panel opens.
    @State private var brief: CalendarBriefViewModel?

    private var recordingSession: RecordingSession? { environment.recordingSession }

    /// The live phase, or `.idle` when the session doesn't exist yet (pre-bootstrap) — the Start
    /// control then renders disabled via `recordingSession == nil`, never a fake-enabled button.
    private var phase: RecordingSession.Phase { recordingSession?.phase ?? .idle }

    /// `false` while the session is missing (pre-bootstrap) or already active — Record stays
    /// honestly disabled rather than pretending a second start is possible (Home's posture).
    private var canRecord: Bool {
        recordingSession != nil && !(recordingSession?.isActive ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            header
            hairline

            if environment.status == .ready {
                recordingControls
                if let brief, !brief.events.isEmpty {
                    CalendarBriefSection(
                        viewModel: brief,
                        scheme: scheme,
                        canRecord: canRecord,
                        onRecord: { record(event: $0) }
                    )
                }
            } else {
                statusRow("Ari is starting…")
            }

            hairline
            footer
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(width: 300)
        // Bootstrap even when no main window is open (menu-bar-only state) — idempotent-guarded, so
        // a no-op when the window already ran it at launch.
        .task { await environment.bootstrap() }
        // Re-runs when the shell becomes ready (build + load the brief) and on each panel open —
        // a meeting that has since started or passed re-sorts or drops off, exactly like Home.
        .task(id: environment.status == .ready) { await loadBrief() }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.marginalia(.hairline, in: scheme))
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Text("Ari")
                .marginaliaTextStyle(.headline, in: scheme)
            Spacer(minLength: MarginaliaSpacing.sm.value)
            if recordingSession?.isActive == true {
                // Amber = the one thing that matters right now (the Signal Rule): a live recording.
                MarginaliaBadge("Recording", style: .accent, scheme: scheme)
            }
        }
    }

    // MARK: - Recording controls (honest to the Swift session model — Start/Stop only)

    @ViewBuilder
    private var recordingControls: some View {
        switch phase {
        case .recording:
            Button {
                stop()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
        case .starting, .consentPrompt:
            statusRow("Starting…")
        case .stopping:
            statusRow("Stopping…")
        case .idle, .saved, .failed:
            Button {
                start()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.marginalia(.primary, .regular, in: scheme))
            .disabled(recordingSession == nil)
        }
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: MarginaliaSpacing.xs.value) {
            menuButton("Open Ari", systemImage: "macwindow") { activateApp() }
            menuButton("Settings", systemImage: "gearshape") {
                activateApp()
                environment.navigate(to: .settings)
            }
            menuButton("Quit Ari", systemImage: "power") { NSApp.terminate(nil) }
        }
    }

    private func menuButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
    }

    // MARK: - Actions

    private func start() {
        activateApp()
        environment.startRecordingFromMenuBar()
    }

    private func stop() {
        activateApp()
        Task { await recordingSession?.stop() }
    }

    /// Record a calendar event pre-named — the SAME prime-and-start-immediately path a meeting
    /// reminder uses (`startRecordingFromReminder`), so the two entry points can never diverge.
    private func record(event: CalendarEvent) {
        activateApp()
        Task { await environment.startRecordingFromReminder(eventId: event.id) }
    }

    /// Bring the app forward, fronting the existing content window or opening a fresh one when all
    /// windows are closed (menu-bar-only state). Activating also moves focus off the popover, which
    /// dismisses it — no manual dismiss plumbing needed.
    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: AriApp.mainWindowID)
        }
    }

    private func loadBrief() async {
        guard environment.status == .ready, let database = environment.database else { return }
        if brief == nil {
            brief = CalendarBriefViewModel(database: database, source: environment.calendarSource)
        }
        await brief?.load()
    }
}
