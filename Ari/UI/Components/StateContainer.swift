//
//  StateContainer.swift — renders a `LoadState` honestly: ProgressView / empty copy /
//  error copy / the loaded content (plan §2.2 Components, No-Fake-State).
//
import AriKit
import AriViewModels
import SwiftUI

struct StateContainer<Value: Sendable, Content: View>: View {
    let state: LoadState<Value>
    let emptyTitle: String
    let emptyMessage: String?
    @ViewBuilder let content: (Value) -> Content

    @Environment(\.colorScheme) private var scheme

    init(
        state: LoadState<Value>,
        emptyTitle: String,
        emptyMessage: String? = nil,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.state = state
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.content = content
    }

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(value):
            content(value)
        case .empty:
            emptyView
        case let .failed(message):
            failedView(message)
        }
    }

    private var emptyView: some View {
        VStack(spacing: MarginaliaSpacing.xs.value) {
            Text(emptyTitle)
                .marginaliaTextStyle(.body, in: scheme)
            if let emptyMessage {
                Text(emptyMessage)
                    .marginaliaTextStyle(.callout, in: scheme)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MarginaliaSpacing.xl.value)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: MarginaliaSpacing.xs.value) {
            Text("Something went wrong")
                .marginaliaTextStyle(.body, in: scheme)
                .foregroundStyle(Color.marginalia(.recordingRed, in: scheme))
            Text(message)
                .marginaliaTextStyle(.caption, in: scheme)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MarginaliaSpacing.xl.value)
    }
}
