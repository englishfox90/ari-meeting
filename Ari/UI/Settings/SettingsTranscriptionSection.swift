//
//  SettingsTranscriptionSection.swift — Transcription settings (docs/plans/settings-ui.md §6).
//
//  LIVE, not honest-disabled: the Swift app transcribes entirely on-device with Apple Speech
//  (AriKit `Engine/STT/`). There is no provider/model/language choice to make — it is the sole
//  engine and follows the Mac's system language — so this is ONE card with a single honest
//  readiness state: "Ready" when the engine can run and its language model is installed; otherwise
//  it surfaces exactly the blocker (engine unavailable, or a Download for the missing model). The
//  two-badge "Available" + "Installed" pairing it replaced read as redundant on the happy path.
//  The Rust-era Parakeet/Whisper panel before that was misleading (the Swift app never runs those).
//  Reversed the plan-§1 "exclude Apple" decision on 2026-07-21 once the STT port landed and shipped.
//
import AriKit
import AriViewModels
import SwiftUI

struct SettingsTranscriptionSection: View {
    let viewModel: SettingsViewModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "Transcription")
            engineCard
        }
    }

    private var engineCard: some View {
        SettingsCard(title: "Engine") {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                        Text("On-device — Apple Speech")
                            .marginaliaTextStyle(.body, in: scheme)
                        Text("Meetings are transcribed entirely on this Mac. Audio never leaves the device.")
                            .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    }
                    Spacer(minLength: MarginaliaSpacing.sm.value)
                    statusBadge
                }

                detail
            }
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
    }

    // MARK: - Readiness

    /// One collapsed badge: "Ready" only when the engine runs AND its model is installed;
    /// "Unavailable" when the engine can't run here. The model-missing / checking / installing
    /// states carry their own affordance in `detail`, so they get no top badge.
    @ViewBuilder private var statusBadge: some View {
        if !viewModel.transcriptionEngineAvailable {
            MarginaliaBadge("Unavailable", style: .neutral, scheme: scheme)
        } else if viewModel.transcriptionModelInstalled == true {
            MarginaliaBadge("Ready", style: .success, scheme: scheme)
        }
    }

    @ViewBuilder private var detail: some View {
        if !viewModel.transcriptionEngineAvailable {
            MarginaliaBanner(
                kind: .error,
                message: "On-device speech transcription isn't available on this Mac.",
                scheme: scheme
            )
        } else {
            switch viewModel.transcriptionModelInstalled {
            case .some(true):
                // "Ready" badge already says it — nothing more to show.
                EmptyView()
            case .some(false):
                modelDownload
            case .none:
                Text("Checking the on-device speech model…")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            }
        }
    }

    /// Shown only when the engine is available but its language model isn't installed yet.
    private var modelDownload: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text("The on-device speech model for your Mac's language needs to be downloaded before recording.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)

            switch viewModel.transcriptionModelInstall {
            case let .installing(fraction):
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    ProgressView(value: fraction)
                        .tint(Color.marginalia(.accent, in: scheme))
                    Text("Downloading… \(Int((fraction * 100).rounded()))%")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            case let .failed(message):
                MarginaliaBanner(kind: .error, message: message, scheme: scheme)
            case .idle:
                EmptyView()
            }

            if !isInstalling {
                Button("Download model") {
                    Task { await viewModel.installTranscriptionModel() }
                }
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
            }
        }
    }

    private var isInstalling: Bool {
        if case .installing = viewModel.transcriptionModelInstall {
            return true
        }
        return false
    }
}
