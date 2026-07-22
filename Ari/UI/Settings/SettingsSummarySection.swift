//
//  SettingsSummarySection.swift — Summary settings (docs/plans/settings-ui.md §6, the largest
//  section).
//
//  Automatic summary, language, provider/model, Ollama endpoint, and API-key entry all persist
//  for real through `SettingsViewModel`. Per-provider model downloads and index rebuild stay
//  honest-disabled (still Rust-only); the embedder choice itself persists live, but the Nomic
//  GGUF download manager is honest-disabled the same way. Apple/apple-foundation/apple embedder
//  are deliberately excluded from this screen (plan §1) — never add them back here.
//
import AriKit
import AriViewModels
import SwiftUI

struct SettingsSummarySection: View {
    let viewModel: SettingsViewModel

    @Environment(\.colorScheme) private var scheme

    @State private var modelText: String = ""
    @State private var endpointText: String = ""
    @State private var endpointValidationMessage: String?
    @State private var customLanguageText: String = ""
    @State private var apiKeyText: String = ""
    @State private var hasStoredAPIKey: Bool = false

    /// A curated, static set of common summary languages — not a fabricated "recently used"
    /// history (there is no persisted MRU list), just the fixed chip row the plan calls for.
    private static let languageChips: [(code: String, label: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("pt", "Portuguese"),
        ("ja", "Japanese")
    ]

    private static let visibleProviders: [ProviderKind] = [.mlx, .ollama, .claudeCLI]

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "Summary")

            VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                automaticSummaryCard
                languageCard
                modelConfigCard
                apiKeyCard
                modelDownloadsCard
                embedderCard
                indexStatsCard
            }
            .padding(.horizontal, MarginaliaSpacing.md.value)
        }
        .task {
            modelText = viewModel.summaryModel
            endpointText = viewModel.summaryOllamaEndpoint
            hasStoredAPIKey = await viewModel.hasAPIKey(for: viewModel.summaryProvider)
        }
        .onChange(of: viewModel.summaryModel) { _, newValue in
            modelText = newValue
        }
        .onChange(of: viewModel.summaryOllamaEndpoint) { _, newValue in
            endpointText = newValue
        }
        .onChange(of: viewModel.summaryProvider) { _, newProvider in
            Task {
                hasStoredAPIKey = await viewModel.hasAPIKey(for: newProvider)
            }
        }
    }

    // MARK: - Automatic summary

    private var automaticSummaryCard: some View {
        SettingsCard {
            MarginaliaToggleRow(
                "Automatically generate summary",
                description: "Summarize each meeting as soon as the transcript finishes.",
                isOn: Binding(
                    get: { viewModel.summaryAutomatic },
                    set: { newValue in
                        Task { try? await viewModel.setSummaryAutomatic(newValue) }
                    }
                ),
                scheme: scheme
            )
        }
    }

    // MARK: - Language

    private var languageCard: some View {
        SettingsCard(title: "Summary language") {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                MarginaliaFlowLayout(spacing: MarginaliaSpacing.xs.value) {
                    ForEach(Self.languageChips, id: \.code) { chip in
                        MarginaliaBadge(
                            chip.label,
                            style: viewModel.summaryLanguage == chip.code ? .accent : .neutral,
                            scheme: scheme
                        ) {
                            Task { try? await viewModel.setSummaryLanguage(chip.code) }
                        }
                    }
                }

                MarginaliaBadge(
                    "Default: English",
                    style: .neutral,
                    symbol: "pin.fill",
                    scheme: scheme
                )

                HStack(spacing: MarginaliaSpacing.sm.value) {
                    MarginaliaTextField(
                        text: $customLanguageText,
                        prompt: "Custom language code (e.g. it, nl)",
                        scheme: scheme
                    )
                    Button("Use") {
                        let code = customLanguageText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !code.isEmpty else { return }
                        Task { try? await viewModel.setSummaryLanguage(code) }
                    }
                    .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                    .disabled(customLanguageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Model config

    private var modelConfigCard: some View {
        SettingsCard(title: "Summary model") {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                Picker(selection: providerBinding) {
                    ForEach(Self.visibleProviders, id: \.self) { provider in
                        Text(providerLabel(provider)).tag(provider)
                    }
                } label: {
                    MarginaliaMenuLabel(title: "Provider", scheme: scheme)
                }
                .pickerStyle(.menu)
                .labelsHidden()

                MarginaliaTextField(
                    text: $modelText,
                    prompt: "Model (optional)",
                    scheme: scheme
                )
                .onSubmit {
                    Task { try? await viewModel.setSummaryModel(modelText) }
                }

                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    MarginaliaTextField(
                        text: $endpointText,
                        prompt: "Ollama endpoint (e.g. http://localhost:11434)",
                        scheme: scheme
                    )
                    .onSubmit {
                        validateEndpoint()
                        Task {
                            try? await viewModel.setSummaryOllamaEndpoint(
                                endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        }
                    }

                    if let endpointValidationMessage {
                        MarginaliaBanner(kind: .error, message: endpointValidationMessage, scheme: scheme)
                    }

                    Text("Ollama access stays loopback-only — enforced inside the recall engine, not here.")
                        .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                }
            }
        }
    }

    private var providerBinding: Binding<ProviderKind> {
        Binding(
            get: { ProviderKind.from(viewModel.summaryProvider) ?? .mlx },
            set: { newProvider in
                Task { try? await viewModel.setSummaryProvider(newProvider.rawValue) }
            }
        )
    }

    private func providerLabel(_ provider: ProviderKind) -> String {
        switch provider {
        case .mlx: "Built-in AI (on-device)"
        case .ollama: "Ollama (local)"
        case .claudeCLI: "Claude CLI"
        default: provider.rawValue
        }
    }

    private func validateEndpoint() {
        let trimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme,
            ["http", "https"].contains(scheme.lowercased()),
            url.host != nil
        else {
            endpointValidationMessage = "Enter a valid http(s) URL, e.g. http://localhost:11434."
            return
        }
        endpointValidationMessage = nil
    }

    // MARK: - API key

    private var apiKeyCard: some View {
        SettingsCard(title: "API key") {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                HStack(spacing: MarginaliaSpacing.sm.value) {
                    Text(hasStoredAPIKey ? "A key is stored for this provider." : "No key stored.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    if hasStoredAPIKey {
                        MarginaliaBadge("Stored", style: .success, scheme: scheme)
                    }
                }

                SecureField("API key", text: $apiKeyText)
                    .textFieldStyle(.plain)
                    .marginaliaTextStyle(.body, in: scheme)
                    .padding(.horizontal, MarginaliaSpacing.sm.value)
                    .frame(height: MarginaliaFieldSpec.standard.height)
                    .background {
                        RoundedRectangle(cornerRadius: MarginaliaFieldSpec.standard.radius.value, style: .continuous)
                            .fill(Color.marginalia(MarginaliaFieldSpec.standard.fill, in: scheme))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: MarginaliaFieldSpec.standard.radius.value, style: .continuous)
                            .strokeBorder(
                                Color.marginalia(MarginaliaFieldSpec.standard.stroke, in: scheme),
                                lineWidth: 1
                            )
                    }

                HStack(spacing: MarginaliaSpacing.sm.value) {
                    Button("Save key") {
                        let key = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        let provider = viewModel.summaryProvider
                        Task {
                            try? await viewModel.setAPIKey(key, for: provider)
                            apiKeyText = ""
                            hasStoredAPIKey = await viewModel.hasAPIKey(for: provider)
                        }
                    }
                    .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                    .disabled(apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Remove") {
                        let provider = viewModel.summaryProvider
                        Task {
                            try? await viewModel.deleteAPIKey(for: provider)
                            hasStoredAPIKey = await viewModel.hasAPIKey(for: provider)
                        }
                    }
                    .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                    .disabled(!hasStoredAPIKey)
                }

                Text("Never displayed once saved — only presence is shown.")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }
        }
    }

    // MARK: - Model downloads (honest-disabled)

    private var modelDownloadsCard: some View {
        SettingsDisabledGroup(availability: viewModel.modelDownloadsAvailability) {
            SettingsCard(title: "Model downloads") {
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

    // MARK: - Embedder

    private var embedderCard: some View {
        SettingsCard(title: "Meeting search embedder") {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                embedderRow(
                    backend: .ollama,
                    title: "Ollama",
                    description: "Local Ollama embedding endpoint — default."
                )
                embedderRow(
                    backend: .nomicGguf,
                    title: "Nomic (GGUF)",
                    description: "A dedicated local GGUF embedding model."
                )

                if EmbedBackend.from(setting: viewModel.recallEmbedder) == .nomicGguf {
                    SettingsDisabledGroup(availability: viewModel.nomicDownloadAvailability) {
                        Button("Download Nomic model") {}
                            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                    }
                }
            }
        }
    }

    private func embedderRow(backend: EmbedBackend, title: String, description: String) -> some View {
        let isSelected = EmbedBackend.from(setting: viewModel.recallEmbedder) == backend
        return Button {
            Task { try? await viewModel.setRecallEmbedder(backend.id) }
        } label: {
            HStack(spacing: MarginaliaSpacing.sm.value) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color.marginalia(isSelected ? .accent : .inkSecondary, in: scheme))
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    Text(title)
                        .marginaliaTextStyle(.body, in: scheme)
                    Text(description)
                        .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Index stats (honest, read-only)

    private var indexStatsCard: some View {
        SettingsCard(title: "Meeting search index") {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                if let summary = viewModel.indexSummary {
                    Text("\(summary.indexedMeetings) meetings indexed")
                        .marginaliaTextStyle(.body, in: scheme)
                    Text("\(summary.chunkCount) chunks, \(summary.embeddedChunkCount) embedded")
                        .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                } else {
                    Text("No index stats available yet.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }

                SettingsDisabledGroup(availability: viewModel.rebuildIndexAvailability) {
                    Button("Rebuild index") {}
                        .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                }
            }
        }
    }
}
