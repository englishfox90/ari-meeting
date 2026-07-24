//
//  AskOverlayHost.swift — the app-wide amber "Ask" FAB + floating panel (docs/plans/
//  ari-ask-ui.md §7): mounted inside `readyShell`'s detail column only (never covers the sidebar
//  rail), absent during launch/import/failed/onboarding (the whole shell isn't mounted then), and
//  suppressed on `.newMeeting`, during active recording, and on the `.ask` page itself (one
//  Signal per screen — recording owns the red Signal there).
//
//  Nav-position resolution: `AskNavKey` (AriKit/Sources/AriViewModels/Ask/AskNavTracker.swift) is
//  no longer maintained by a parallel stack of `path.append` call sites — that missed every
//  internal `NavigationLink(value:)` push (bug fix, 2026-07-24). It's now VIEW-DECLARED presence:
//  `MeetingDetailView`/`SeriesDetailView` register themselves on `environment.askNavTracker` while
//  on screen, and this host just reads `environment.askNavTracker.top`.
//
import AriKit
import AriViewModels
import SwiftUI

struct AskOverlayHost: View {
    let database: AppDatabase
    let recallEngine: RecallEngine?
    let selectedSection: SidebarSection
    let isRecordingActive: Bool
    let onOpenMeeting: (MeetingID) -> Void
    let onOpenPerson: (PersonID) -> Void
    let onOpenSeries: (SeriesID) -> Void
    let onOpenSettings: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme
    @State private var viewModel: AskViewModel?
    @State private var isExpanded = false

    private static let resolver = AskScopeResolver()

    var body: some View {
        if isSuppressed {
            EmptyView()
        } else {
            fab
                .popover(isPresented: $isExpanded, arrowEdge: .trailing) { panel }
                // Keyed on engine readiness so it re-runs when `recallEngine` flips nil→available:
                // the shell can mount the FAB before bootstrap assigns the engine, and a plain
                // `.task {}` (no id) would run once against the nil engine and never retry, leaving
                // the panel stuck on `ProgressView()` until a navigation change. Also refreshes
                // scope here (not just `ensureViewModel()`): if the engine was still nil when the
                // nav-key task fired, that scope refresh was silently lost with no later retry —
                // this idempotent re-run (via `refreshScope()`'s own `ensureViewModel()` call)
                // recovers it the moment the engine arrives.
                .task(id: recallEngine != nil) { await refreshScope() }
                .task(id: environment.askNavTracker.top) { await refreshScope() }
                // Belt-and-suspenders (caught live 2026-07-23: the panel stayed on `ProgressView()`
                // even well after bootstrap had clearly finished — the main `.ask` page worked fine
                // in the same session). `.popover`'s content can be unreliable about picking up a
                // `@State` change that happens while it's already presented on macOS; re-running the
                // same idempotent refresh at the exact moment the user opens the panel (using
                // whichever `recallEngine`/nav-key values are current then) sidesteps that
                // reactivity gap instead of depending on it — so an open popup always reflects the
                // current page rather than whatever it last resolved.
                .onChange(of: isExpanded) { _, expanded in
                    if expanded {
                        Task { await refreshScope() }
                    }
                }
                .padding(MarginaliaSpacing.lg.value)
        }
    }

    /// One Signal per screen (plan §7): recording already owns the red Signal on `.newMeeting`
    /// and while a recording is active; the `.ask` page itself already hosts the full console.
    private var isSuppressed: Bool {
        selectedSection == .newMeeting || isRecordingActive || selectedSection == .ask
    }

    /// A round chat-bubble FAB — the one amber Signal for "ask the AI" (plan §7/§8). Built as an
    /// explicit accent-filled circle rather than the `.primary` glass pill: the pill read as a flat
    /// system-tinted button, not a speech bubble, and the glyph looked like a zoom control.
    private var fab: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.marginalia(.canvas, in: scheme))
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.marginalia(.accent, in: scheme)))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask your meetings")
    }

    @ViewBuilder
    private var panel: some View {
        if let viewModel {
            VStack(spacing: 0) {
                AskScopePill(viewModel: viewModel)
                    .padding(MarginaliaSpacing.md.value)
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                AskConsoleView(
                    viewModel: viewModel,
                    onOpenMeeting: { meetingId in
                        isExpanded = false
                        onOpenMeeting(MeetingID(rawValue: meetingId))
                    },
                    onOpenPerson: { personId in
                        isExpanded = false
                        onOpenPerson(PersonID(rawValue: personId))
                    },
                    onOpenSeries: { seriesId in
                        isExpanded = false
                        onOpenSeries(SeriesID(rawValue: seriesId))
                    },
                    onOpenSettings: {
                        isExpanded = false
                        onOpenSettings()
                    }
                )
            }
            .frame(width: 420, height: 560)
        } else {
            // Honest "not ready" — the engine hasn't finished bootstrapping yet (No-Fake-State).
            ProgressView()
                .frame(width: 420, height: 560)
        }
    }

    private func ensureViewModel() {
        guard viewModel == nil, let recallEngine else { return }
        viewModel = AskViewModel(
            recallEngine: recallEngine,
            conversationStore: database.askConversations,
            scope: .global
        )
    }

    /// Re-derives `availableScopes`/`scope` whenever the app's navigation position changes (plan
    /// §7 "Scope auto-derivation") — cancels any in-flight ask and starts a fresh thread
    /// (`AskViewModel.setScope`'s own contract), matching "changing it cancels in-flight + starts
    /// a fresh thread".
    private func refreshScope() async {
        ensureViewModel()
        guard let viewModel else { return }
        let context = await resolveNavContext()
        viewModel.setAvailableScopes(Self.resolver.availableScopes(for: context))
        viewModel.setScope(Self.resolver.defaultScope(from: context))
    }

    private func resolveNavContext() async -> AskNavContext {
        switch environment.askNavTracker.top {
        case .none:
            return .none

        case let .meeting(meetingId):
            guard let meeting = try? await database.meetings.find(meetingId) else { return .none }
            let seriesIds = await (try? database.series.seriesIds(forMeeting: meetingId)) ?? []
            var seriesRef: AskNavSeriesRef?
            if let firstSeriesId = seriesIds.first,
               let series = try? await database.series.find(firstSeriesId) {
                seriesRef = AskNavSeriesRef(id: series.id, title: series.title)
            }
            return .meeting(meeting.id, title: meeting.title, series: seriesRef)

        case let .series(seriesId):
            guard let series = try? await database.series.find(seriesId) else { return .none }
            return .series(series.id, title: series.title)
        }
    }
}
