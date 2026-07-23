//
//  AskPageView.swift — the `.ask` sidebar route host (docs/plans/ari-ask-ui.md §7): a global-scope
//  `AskConsoleView` + recent list, no scope pill (there's nothing to scope to at the top level).
//
import AriKit
import AriViewModels
import SwiftUI

struct AskPageView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme
    let onOpenMeeting: (MeetingID) -> Void
    let onOpenSettings: () -> Void

    @State private var viewModel: AskViewModel?

    var body: some View {
        ZStack {
            MarginaliaCanvasWash(scheme: scheme)
            if let viewModel {
                AskConsoleView(
                    viewModel: viewModel,
                    onOpenMeeting: { meetingId in onOpenMeeting(MeetingID(rawValue: meetingId)) },
                    onOpenSettings: onOpenSettings
                )
            } else {
                notReadyState
            }
        }
        .task {
            guard viewModel == nil,
                  let recallEngine = environment.recallEngine,
                  let database = environment.database
            else { return }
            viewModel = AskViewModel(
                recallEngine: recallEngine,
                conversationStore: database.askConversations,
                scope: .global
            )
        }
    }

    /// Honest fallback (No-Fake-State) for the brief window before `bootstrap()`'s
    /// `recallEngine` is available — never a fake-ready console over a missing engine.
    private var notReadyState: some View {
        VStack(spacing: MarginaliaSpacing.md.value) {
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 72)
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
            Text("Ask isn't ready yet.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
