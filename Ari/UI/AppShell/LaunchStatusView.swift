//
//  LaunchStatusView.swift — launching/importing/failed readout (extracted from the S0
//  `ContentView`, plan §2.2 AppShell). `.ready` is handled by `RootSplitView` itself, which
//  swaps to the real 3-column shell — this view only ever renders the pre-ready states.
//
import AriKit
import SwiftUI

struct LaunchStatusView: View {
    let status: AppEnvironment.Status
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: MarginaliaSpacing.lg.value) {
            // The Marginalia "Dictation" mark — the brand logo, not an audio glyph. Rendered as a
            // tintable template vector; Shin-kai accent is the one hero element on the launch field.
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 108)
                .foregroundStyle(Color.marginalia(.accent, in: scheme))

            Text("Ari Meetings")
                .marginaliaTextStyle(.title2, in: scheme)

            statusView
                .padding(.top, MarginaliaSpacing.sm.value)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MarginaliaSpacing.xxl.value)
        .background(Color.marginalia(.canvas, in: scheme))
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .launching:
            HStack(spacing: MarginaliaSpacing.sm.value) {
                ProgressView().controlSize(.small)
                Text("Opening your library…")
                    .marginaliaTextStyle(.body, in: scheme)
            }
        case .importing:
            HStack(spacing: MarginaliaSpacing.sm.value) {
                ProgressView().controlSize(.small)
                Text("Importing your existing library…")
                    .marginaliaTextStyle(.body, in: scheme)
            }
        case .ready:
            // RootSplitView switches to the real shell before this ever renders — kept only
            // so the switch stays exhaustive.
            EmptyView()
        case let .failed(message):
            VStack(spacing: MarginaliaSpacing.xs.value) {
                Text("Couldn't open your library")
                    .marginaliaTextStyle(.body, in: scheme, ink: .recordingRed)
                Text(message)
                    .marginaliaTextStyle(.caption, in: scheme)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
