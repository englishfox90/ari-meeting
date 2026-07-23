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
    @Environment(\.colorScheme) private var scheme

    /// Built once the shell is `.ready` (a real `database` exists). Local-DB-first like Home's
    /// brief — no live EventKit call, no permission prompt; the 15-min background sync keeps it
    /// fresh, and `load()` re-filters against a fresh `now` each time the panel opens.
    @State private var brief: CalendarBriefViewModel?

    private var recordingSession: RecordingSession? {
        environment.recordingSession
    }

    /// The live phase, or `.idle` when the session doesn't exist yet (pre-bootstrap) — the Start
    /// control then renders disabled via `recordingSession == nil`, never a fake-enabled button.
    private var phase: RecordingSession.Phase {
        recordingSession?.phase ?? .idle
    }

    /// `false` while the session is missing (pre-bootstrap) or already active — Record stays
    /// honestly disabled rather than pretending a second start is possible (Home's posture).
    private var canRecord: Bool {
        recordingSession != nil && !(recordingSession?.isActive ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
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
        .padding(MarginaliaSpacing.sm.value)
        .frame(width: 260)
        // Bootstrap even when no main window is open (menu-bar-only state) — idempotent-guarded, so
        // a no-op when the window already ran it at launch.
        .task { await environment.bootstrap() }
        // Builds + loads the brief once the shell is ready. `load()` re-filters against a fresh
        // `now`, so whenever SwiftUI re-runs this task (readiness flip, or a content recreate on
        // panel reopen) a since-passed meeting re-sorts or drops off. Even a snapshot that lags one
        // open is honest — every row is a real DB event, never fabricated (same posture as Home).
        .task(id: environment.status == .ready) { await loadBrief() }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.marginalia(.hairline, in: scheme))
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            // The Ari brand mark, tinted accent — the same treatment as the sidebar wordmark
            // (`SidebarView.wordmark`), so the panel reads as our app rather than plain text.
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 16)
                .foregroundStyle(Color.marginalia(.accent, in: scheme))
            Text("Ari")
                .marginaliaTextStyle(.subheadline, in: scheme)
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
            // Amber = the one thing that matters (Signal Rule): a live recording is stoppable here.
            MenuBarRow(title: "Stop Recording", systemImage: "stop.circle.fill", scheme: scheme, emphasis: .recording) {
                stop()
            }
        case .starting, .consentPrompt:
            statusRow("Starting…")
        case .stopping:
            statusRow("Stopping…")
        case .idle, .saved, .failed:
            // The one prominent (amber) row — the panel's primary action, sized as a menu row so it
            // reads native rather than as an in-app CTA button.
            MenuBarRow(title: "Start Recording", systemImage: "record.circle", scheme: scheme, emphasis: .accent) {
                start()
            }
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
        VStack(spacing: 2) {
            MenuBarRow(title: "Open Ari", systemImage: "macwindow", scheme: scheme) { activateApp() }
            MenuBarRow(title: "Settings", systemImage: "gearshape", scheme: scheme) {
                activateApp()
                environment.navigate(to: .settings)
            }
            MenuBarRow(title: "Quit Ari", systemImage: "power", scheme: scheme) { NSApp.terminate(nil) }
        }
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
        environment.activateApp()
    }

    private func loadBrief() async {
        guard environment.status == .ready, let database = environment.database else { return }
        if brief == nil {
            brief = CalendarBriefViewModel(database: database, source: environment.calendarSource)
        }
        await brief?.load()
    }
}

/// A compact, native-feeling menu-bar row — the popover analog of the in-app Marginalia button
/// system, sized for a menu (13pt label, 24pt height) rather than a window CTA. `.standard` rows
/// are flat text with a subtle hover wash; the single `.accent`/`.recording` row is the Signal
/// (solid amber / recording-red), keeping brand accent to one element per the ≤8% Signal Rule.
private struct MenuBarRow: View {
    enum Emphasis { case standard, accent, recording }

    let title: String
    let systemImage: String
    let scheme: ColorScheme
    var emphasis: Emphasis = .standard
    let action: () -> Void

    @State private var hovering = false
    /// A disabled row must read as disabled (No-Fake-State) — mirror the Marginalia button's 0.4 dim.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: emphasis == .standard ? .regular : .semibold))
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MarginaliaSpacing.sm.value)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                .fill(background)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }

    private var fill: Color? {
        switch emphasis {
        case .standard: nil
        case .accent: Color.marginalia(.accent, in: scheme)
        case .recording: Color.marginalia(.recordingRed, in: scheme)
        }
    }

    private var background: Color {
        if let fill {
            return fill
        }
        return hovering ? Color.marginalia(.selectionWash, in: scheme) : .clear
    }

    private var foreground: Color {
        switch emphasis {
        case .standard: Color.marginalia(.inkBody, in: scheme)
        // `.canvas` (near-white light / near-black dark) stays high-contrast on the solid accent
        // fill in both schemes — the same reasoning as the Marginalia primary button's label role.
        case .accent, .recording: Color.marginalia(.canvas, in: scheme)
        }
    }
}
