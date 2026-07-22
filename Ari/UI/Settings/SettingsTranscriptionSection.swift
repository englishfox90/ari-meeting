//
//  SettingsTranscriptionSection.swift — Transcription settings (docs/plans/settings-ui.md §6).
//
//  LIVE, not honest-disabled: the Swift app transcribes entirely on-device with Apple's
//  `SpeechTranscriber` (AriKit `Engine/STT/`). There is no provider/model choice to make —
//  SpeechTranscriber is the sole engine — so this screen exposes the only real knobs: the
//  transcription language and the on-device model download for that language. The Rust-era
//  Parakeet/Whisper panel it replaced was misleading (the Swift app never runs those). Reversed
//  the plan-§1 "exclude Apple" decision on 2026-07-21 once the STT port landed and shipped.
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

            if viewModel.transcriptionEngineAvailable {
                languageCard
                modelCard
            }
        }
    }

    // MARK: - Engine

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
                    if viewModel.transcriptionEngineAvailable {
                        MarginaliaBadge("Available", style: .success, scheme: scheme)
                    } else {
                        MarginaliaBadge("Unavailable", style: .neutral, scheme: scheme)
                    }
                }

                if !viewModel.transcriptionEngineAvailable {
                    MarginaliaBanner(
                        kind: .error,
                        message: "On-device speech transcription isn't available on this Mac.",
                        scheme: scheme
                    )
                }
            }
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
    }

    // MARK: - Language

    private var languageCard: some View {
        SettingsCard(title: "Language") {
            Picker(selection: languageBinding) {
                ForEach(viewModel.transcriptionLanguageOptions) { option in
                    Text(option.name).tag(option.id)
                }
            } label: {
                MarginaliaMenuLabel(title: "Transcription language", scheme: scheme)
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
    }

    // MARK: - Language model

    private var modelCard: some View {
        SettingsCard(title: "Language model") {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                HStack {
                    Text(modelStatusText)
                        .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
                    Spacer(minLength: 0)
                    if viewModel.transcriptionModelInstalled == true {
                        MarginaliaBadge("Installed", style: .success, scheme: scheme)
                    }
                }

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

                if viewModel.transcriptionModelInstalled != true, !isInstalling {
                    Button("Download language model") {
                        Task { await viewModel.installTranscriptionModel() }
                    }
                    .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                }
            }
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
    }

    // MARK: - Derived state

    private var modelStatusText: String {
        switch viewModel.transcriptionModelInstalled {
        case .some(true):
            "The speech model for this language is installed."
        case .some(false):
            "The speech model for this language isn't downloaded yet."
        case .none:
            "Checking model availability…"
        }
    }

    private var isInstalling: Bool {
        if case .installing = viewModel.transcriptionModelInstall {
            return true
        }
        return false
    }

    // MARK: - Bindings

    private var languageBinding: Binding<String> {
        Binding(
            get: { viewModel.transcriptionLanguage },
            set: { newValue in Task { await viewModel.selectTranscriptionLanguage(newValue) } }
        )
    }
}
