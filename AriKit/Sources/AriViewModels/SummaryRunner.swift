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
//  ("nothing to summarize") and `generate` turns that into an explicit `LLMError.nothingToSummarize`
//  rather than asking the LLM to summarize nothing. `suggestTemplateID` never throws — it degrades
//  to `TemplateSelector.defaultTemplateID` on any failure (no configured model, a bad provider
//  config, a classifier error), matching `TemplateSelector.suggestTemplate`'s own "never blocks
//  summary generation" contract.
//
import AriKit
import Foundation
import os

public struct SummaryRunner: Sendable {
    private static let log = Logger(subsystem: "com.arivo.ari.AriViewModels", category: "summary.runner")

    let database: AppDatabase
    let settings: any SettingsReading
    let secrets: any SecretsReading
    let summaryService: SummaryService
    /// Optional custom-templates directory; `nil` for now (built-ins only — plan §0).
    let customTemplateDirectory: URL?
    /// Injectable for tests; production default constructs a real client via `ProviderFactory`.
    let clientFactory: @Sendable (ProviderConfig) throws -> any LLMClient
    /// The F9 series-ledger reducer (docs/plans/glittery-humming-truffle.md Part 5) — folded
    /// fire-and-forget after a successful summary persist, below. `nil` disables auto-fold (e.g.
    /// in tests that don't care about series), never blocking or failing the summary itself.
    let ledgerReducer: SeriesLedgerReducer?

    /// Cap on the linked event's `notes` snippet folded into `calendarContextString` (← plan
    /// `docs/plans/summary-pipeline-completion.md` Gap 1's "~200 chars" bound).
    private static let calendarContextDescriptionCap = 200

    public init(
        database: AppDatabase,
        settings: any SettingsReading,
        secrets: any SecretsReading,
        summaryService: SummaryService,
        customTemplateDirectory: URL? = nil,
        clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = {
            try ProviderFactory.make(config: $0)
        },
        ledgerReducer: SeriesLedgerReducer? = nil
    ) {
        self.database = database
        self.settings = settings
        self.secrets = secrets
        self.summaryService = summaryService
        self.customTemplateDirectory = customTemplateDirectory
        self.clientFactory = clientFactory
        self.ledgerReducer = ledgerReducer
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
    public func suggestTemplateID(meetingId: MeetingID, text: String, speakerCount: Int?) async -> String {
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
            let calendarContext = await calendarContextString(for: meetingId)
            let suggestion = await TemplateSelector.suggestTemplate(
                client: client,
                text: text,
                speakerCount: speakerCount,
                calendarContext: calendarContext,
                customDirectory: customTemplateDirectory
            )
            return suggestion.id
        } catch {
            return TemplateSelector.defaultTemplateID
        }
    }

    /// A terse, bounded calendar-context one-liner for the template classifier (← plan
    /// `docs/plans/summary-pipeline-completion.md` Gap 1, LOCKED decision: calendar-only, not the
    /// full F3 context block `generate` already injects separately). `nil` when no calendar event
    /// is linked to `meetingId` — No-Fake-State: the classifier just sees no calendar signal,
    /// exactly as before this was wired, rather than a fabricated context string.
    func calendarContextString(for meetingId: MeetingID) async -> String? {
        guard let event = await (try? database.calendarEvents.forMeeting(meetingId))?.first else {
            return nil
        }
        var context = event.title
        if let notes = SummaryContextAssembler.trimmedNonEmpty(event.notes) {
            context += " — \(SummaryContextAssembler.truncateChars(notes, max: Self.calendarContextDescriptionCap))"
        }
        return context
    }

    /// Runs the full generate: assembles the transcript, resolves the configured provider/model,
    /// resolves (or auto-suggests, when `templateId == nil`) the template, and delegates
    /// persistence to `SummaryService.processTranscript`. Throws `LLMError.nothingToSummarize`
    /// when the meeting has no transcript text (benign — a recording that captured no speech) and
    /// `LLMError.notConfigured` when no summary provider/model is configured — both honest and
    /// actionable, rather than a silently-empty summary.
    public func generate(
        meetingId: MeetingID,
        templateId: String?,
        speakerCount: Int?,
        customInstructions: String = ""
    ) async throws -> Summary {
        let text = try await transcriptText(for: meetingId)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.nothingToSummarize
        }
        guard let modelConfig = try await settings.summaryModelConfig() else {
            throw LLMError.notConfigured("No summarization model is configured. Choose one in Settings.")
        }

        let resolvedTemplateId: String = if let templateId {
            templateId
        } else {
            await suggestTemplateID(meetingId: meetingId, text: text, speakerCount: speakerCount)
        }

        // F3 context injection (← the Rust `summary_context_for_meeting` block the first Swift
        // migration dropped): owner + participants + linked calendar event (title/date/description/
        // attendees) + speakers present + series ledger, prepended to any user-supplied custom
        // instructions. Best-effort — an empty block just means the bare transcript, as before.
        let contextBlock = await SummaryContextAssembler(database: database).contextBlock(for: meetingId)
        let customPrompt = Self.mergeCustomPrompt(contextBlock: contextBlock, userInstructions: customInstructions)

        // Detect the transcript language on-device so an already-English meeting skips
        // `SummaryGenerator`'s redundant normalize-English second pass (which otherwise ~doubles
        // generation time). `nil` (short/uncertain/unsupported) keeps the safe `.normalizeEnglish`
        // default — the same behavior as before this was wired.
        let detectedLanguage = TranscriptLanguageDetector.detect(text)

        Self.log.info(
            """
            Generating summary for meeting \(meetingId.rawValue, privacy: .public): \
            provider=\(modelConfig.providerKey, privacy: .public) model=\(modelConfig.model, privacy: .public) \
            template=\(resolvedTemplateId, privacy: .public) transcriptChars=\(text.count, privacy: .public) \
            contextChars=\(contextBlock.count, privacy: .public) speakerCount=\(speakerCount ?? -1, privacy: .public) \
            detectedLanguage=\(detectedLanguage ?? "nil", privacy: .public)
            """
        )
        if contextBlock.isEmpty {
            Self.log.notice(
                "No meeting context assembled for \(meetingId.rawValue, privacy: .public) — summarizing bare transcript (no owner/participants/calendar event linked)."
            )
        }

        let request = await SummaryProcessRequest(
            meetingId: meetingId,
            text: text,
            modelProviderKey: modelConfig.providerKey,
            modelName: modelConfig.model,
            customPrompt: customPrompt,
            templateId: resolvedTemplateId,
            summaryLanguage: try? database.settings.string(forKey: .summaryLanguage),
            detectedTranscriptLanguage: detectedLanguage,
            customTemplateDirectory: customTemplateDirectory
        )

        let clock = ContinuousClock()
        let started = clock.now
        do {
            let summary = try await summaryService.processTranscript(request)
            let elapsed = clock.now - started
            Self.log.info(
                "Summary generated for meeting \(meetingId.rawValue, privacy: .public) in \(elapsed.formatted(), privacy: .public) (\(summary.bodyMarkdown.count, privacy: .public) chars)."
            )

            // F9 auto-fold (full parity with the frozen Rust app's fire-and-forget
            // `series_update_ledger` on summary completion): fold this meeting's fresh summary
            // into its series ledger, if any. Detached + best-effort — logged, never surfaced to
            // the caller, and must never block returning the summary the user is waiting on.
            if let ledgerReducer {
                Task.detached(priority: .utility) {
                    do {
                        try await ledgerReducer.foldMeeting(meetingId: meetingId)
                    } catch {
                        Self.log.error(
                            "Series ledger auto-fold FAILED for meeting \(meetingId.rawValue, privacy: .public): \(String(describing: error), privacy: .public)"
                        )
                    }
                }
            }

            return summary
        } catch {
            let elapsed = clock.now - started
            Self.log.error(
                "Summary generation FAILED for meeting \(meetingId.rawValue, privacy: .public) after \(elapsed.formatted(), privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// Combines the assembled meeting-context block with any user-supplied custom instructions.
    /// Either may be empty; when both are present the context leads and the user's instructions
    /// follow under their own heading, so the model sees the reference context first.
    static func mergeCustomPrompt(contextBlock: String, userInstructions: String) -> String {
        let context = contextBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (context.isEmpty, user.isEmpty) {
        case (true, true): return ""
        case (false, true): return context
        case (true, false): return user
        case (false, false): return context + "\n\n### Additional instructions\n" + user
        }
    }

    /// Cancels an in-flight generation for `meetingId`, if any (← `SummaryService.cancelSummary`).
    public func cancel(_ meetingId: MeetingID) async -> Bool {
        await summaryService.cancelSummary(meetingId)
    }
}
