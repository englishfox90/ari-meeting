//
//  SettingsTranscriptionSection.swift — Transcription settings (docs/plans/settings-ui.md §6).
//
//  The whole section is honest-disabled behind one `MarginaliaBanner(.info)`: provider/model
//  selection and the per-provider download managers all still run in the frozen Rust engine —
//  the Swift port hasn't reached this seam yet. Apple on-device transcription is deliberately
//  excluded from this screen (plan §1) — never add an `apple` option here.
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

            SettingsDisabledGroup(availability: viewModel.transcriptionAvailability) {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                    SettingsCard(title: "Provider") {
                        Picker(selection: .constant(viewModel.transcriptionProvider)) {
                            Text("Parakeet").tag("parakeet")
                            Text("Whisper (local)").tag("localWhisper")
                        } label: {
                            MarginaliaMenuLabel(title: "Transcription provider", scheme: scheme)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    modelManagerCard(
                        title: "Parakeet",
                        currentModel: viewModel.transcriptionProvider == "parakeet"
                            ? viewModel.transcriptionModel
                            : nil
                    )

                    modelManagerCard(
                        title: "Whisper (local)",
                        currentModel: viewModel.transcriptionProvider == "localWhisper"
                            ? viewModel.transcriptionModel
                            : nil
                    )
                }
            }
            .padding(.horizontal, MarginaliaSpacing.md.value)
        }
    }

    private func modelManagerCard(title: String, currentModel: String?) -> some View {
        SettingsCard(title: "\(title) models") {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                HStack {
                    Text(currentModel ?? "No model selected")
                        .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
                    Spacer(minLength: 0)
                    if currentModel != nil {
                        MarginaliaBadge("Active", style: .neutral, scheme: scheme)
                    }
                }

                HStack(spacing: MarginaliaSpacing.sm.value) {
                    Button("Download") {}
                        .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                    Button("Select") {}
                        .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                    Button("Delete") {}
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
            }
        }
    }
}
