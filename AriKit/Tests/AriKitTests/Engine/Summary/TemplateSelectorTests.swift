//
//  TemplateSelectorTests.swift — plan §6 Slice G (← `ari-engine/src/summary/template_selector.rs`
//  `#[cfg(test)]`, ported 1:1 where the Rust free functions have a direct Swift counterpart, plus
//  an integration-style `suggestTemplate` test driven with `StubLLMClient`).
//
import Testing
@testable import AriKit

@Suite("TemplateSelector — F6 auto-suggest (Slice G)")
struct TemplateSelectorTests {
    private static let sampleIDs = ["standard_meeting", "team_meeting", "one_on_one", "daily_standup"]

    // MARK: - parseSelectedTemplateID (← `parse_selected_template_id`)

    @Test func parsesExactID() {
        #expect(TemplateSelector.parseSelectedTemplateID("team_meeting", validIDs: Self.sampleIDs) == "team_meeting")
    }

    @Test func parsesWithSurroundingNoise() {
        #expect(
            TemplateSelector.parseSelectedTemplateID("  \"one_on_one\".\n", validIDs: Self.sampleIDs) == "one_on_one"
        )
    }

    @Test func parsesIDEmbeddedInProse() {
        #expect(
            TemplateSelector.parseSelectedTemplateID(
                "The best fit is daily_standup here.",
                validIDs: Self.sampleIDs
            ) == "daily_standup"
        )
    }

    @Test func isCaseInsensitive() {
        #expect(
            TemplateSelector.parseSelectedTemplateID("TEAM_MEETING", validIDs: Self.sampleIDs) == "team_meeting"
        )
    }

    @Test func fallsBackToStandardOnGarbage() {
        #expect(
            TemplateSelector.parseSelectedTemplateID("I don't know", validIDs: Self.sampleIDs) == "standard_meeting"
        )
    }

    @Test func fallsBackToFirstWhenNoStandard() {
        let alt = ["team_meeting", "one_on_one"]
        #expect(TemplateSelector.parseSelectedTemplateID("???", validIDs: alt) == "team_meeting")
    }

    // MARK: - defaultSuggestion (← `default_suggestion`)

    @Test func defaultSuggestionPrefersStandardMeeting() {
        let options: [(id: String, name: String, description: String)] = [
            (id: "team_meeting", name: "Team Meeting", description: "d"),
            (id: "standard_meeting", name: "Standard Meeting Notes", description: "d")
        ]
        let suggestion = TemplateSelector.defaultSuggestion(options)
        #expect(suggestion == TemplateSelector.TemplateSuggestion(
            id: "standard_meeting",
            name: "Standard Meeting Notes"
        ))
    }

    @Test func defaultSuggestionFallsBackToFirstWhenNoStandardMeeting() {
        let options: [(id: String, name: String, description: String)] = [
            (id: "team_meeting", name: "Team Meeting", description: "d"),
            (id: "one_on_one", name: "1:1 Meeting", description: "d")
        ]
        let suggestion = TemplateSelector.defaultSuggestion(options)
        #expect(suggestion == TemplateSelector.TemplateSuggestion(id: "team_meeting", name: "Team Meeting"))
    }

    // MARK: - buildTemplateSelectionPrompt (← `build_template_selection_prompt`)

    @Test func promptListsAllOptionsAndWrapsExcerpt() {
        let options: [(id: String, name: String, description: String)] = [
            (id: "team_meeting", name: "Team Meeting", description: "team sync"),
            (id: "one_on_one", name: "1:1 Meeting", description: "manager 1:1")
        ]
        let (system, user) = TemplateSelector.buildTemplateSelectionPrompt(
            options: options,
            excerpt: "hello team",
            speakerCount: nil,
            calendarContext: nil
        )
        #expect(system.contains("meeting classifier"))
        #expect(user.contains("team_meeting: Team Meeting — team sync"))
        #expect(user.contains("one_on_one: 1:1 Meeting — manager 1:1"))
        #expect(user.contains("<transcript>\nhello team\n</transcript>"))
    }

    @Test func promptIncludesSpeakerCountAndCalendarContextWhenPresent() {
        let options = [
            (id: "one_on_one", name: "1:1 Meeting", description: "manager 1:1")
        ]
        let (_, user) = TemplateSelector.buildTemplateSelectionPrompt(
            options: options,
            excerpt: "hello",
            speakerCount: 2,
            calendarContext: "Weekly 1:1 with Jamie"
        )
        #expect(user.contains("Distinct speakers detected: 2"))
        #expect(user.contains("Calendar event context: Weekly 1:1 with Jamie"))
    }

    @Test func promptOmitsSignalsSectionWhenAbsent() {
        let options = [
            (id: "standard_meeting", name: "Standard Meeting Notes", description: "d")
        ]
        let (_, user) = TemplateSelector.buildTemplateSelectionPrompt(
            options: options,
            excerpt: "hello",
            speakerCount: nil,
            calendarContext: nil
        )
        #expect(!user.contains("Additional signals"))
    }

    // MARK: - suggestTemplate integration (← `api_suggest_template_impl`, StubLLMClient-driven)

    @Test("Empty transcript short-circuits to the default suggestion without calling the LLM")
    func emptyTranscriptUsesDefaultWithoutCallingLLM() async {
        let client = RecordingClient(cannedResponse: "team_meeting")
        let suggestion = await TemplateSelector.suggestTemplate(client: client, text: "   ")
        #expect(suggestion.id == "standard_meeting")
        #expect(await client.callCount == 0)
    }

    @Test("A real transcript classifies via the LLM and returns the matching template's name")
    func classifiesViaLLMAndReturnsMatchingName() async {
        let client = RecordingClient(cannedResponse: "daily_standup")
        let suggestion = await TemplateSelector.suggestTemplate(
            client: client,
            text: "Good morning team, let's go around with yesterday/today/blockers."
        )
        #expect(suggestion.id == "daily_standup")
        #expect(suggestion.name == "Daily Standup")
        #expect(await client.callCount == 1)
    }

    @Test("A provider error degrades to the default suggestion rather than throwing")
    func providerErrorDegradesToDefault() async {
        let client = RecordingClient(cannedResponse: "daily_standup", shouldFail: true)
        let suggestion = await TemplateSelector.suggestTemplate(
            client: client,
            text: "Good morning team, let's go around with yesterday/today/blockers."
        )
        #expect(suggestion.id == "standard_meeting")
    }

    @Test("A garbage LLM response degrades to the default suggestion")
    func garbageResponseDegradesToDefault() async {
        let client = RecordingClient(cannedResponse: "no idea what this meeting was")
        let suggestion = await TemplateSelector.suggestTemplate(
            client: client,
            text: "Some ambiguous meeting content."
        )
        #expect(suggestion.id == "standard_meeting")
    }
}

/// A stub `LLMClient` that records call count and can optionally fail, for `suggestTemplate`
/// integration tests.
private actor RecordingClient: LLMClient {
    let kind: ProviderKind = .claude
    private let cannedResponse: String
    private let shouldFail: Bool
    private(set) var callCount = 0

    init(cannedResponse: String, shouldFail: Bool = false) {
        self.cannedResponse = cannedResponse
        self.shouldFail = shouldFail
    }

    func generate(_: LLMRequest) async throws -> String {
        callCount += 1
        if shouldFail {
            throw LLMError.requestFailed("simulated classifier failure")
        }
        return cannedResponse
    }
}
