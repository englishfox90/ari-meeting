//
//  SummaryRunner.swift — the shared "generate a summary" core (docs/plans/
//  swift-meeting-generation-flow.md, Track 1 §0).
//
//  Centralizes the 5-step generate flow so both `MeetingSummaryViewModel` (Track 1) and the later
//  `MeetingProcessingCoordinator` (Track 2) share ONE copy: assemble transcript text → read the
//  configured summary model → resolve a `ProviderConfig` → build an `any LLMClient` →
//  (auto-suggest a template when none is given) → `SummaryService.processTranscript`. No
//  duplicated provider-resolution logic between the two call sites.
//
//  `Sendable` struct (not a class): every stored property is itself `Sendable` (an actor, two
//  `Sendable` existentials, a `Sendable` struct, an optional `URL`, and a `@Sendable` closure), so
//  the compiler-synthesized conformance needs no `@unchecked Sendable`/`nonisolated(unsafe)`.
//
//  No-Fake-State: `transcriptText` never fabricates a transcript — an empty result is honest
//  ("nothing to summarize") and `generate` turns that into an explicit `LLMError.notConfigured`
//  rather than asking the LLM to summarize nothing. `suggestTemplateID` never throws — it degrades
//  to `TemplateSelector.defaultTemplateID` on any failure (no configured model, a bad provider
//  config, a classifier error), matching `TemplateSelector.suggestTemplate`'s own "never blocks
//  summary generation" contract.
//
import AriKit
import Foundation

public struct SummaryRunner: Sendable {
    let database: AppDatabase
    let settings: any SettingsReading
    let secrets: any SecretsReading
    let summaryService: SummaryService
    /// Optional custom-templates directory; `nil` for now (built-ins only — plan §0).
    let customTemplateDirectory: URL?
    /// Injectable for tests; production default constructs a real client via `ProviderFactory`.
    let clientFactory: @Sendable (ProviderConfig) throws -> any LLMClient

    public init(
        database: AppDatabase,
        settings: any SettingsReading,
        secrets: any SecretsReading,
        summaryService: SummaryService,
        customTemplateDirectory: URL? = nil,
        clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = {
            try ProviderFactory.make(config: $0)
        }
    ) {
        self.database = database
        self.settings = settings
        self.secrets = secrets
        self.summaryService = summaryService
        self.customTemplateDirectory = customTemplateDirectory
        self.clientFactory = clientFactory
    }

    /// The transcript text to summarize: speaker-labeled ("Name: text") when at least one speaker
    /// resolves, else the plain concatenation. An empty result is honest — the meeting genuinely
    /// has no transcript text — and `generate` treats it as "nothing to summarize" rather than
    /// fabricating content.
    public func transcriptText(for meetingId: MeetingID) async throws -> String {
        // Summary path: always `[MM:SS] Name: text` (or `[MM:SS] text` when the speaker is
        // unknown). The `[MM:SS]` prefix is load-bearing — the summary prompt promises it and
        // `SummaryCitations` verifies/back-fills `@ref(MM:SS)` against it. The persons-oriented
        // `buildLabeledTranscriptText` deliberately omits timestamps, so it must NOT be reused
        // here (doing so silently disabled reference-badge citations).
        try await LabeledTranscript.buildSummaryTranscriptText(db: database, meetingId: meetingId)
    }

    /// The auto-suggested template id for `text`. Never throws: with no configured summary model
    /// there is no way to classify, so this honestly degrades to
    /// `TemplateSelector.defaultTemplateID` rather than blocking (mirrors
    /// `TemplateSelector.suggestTemplate`'s own contract) — the same degradation applies to any
    /// provider-resolution or client-construction failure along the way.
    public func suggestTemplateID(text: String, speakerCount: Int?) async -> String {
        guard let modelConfig = try? await settings.summaryModelConfig() else {
            return TemplateSelector.defaultTemplateID
        }
        do {
            let providerConfig = try await ProviderConfigResolution.resolve(
                providerKey: modelConfig.providerKey,
                modelName: modelConfig.model,
                settings: settings,
                secrets: secrets
            )
            let client = try clientFactory(providerConfig)
            let suggestion = await TemplateSelector.suggestTemplate(
                client: client,
                text: text,
                speakerCount: speakerCount,
                calendarContext: nil,
                customDirectory: customTemplateDirectory
            )
            return suggestion.id
        } catch {
            return TemplateSelector.defaultTemplateID
        }
    }

    /// Runs the full generate: assembles the transcript, resolves the configured provider/model,
    /// resolves (or auto-suggests, when `templateId == nil`) the template, and delegates
    /// persistence to `SummaryService.processTranscript`. Throws `LLMError.notConfigured` when
    /// there is nothing to summarize or no summary provider/model is configured — both honest,
    /// actionable failures rather than a silently-empty summary.
    public func generate(
        meetingId: MeetingID,
        templateId: String?,
        speakerCount: Int?,
        customInstructions: String = ""
    ) async throws -> Summary {
        let text = try await transcriptText(for: meetingId)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.notConfigured("This meeting has no transcript to summarize.")
        }
        guard let modelConfig = try await settings.summaryModelConfig() else {
            throw LLMError.notConfigured("No summarization model is configured. Choose one in Settings.")
        }

        let resolvedTemplateId: String = if let templateId {
            templateId
        } else {
            await suggestTemplateID(text: text, speakerCount: speakerCount)
        }

        let request = await SummaryProcessRequest(
            meetingId: meetingId,
            text: text,
            modelProviderKey: modelConfig.providerKey,
            modelName: modelConfig.model,
            customPrompt: customInstructions,
            templateId: resolvedTemplateId,
            summaryLanguage: try? database.settings.string(forKey: .summaryLanguage),
            detectedTranscriptLanguage: nil,
            customTemplateDirectory: customTemplateDirectory
        )
        return try await summaryService.processTranscript(request)
    }

    /// Cancels an in-flight generation for `meetingId`, if any (← `SummaryService.cancelSummary`).
    public func cancel(_ meetingId: MeetingID) async -> Bool {
        await summaryService.cancelSummary(meetingId)
    }
}
