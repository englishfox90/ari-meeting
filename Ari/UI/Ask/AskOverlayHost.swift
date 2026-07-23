//
//  AskOverlayHost.swift — the app-wide amber "Ask" FAB + floating panel (docs/plans/
//  ari-ask-ui.md §7): mounted inside `readyShell`'s detail column only (never covers the sidebar
//  rail), absent during launch/import/failed/onboarding (the whole shell isn't mounted then), and
//  suppressed on `.newMeeting`, during active recording, and on the `.ask` page itself (one
//  Signal per screen — recording owns the red Signal there).
//
import AriKit
import AriViewModels
import SwiftUI

/// A lightweight nav-position key `RootSplitView` maintains alongside its opaque
/// `NavigationPath` — SwiftUI's `NavigationPath` has no public API to peek at its top element's
/// concrete type, so the app tracks "the meeting/series currently in view" explicitly at each
/// `path.append` call site instead of trying to introspect `path` itself. `AskOverlayHost`
/// resolves this key into the richer `AskNavContext` (real titles + series membership) itself.
enum AskNavKey: Hashable {
    case none
    case meeting(MeetingID)
    case series(SeriesID)
}

struct AskOverlayHost: View {
    let database: AppDatabase
    let recallEngine: RecallEngine?
    let selectedSection: SidebarSection
    let navKey: AskNavKey
    let isRecordingActive: Bool
    let onOpenMeeting: (MeetingID) -> Void
    let onOpenSettings: () -> Void

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
                .task { ensureViewModel() }
                .task(id: navKey) { await refreshScope() }
                .padding(MarginaliaSpacing.lg.value)
        }
    }

    /// One Signal per screen (plan §7): recording already owns the red Signal on `.newMeeting`
    /// and while a recording is active; the `.ask` page itself already hosts the full console.
    private var isSuppressed: Bool {
        selectedSection == .newMeeting || isRecordingActive || selectedSection == .ask
    }

    // A round chat-bubble FAB — the one amber Signal for "ask the AI" (plan §7/§8). Built as an
    // explicit accent-filled circle rather than the `.primary` glass pill: the pill read as a flat
    // system-tinted button, not a speech bubble, and the glyph looked like a zoom control.
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
        switch navKey {
        case .none:
            return .none

        case let .meeting(meetingId):
            guard let meeting = try? await database.meetings.find(meetingId) else { return .none }
            let seriesIds = (try? await database.series.seriesIds(forMeeting: meetingId)) ?? []
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
