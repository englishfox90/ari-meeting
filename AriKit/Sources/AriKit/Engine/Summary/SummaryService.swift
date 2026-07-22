//
//  SummaryService.swift — the summary orchestration (plan §2.4, Slice G, ← the Rust
//  `SummaryService::process_transcript_background`, `ari-engine/src/summary/service.rs:323-677`).
//
//  Resolves provider/API-key/endpoint/token-threshold (`service.rs:344-471`), loads the template,
//  generates via `SummaryGenerator`, and persists the result through `AppDatabase` repositories
//  only (never a raw SQLite handle — plan principle 3). Cancellation runs through
//  `TaskCancellationCoordinator` (§3) rather than the Rust module-static registry.
//
//  ⚠️ Decision (§4/§9(2)): the Rust translation-cache JSON blob (`summary_processes.result`'s
//  `english_cache`, `service.rs:56,166-219`) is DROPPED. This port always regenerates pass 1 fresh
//  and persists only the final English/target-language body + `provider`/`model`/`templateId`
//  provenance (`Summary`, `SummaryRecord`) — translations are recomputed on demand.
//
//  No partial DB write on cancellation: every write (`db.meetings.upsert`, `db.summaries.upsert`)
//  happens only after `SummaryGenerator.generateMeetingSummary` returns successfully — a
//  cancellation anywhere before that point (cooperative `Task.checkCancellation()`, mirrored inside
//  `SummaryGenerator` itself) unwinds through `runGeneration` without touching the Store.
//
import Foundation

/// ← the explicit arguments to `process_transcript_background` (`service.rs:323-333`) — the
/// caller (app/UI layer) has already resolved `modelProviderKey`/`modelName` (e.g. from its own
/// settings UI), same as Rust's frontend-supplied `model_provider`/`model_name` strings.
public struct SummaryProcessRequest: Sendable {
    public var meetingId: MeetingID
    public var text: String
    /// The raw settings-lookup key (e.g. `"openai"`, `"ollama"`) — parsed into a `ProviderKind`
    /// via `ProviderKind.from(_:)` and also used verbatim as the `SecretsReading`/provenance key.
    public var modelProviderKey: String
    public var modelName: String
    public var customPrompt: String
    public var templateId: String
    public var summaryLanguage: String?
    public var detectedTranscriptLanguage: String?
    /// Optional custom-templates directory (← `TemplateRegistry.template(id:customDirectory:)`).
    /// Path resolution stays the app target's job; this never hardcodes a path.
    public var customTemplateDirectory: URL?

    public init(
        meetingId: MeetingID,
        text: String,
        modelProviderKey: String,
        modelName: String,
        customPrompt: String = "",
        templateId: String,
        summaryLanguage: String? = nil,
        detectedTranscriptLanguage: String? = nil,
        customTemplateDirectory: URL? = nil
    ) {
        self.meetingId = meetingId
        self.text = text
        self.modelProviderKey = modelProviderKey
        self.modelName = modelName
        self.customPrompt = customPrompt
        self.templateId = templateId
        self.summaryLanguage = summaryLanguage
        self.detectedTranscriptLanguage = detectedTranscriptLanguage
        self.customTemplateDirectory = customTemplateDirectory
    }
}

public struct SummaryService: Sendable {
    private let db: AppDatabase
    private let settings: any SettingsReading
    private let secrets: any SecretsReading
    private let cancellation: TaskCancellationCoordinator
    private let clientFactory: @Sendable (ProviderConfig) throws -> any LLMClient

    public init(
        db: AppDatabase,
        settings: any SettingsReading,
        secrets: any SecretsReading,
        cancellation: TaskCancellationCoordinator,
        clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = {
            try ProviderFactory.make(config: $0)
        }
    ) {
        self.db = db
        self.settings = settings
        self.secrets = secrets
        self.cancellation = cancellation
        self.clientFactory = clientFactory
    }

    /// ← `SummaryService::cancel_summary`. Returns `true` if an in-flight generation for
    /// `meetingId` was found and cancelled.
    public func cancelSummary(_ meetingId: MeetingID) async -> Bool {
        await cancellation.cancel(meetingId)
    }

    /// ← `process_transcript_background`. Runs the generation as a child `Task` registered with
    /// the `TaskCancellationCoordinator` for the duration of the call, so a concurrent
    /// `cancelSummary(meetingId)` can cancel it; the registration is always cleaned up
    /// (← `cleanup_cancellation_token`, "regardless of outcome", `service.rs:564-565`).
    public func processTranscript(_ request: SummaryProcessRequest) async throws -> Summary {
        let generationTask = Task<Summary, Error> {
            try await runGeneration(request)
        }
        await cancellation.register(request.meetingId) { generationTask.cancel() }

        do {
            let summary = try await generationTask.value
            await cancellation.unregister(request.meetingId)
            return summary
        } catch {
            await cancellation.unregister(request.meetingId)
            // ← `e.contains("cancelled")` (`service.rs:667`): both the raw Swift-concurrency
            // `CancellationError` (from `Task.checkCancellation()`) and an `LLMError.cancelled`
            // bubbled up from `SummaryGenerator`/a conformer normalize to the same error here.
            if error is CancellationError {
                throw LLMError.cancelled
            }
            throw error
        }
    }

    // MARK: - Generation

    private func runGeneration(_ request: SummaryProcessRequest) async throws -> Summary {
        try Task.checkCancellation()

        let config = try await ProviderConfigResolution.resolve(
            providerKey: request.modelProviderKey,
            modelName: request.modelName,
            settings: settings,
            secrets: secrets
        )
        let providerKind = config.kind

        try Task.checkCancellation()

        let tokenThreshold = await resolveTokenThreshold(providerKind: providerKind, modelName: request.modelName)

        let template: Template
        do {
            template = try TemplateRegistry.template(
                id: request.templateId,
                customDirectory: request.customTemplateDirectory
            )
        } catch {
            throw LLMError.notConfigured("Failed to load template '\(request.templateId)': \(error)")
        }

        let client = try clientFactory(config)

        try Task.checkCancellation()

        let result = try await SummaryGenerator.generateMeetingSummary(
            client: client,
            text: request.text,
            customPrompt: request.customPrompt,
            templateID: request.templateId,
            template: template,
            tokenThreshold: tokenThreshold,
            summaryLanguage: request.summaryLanguage,
            detectedTranscriptLanguage: request.detectedTranscriptLanguage
        )

        try Task.checkCancellation()

        return try await persist(result: result, request: request)
    }

    // MARK: - Settings resolution (← service.rs:344-471)

    //
    // Provider/API-key/Custom-OpenAI-config resolution now lives in the shared
    // `ProviderConfigResolution.resolve(...)` helper (Track H locked decision §6-7) — this
    // section keeps only the token-threshold resolution, which stays Summary-specific.

    /// ← `service.rs:424-471`: the per-provider token-threshold resolution, reserving 300 tokens
    /// for prompt overhead on the two dynamic-context paths.
    private func resolveTokenThreshold(providerKind: ProviderKind, modelName: String) async -> Int {
        switch providerKind {
        case .ollama:
            if let contextSize = await settings.ollamaContextSize(forModel: modelName) {
                return max(contextSize - 300, 0)
            }
            return 4000
        case .mlx:
            if let contextSize = await settings.mlxContextSize(forModel: modelName) {
                return max(contextSize - 300, 0)
            }
            return 1748
        case .appleFoundation:
            // FoundationModels has a ~4k-token context window; reserve overhead so long
            // transcripts chunk (paired with `SummaryGenerator`'s map-reduce gate).
            return 3500
        case .openAI, .claude, .groq, .openRouter, .customOpenAI, .claudeCLI:
            // Cloud providers handle large contexts automatically — effectively unlimited for
            // single-pass processing.
            return 100_000
        }
    }

    // MARK: - Persistence (← service.rs:567-663, repositories-only)

    private func persist(result: SummaryGenerationResult, request: SummaryProcessRequest) async throws -> Summary {
        // Critical write first: the already-generated summary body must never be discarded by a
        // failure in the best-effort meeting-table update below (← service.rs:630-632, "Best
        // effort — a failure here must not fail the summary"; Rust's
        // `SummaryProcessesRepository::update_process_completed` — the body write — runs and
        // succeeds/fails independently of the provenance write that follows it).
        let existing = try await db.summaries.forMeeting(request.meetingId)
        let now = Date()
        let summary = Summary(
            id: existing?.id ?? SummaryID(UUID().uuidString),
            meetingId: request.meetingId,
            bodyMarkdown: result.finalMarkdown,
            provider: request.modelProviderKey,
            model: request.modelName,
            templateId: request.templateId,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try await db.summaries.upsert(summary)

        // Best-effort meeting title-rename + provenance (← `update_summary_provenance`,
        // `service.rs:632-645`): a failure here must not discard the already-persisted summary
        // above — log-and-continue, matching Rust's warn!-and-continue behavior.
        do {
            if var meeting = try await db.meetings.find(request.meetingId) {
                if let name = Chunking.extractMeetingName(fromMarkdown: result.finalMarkdown), !name.isEmpty,
                   Self.isAutomaticMeetingTitle(meeting.title) {
                    meeting.title = name
                }
                meeting.summaryProvider = request.modelProviderKey
                meeting.summaryModel = request.modelName
                try await db.meetings.upsert(meeting)
            }
        } catch {
            // Intentionally swallowed: provenance/title-rename is best-effort only. Mirrors
            // Rust's `warn!` on `update_summary_provenance`/`update_summary_template` failure.
        }

        return summary
    }

    // MARK: - Auto-title rename gate (← `is_automatic_meeting_title`, `service.rs:58-85`)

    /// Whether `title` looks like an app-assigned placeholder (never a user's own title) — the
    /// gate that decides whether the generated meeting name is allowed to rename the meeting.
    static func isAutomaticMeetingTitle(_ rawTitle: String) -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Untitled meeting" is the Swift `RecordingSession` default for an un-named recording
        // (RecordingSession.swift) — an app-assigned placeholder just like the Rust-era
        // "New Meeting"/"+ New Call". Without it the AI-generated title never replaced the
        // placeholder, so freshly recorded meetings kept showing "Untitled meeting".
        if title == "New Meeting" || title == "+ New Call" || title == "Untitled meeting" {
            return true
        }
        guard title.hasPrefix("Meeting ") else {
            return false
        }
        let timestamp = String(title.dropFirst("Meeting ".count))
        let bytes = Array(timestamp.utf8)

        let separatorsMatch: Bool
        switch bytes.count {
        case 17:
            // Frontend default: DD_MM_YY_HH_MM_SS
            separatorsMatch = [2, 5, 8, 11, 14].allSatisfy { bytes[$0] == UInt8(ascii: "_") }
        case 19:
            // Native fallback: YYYY-MM-DD_HH-MM-SS
            let expectations: [(index: Int, separator: UInt8)] = [
                (4, UInt8(ascii: "-")), (7, UInt8(ascii: "-")), (10, UInt8(ascii: "_")),
                (13, UInt8(ascii: "-")), (16, UInt8(ascii: "-"))
            ]
            separatorsMatch = expectations.allSatisfy { bytes[$0.index] == $0.separator }
        default:
            separatorsMatch = false
        }

        guard separatorsMatch else {
            return false
        }

        // ← `.filter(is_ascii_alphanumeric).all(is_ascii_digit)`: every alphanumeric byte must be
        // a digit (non-alphanumeric separator bytes are skipped, not required to be digits).
        return bytes.allSatisfy { byte in
            let isAsciiAlnum = (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            guard isAsciiAlnum else {
                return true
            }
            return byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
    }
}
