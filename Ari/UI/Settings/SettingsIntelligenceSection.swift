//
//  SettingsIntelligenceSection.swift — the merged on-device model settings (docs/plans/settings-ui.md §6).
//
//  Consolidates what were three separate tabs' worth of "which on-device model does what" into one
//  pane, mirroring macOS's own "Apple Intelligence & Siri" pane: Transcription (Apple Speech STT),
//  Summary (LLM provider/model + language), and Meeting Search (embedder + recall index). Rendered
//  in the Apple grouped-list idiom (`SettingsGroup`/`SettingsRow`) — related rows in one paper
//  container, label-left / control-right.
//
//  Honesty is unchanged from the sections it replaces: transcription is LIVE over Apple Speech with
//  a single collapsed readiness state; the summary LLM is deliberately the two evaluated options
//  (on-device Qwen 4B + Claude CLI — no Ollama, no cloud); the search embedder is the single
//  non-configurable on-device `AppleContextualEmbedder`; the recall index rebuild is LIVE.
//
import AriKit
import AriViewModels
import SwiftUI

struct SettingsIntelligenceSection: View {
    let viewModel: SettingsViewModel
    let database: AppDatabase

    @Environment(\.colorScheme) private var scheme

    @State private var modelText: String = ""
    @State private var customLanguageText: String = ""
    @State private var showingCustomLanguage: Bool = false
    @State private var apiKeyText: String = ""
    @State private var hasStoredAPIKey: Bool = false

    /// A curated, static set of common summary languages — not a fabricated "recently used"
    /// history (there is no persisted MRU list), just the fixed set the plan calls for.
    private static let languageChips: [(code: String, label: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("pt", "Portuguese"),
        ("ja", "Japanese")
    ]

    /// Sentinel selection meaning "let me type a language code that isn't a preset".
    private static let customLanguageSentinel = "__custom__"

    private static let visibleProviders: [ProviderKind] = [.mlx, .claudeCLI]

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "Intelligence")

            VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                transcriptionGroup
                summaryGroup
                if selectedProvider.requiresAPIKey {
                    apiKeyGroup
                }
                searchGroup
            }
            .padding(.horizontal, MarginaliaSpacing.md.value)
        }
        .task {
            modelText = viewModel.summaryModel
            // Only touch the Keychain when a key-bearing provider is actually selected; both
            // visible providers (.mlx, .claudeCLI) are keyless today, so the apiKeyGroup stays
            // dormant and this fetch is skipped.
            if selectedProvider.requiresAPIKey {
                hasStoredAPIKey = await viewModel.hasAPIKey(for: viewModel.summaryProvider)
            }
            syncLanguageState()
        }
        .onChange(of: viewModel.summaryModel) { _, newValue in
            modelText = newValue
        }
        .onChange(of: viewModel.summaryProvider) { _, newProvider in
            guard selectedProvider.requiresAPIKey else { return }
            Task { hasStoredAPIKey = await viewModel.hasAPIKey(for: newProvider) }
        }
        .onChange(of: viewModel.summaryLanguage) { _, _ in
            // Re-sync the custom-code reveal if the language changes outside this view.
            syncLanguageState()
        }
    }

    /// Seed the custom-language reveal from the stored value: shown (pre-filled) when the stored
    /// language isn't one of the presets, hidden otherwise.
    private func syncLanguageState() {
        showingCustomLanguage = !isPresetLanguage(viewModel.summaryLanguage)
        if showingCustomLanguage {
            customLanguageText = viewModel.summaryLanguage
        }
    }

    // MARK: - Transcription

    private var transcriptionGroup: some View {
        SettingsGroup(header: "Transcription") {
            SettingsRow(
                "On-device — Apple Speech",
                description: "Meetings are transcribed entirely on this Mac. Audio never leaves the device."
            ) {
                transcriptionStatusBadge
            }

            transcriptionDetailRow

            SettingsVocabularySection(database: database)
        }
    }

    /// One collapsed badge: "Ready" only when the engine runs AND its model is installed;
    /// "Unavailable" when the engine can't run here. The model-missing / checking / installing
    /// states carry their own affordance in `transcriptionDetailRow`, so they get no top badge.
    @ViewBuilder private var transcriptionStatusBadge: some View {
        if !viewModel.transcriptionEngineAvailable {
            MarginaliaBadge("Unavailable", style: .neutral, scheme: scheme)
        } else if viewModel.transcriptionModelInstalled == true {
            MarginaliaBadge("Ready", style: .success, scheme: scheme)
        }
    }

    /// The extra row shown only when transcription needs the user's attention (engine unavailable,
    /// or its language model isn't installed / is still downloading). On the happy path the
    /// `@ViewBuilder` emits nothing, so `SettingsGroup` renders no second row or divider.
    @ViewBuilder private var transcriptionDetailRow: some View {
        if !viewModel.transcriptionEngineAvailable {
            MarginaliaBanner(
                kind: .error,
                message: "On-device speech transcription isn't available on this Mac.",
                scheme: scheme
            )
            .settingsRowInsets()
        } else if viewModel.transcriptionModelInstalled == false {
            transcriptionModelDownload
                .settingsRowInsets()
        } else if viewModel.transcriptionModelInstalled == nil {
            Text("Checking the on-device speech model…")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                .settingsRowInsets()
        }
    }

    private var transcriptionModelDownload: some View {
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

            if !isInstallingTranscriptionModel {
                Button("Download model") {
                    Task { await viewModel.installTranscriptionModel() }
                }
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
            }
        }
    }

    private var isInstallingTranscriptionModel: Bool {
        if case .installing = viewModel.transcriptionModelInstall {
            return true
        }
        return false
    }

    // MARK: - Summary

    private var summaryGroup: some View {
        SettingsGroup(
            header: "Summary",
            footnote: "On-device Qwen 4B runs fully offline. Claude CLI shells out to your local `claude` — no API key needed."
        ) {
            SettingsRow(
                "Automatic summary",
                description: "Summarize each meeting as soon as the transcript finishes."
            ) {
                Toggle("", isOn: Binding(
                    get: { viewModel.summaryAutomatic },
                    set: { newValue in Task { try? await viewModel.setSummaryAutomatic(newValue) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            SettingsRow("Language") {
                Picker("Language", selection: languageBinding) {
                    ForEach(Self.languageChips, id: \.code) { chip in
                        Text(chip.label).tag(chip.code)
                    }
                    Text("Custom…").tag(Self.customLanguageSentinel)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            if showingCustomLanguage {
                HStack(spacing: MarginaliaSpacing.sm.value) {
                    MarginaliaTextField(
                        text: $customLanguageText,
                        prompt: "Language code (e.g. it, nl)",
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
                .settingsRowInsets()
            }

            SettingsRow("Model") {
                Picker("Model", selection: providerBinding) {
                    ForEach(Self.visibleProviders, id: \.self) { provider in
                        Text(providerLabel(provider)).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            // On-device Qwen runs a single fixed model, so a model override is meaningless there;
            // only show the field for providers that can target a named model (Claude CLI).
            if selectedProvider.allowsModelOverride {
                MarginaliaTextField(
                    text: $modelText,
                    prompt: "Model (optional, e.g. claude-sonnet-4-5)",
                    scheme: scheme
                )
                .onSubmit { Task { try? await viewModel.setSummaryModel(modelText) } }
                .settingsRowInsets()
            }
        }
    }

    private func isPresetLanguage(_ code: String) -> Bool {
        Self.languageChips.contains { $0.code == code }
    }

    /// Menu selection for the language row: a preset code, or the sentinel when the stored value is
    /// custom (or the user chose "Custom…"). Choosing a preset persists it and hides the field;
    /// choosing "Custom…" reveals the code field without clobbering the stored value.
    private var languageBinding: Binding<String> {
        Binding(
            get: {
                if showingCustomLanguage || !isPresetLanguage(viewModel.summaryLanguage) {
                    return Self.customLanguageSentinel
                }
                return viewModel.summaryLanguage
            },
            set: { newValue in
                if newValue == Self.customLanguageSentinel {
                    showingCustomLanguage = true
                    customLanguageText = isPresetLanguage(viewModel.summaryLanguage) ? "" : viewModel.summaryLanguage
                } else {
                    showingCustomLanguage = false
                    Task { try? await viewModel.setSummaryLanguage(newValue) }
                }
            }
        )
    }

    /// The provider currently in effect, coercing any stored value not offered here (e.g. a legacy
    /// `.ollama` selection) to the on-device default so the UI always reflects a valid choice.
    private var selectedProvider: ProviderKind {
        let stored = ProviderKind.from(viewModel.summaryProvider) ?? .mlx
        return Self.visibleProviders.contains(stored) ? stored : .mlx
    }

    private var providerBinding: Binding<ProviderKind> {
        Binding(
            get: { selectedProvider },
            // Persist the canonical `settingID` (e.g. "claude-cli"), NOT `rawValue` ("claudeCLI"):
            // only `settingID` round-trips through `ProviderKind.from(_:)`, which both this picker
            // and the engine use to resolve the stored value.
            set: { newProvider in Task { try? await viewModel.setSummaryProvider(newProvider.settingID) } }
        )
    }

    private func providerLabel(_ provider: ProviderKind) -> String {
        switch provider {
        case .mlx: "Qwen 4B (on-device)"
        case .claudeCLI: "Claude CLI"
        default: provider.rawValue
        }
    }

    // MARK: - API key (dormant unless a visible provider ever requires one)

    private var apiKeyGroup: some View {
        SettingsGroup(header: "API key", footnote: "Never displayed once saved — only presence is shown.") {
            HStack(spacing: MarginaliaSpacing.sm.value) {
                Text(hasStoredAPIKey ? "A key is stored for this provider." : "No key stored.")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                if hasStoredAPIKey {
                    MarginaliaBadge("Stored", style: .success, scheme: scheme)
                }
                Spacer(minLength: 0)
            }
            .settingsRowInsets()

            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
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
            }
            .settingsRowInsets()
        }
    }

    // MARK: - Meeting search

    private var searchGroup: some View {
        SettingsGroup(header: "Meeting search") {
            SettingsRow(
                "Embedder",
                description: "Built-in on-device embeddings — no download."
            ) {
                HStack(spacing: MarginaliaSpacing.xs.value) {
                    Text("Apple (on-device)")
                        .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.marginalia(.accent, in: scheme))
                }
            }

            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                if let summary = viewModel.indexSummary {
                    Text("\(summary.indexedMeetings) \(summary.indexedMeetings == 1 ? "meeting" : "meetings") indexed")
                        .marginaliaTextStyle(.body, in: scheme)
                    Text(
                        "\(summary.chunkCount) \(summary.chunkCount == 1 ? "chunk" : "chunks"), \(summary.embeddedChunkCount) embedded"
                    )
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                } else {
                    Text("No index stats available yet.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }

                SettingsDisabledGroup(availability: viewModel.rebuildIndexAvailability) {
                    Button(viewModel.isRebuildingIndex ? "Rebuilding…" : "Rebuild index") {
                        Task { await viewModel.rebuildIndex() }
                    }
                    .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                    .disabled(viewModel.isRebuildingIndex)
                }
            }
            .settingsRowInsets()
        }
    }
}
