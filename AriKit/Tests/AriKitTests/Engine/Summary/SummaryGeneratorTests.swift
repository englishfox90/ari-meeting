//
//  SummaryGeneratorTests.swift — plan §6 Slice F (← summary/processor.rs `generate_meeting_summary`,
//  driven with `StubLLMClient` — headless, no network/Store/MLX).
//
import Testing
@testable import AriKit

struct SummaryGeneratorTests {
    static let template = Template(
        name: "Standard Meeting Notes",
        description: "test",
        sections: [
            TemplateSection(title: "Summary", instruction: "Summarize", format: "paragraph")
        ]
    )

    static let shortTranscript = "[00:00] Paul: Let's get started with today's meeting."

    @Test func singlePassIsUsedForCloudProviderRegardlessOfLength() async throws {
        // .claude is never a map-reduce provider, so even a transcript OVER the tiny threshold
        // stays single-pass: only one `generate` call, whose `user` prompt is the raw transcript
        // wrapped once in <transcript_chunks>, not per-chunk summaries. `detectedTranscriptLanguage:
        // "en"` resolves to `.returnEnglish` so no extra English-normalization pass runs.
        let longTranscript = String(repeating: "[00:00] Paul: word word word word word. ", count: 200)
        let client = RecordingStubClient(kind: .claude, cannedResponse: "# Meeting\n\n**Summary**\n\nDone.")
        let result = try await SummaryGenerator.generateMeetingSummary(
            client: client,
            text: longTranscript,
            templateID: "standard_meeting",
            template: Self.template,
            tokenThreshold: 10,
            detectedTranscriptLanguage: "en"
        )
        await #expect(client.generateCallCount == 1)
        #expect(result.chunkCount == 1)
        let lastPrompt = await client.lastUserPrompt
        #expect(lastPrompt?.contains(longTranscript) == true)
    }

    @Test func mapReduceIsUsedForOllamaOverThreshold() async throws {
        // .ollama IS a map-reduce provider; a transcript over the (tiny) threshold triggers
        // chunk -> combine -> final-report, so more than one `generate` call happens.
        let longTranscript = String(repeating: "[00:00] Paul: word word word word word. ", count: 200)
        let client = RecordingStubClient(kind: .ollama, cannedResponse: "chunk summary")
        _ = try await SummaryGenerator.generateMeetingSummary(
            client: client,
            text: longTranscript,
            templateID: "standard_meeting",
            template: Self.template,
            tokenThreshold: 10
        )
        await #expect(client.generateCallCount > 1)
    }

    @Test func mapReduceIsNotUsedForOllamaUnderThreshold() async throws {
        let client = RecordingStubClient(kind: .ollama, cannedResponse: "# Meeting\n\n**Summary**\n\nDone.")
        let result = try await SummaryGenerator.generateMeetingSummary(
            client: client,
            text: Self.shortTranscript,
            templateID: "standard_meeting",
            template: Self.template,
            tokenThreshold: 4000,
            detectedTranscriptLanguage: "en"
        )
        await #expect(client.generateCallCount == 1)
        #expect(result.chunkCount == 1)
    }

    @Test func finalReportPromptIncludesSectionInstructionsAndTemplate() async throws {
        let client = RecordingStubClient(kind: .claude, cannedResponse: "# Meeting\n\n**Summary**\n\nDone.")
        _ = try await SummaryGenerator.generateMeetingSummary(
            client: client,
            text: Self.shortTranscript,
            templateID: "standard_meeting",
            template: Self.template,
            tokenThreshold: 4000,
            detectedTranscriptLanguage: "en"
        )
        let systemPrompt = await client.lastSystemPrompt
        #expect(systemPrompt?.contains("SECTION-SPECIFIC INSTRUCTIONS") == true)
        #expect(systemPrompt?.contains("<template>") == true)
        #expect(systemPrompt?.contains("For the 'Summary' section:") == true)
    }

    @Test func customPromptIsAppendedToFinalUserPrompt() async throws {
        let client = RecordingStubClient(kind: .claude, cannedResponse: "# Meeting\n\n**Summary**\n\nDone.")
        _ = try await SummaryGenerator.generateMeetingSummary(
            client: client,
            text: Self.shortTranscript,
            customPrompt: "Focus on action items only.",
            templateID: "standard_meeting",
            template: Self.template,
            tokenThreshold: 4000,
            detectedTranscriptLanguage: "en"
        )
        let userPrompt = await client.lastUserPrompt
        #expect(userPrompt?.contains("<user_context>") == true)
        #expect(userPrompt?.contains("Focus on action items only.") == true)
    }

    @Test func citationPassIsAppliedToEnglishMarkdown() async throws {
        // The stub returns a summary with a citation that's a near-miss of a real transcript
        // marker — SummaryGenerator must run it through SummaryCitations.applyCitations, snapping
        // it to the real timestamp.
        let transcript = "[01:05] Marcus: I'll own getting the beta build signed off by Friday."
        let client = RecordingStubClient(
            kind: .claude,
            cannedResponse: "- Marcus owns the beta signoff @ref(01:07)"
        )
        let result = try await SummaryGenerator.generateMeetingSummary(
            client: client,
            text: transcript,
            templateID: "standard_meeting",
            template: Self.template,
            tokenThreshold: 4000,
            detectedTranscriptLanguage: "en"
        )
        #expect(result.englishMarkdown.contains("@ref(01:05)"))
        #expect(!result.englishMarkdown.contains("@ref(01:07)"))
    }

    @Test func chunkFailuresAreSkippedNotFatal() async throws {
        // One chunk generation fails (non-cancellation); as long as at least one succeeds, the
        // summary must still complete (← processor.rs:427-434).
        let longTranscript = String(repeating: "[00:00] Paul: word word word word word. ", count: 200)
        let client = FailFirstChunkStubClient(kind: .ollama)
        let result = try await SummaryGenerator.generateMeetingSummary(
            client: client,
            text: longTranscript,
            templateID: "standard_meeting",
            template: Self.template,
            tokenThreshold: 10
        )
        #expect(result.chunkCount >= 1)
    }

    @Test func translateActionProducesTranslatedFinalMarkdownButKeepsEnglishMarkdown() async throws {
        let client = TranslatingStubClient()
        let result = try await SummaryGenerator.generateMeetingSummary(
            client: client,
            text: Self.shortTranscript,
            templateID: "standard_meeting",
            template: Self.template,
            tokenThreshold: 4000,
            summaryLanguage: "fr"
        )
        #expect(result.finalMarkdown == "[TRANSLATED] # Meeting\n\nRésumé.")
        #expect(result.englishMarkdown == "# Meeting\n\nSummary.")
    }
}

/// A stub `LLMClient` that records every call's prompts, for shape assertions.
private actor RecordingStubClient: LLMClient {
    let kind: ProviderKind
    let cannedResponse: String
    private(set) var generateCallCount = 0
    private(set) var lastSystemPrompt: String?
    private(set) var lastUserPrompt: String?

    init(kind: ProviderKind, cannedResponse: String) {
        self.kind = kind
        self.cannedResponse = cannedResponse
    }

    func generate(_ request: LLMRequest) async throws -> String {
        generateCallCount += 1
        lastSystemPrompt = request.system
        lastUserPrompt = request.user
        return cannedResponse
    }
}

/// A stub that fails the FIRST chunk-summarization call, then succeeds on all subsequent calls —
/// exercises the "skip one bad chunk, keep going" path.
private actor FailFirstChunkStubClient: LLMClient {
    let kind: ProviderKind
    private var callCount = 0

    init(kind: ProviderKind) {
        self.kind = kind
    }

    func generate(_ request: LLMRequest) async throws -> String {
        callCount += 1
        if callCount == 1 {
            throw LLMError.requestFailed("simulated transient failure")
        }
        return "chunk summary \(callCount)"
    }
}

/// A stub that returns a distinguishable English summary on the first call, then a
/// distinguishable "translated" summary on the translation-pass call.
private actor TranslatingStubClient: LLMClient {
    let kind: ProviderKind = .claude
    private var callCount = 0

    func generate(_ request: LLMRequest) async throws -> String {
        callCount += 1
        if callCount == 1 {
            return "# Meeting\n\nSummary."
        }
        return "[TRANSLATED] # Meeting\n\nRésumé."
    }
}
