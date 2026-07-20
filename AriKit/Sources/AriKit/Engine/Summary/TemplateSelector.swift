//
//  TemplateSelector.swift — F6 automatic template selection (plan §2.1/§5 Slice G, ←
//  `ari-engine/src/summary/template_selector.rs`).
//
//  Classifies a transcript against the available templates and returns the best-fitting
//  `template_id`, run once just before summary generation so the summary is shaped by the *kind*
//  of meeting without the user picking a template. Never hard-fails: any error (no templates,
//  empty transcript, a bad/garbage LLM response) degrades to `standard_meeting` rather than
//  blocking summary generation (← `template_selector.rs`'s doc comment).
//
//  Unlike the Rust version, this port takes an already-constructed `any LLMClient` rather than
//  re-resolving provider/settings itself (`resolve_model`, `template_selector.rs:144-193`) — that
//  resolution is `SummaryService`'s job (§9(1)'s injected `SettingsReading`/`SecretsReading`
//  seam); duplicating it here would be a second, drifting copy of the same logic. The caller
//  builds one client (via `ProviderFactory`) and can hand it to both `TemplateSelector` and
//  `SummaryGenerator`.
//
import Foundation

public enum TemplateSelector {
    /// Meeting type is almost always evident early (greetings, agenda, roll-call), so a bounded
    /// prefix keeps classification cheap and inside local-model context (← `MAX_CLASSIFY_CHARS`).
    static let maxClassifyChars = 4000

    /// Safe fallback when nothing else fits or the classifier is unavailable (← `DEFAULT_TEMPLATE_ID`).
    static let defaultTemplateID = "standard_meeting"

    /// The auto-selected template (← `TemplateSuggestion`).
    public struct TemplateSuggestion: Sendable, Equatable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// ← `api_suggest_template_impl`. Never throws — every failure path degrades to the default
    /// suggestion so summary generation is never blocked on the classifier.
    public static func suggestTemplate(
        client: any LLMClient,
        text: String,
        speakerCount: Int? = nil,
        calendarContext: String? = nil,
        customDirectory: URL? = nil
    ) async -> TemplateSuggestion {
        let options = templateOptions(customDirectory: customDirectory)
        guard !options.isEmpty else {
            return TemplateSuggestion(id: defaultTemplateID, name: "Standard Meeting Notes")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, options.count > 1 else {
            return defaultSuggestion(options)
        }

        let excerpt = String(trimmed.prefix(maxClassifyChars))
        let (system, user) = buildTemplateSelectionPrompt(
            options: options,
            excerpt: excerpt,
            speakerCount: speakerCount,
            calendarContext: calendarContext
        )

        let raw: String
        do {
            raw = try await client.generate(LLMRequest(system: system, user: user, maxTokens: 32, temperature: 0.0))
        } catch {
            return defaultSuggestion(options)
        }

        let validIDs = options.map(\.id)
        let selectedID = parseSelectedTemplateID(raw, validIDs: validIDs)
        let name = options.first(where: { $0.id == selectedID })?.name ?? selectedID
        return TemplateSuggestion(id: selectedID, name: name)
    }

    // MARK: - Template options (← `templates::list_templates`)

    static func templateOptions(
        customDirectory: URL?
    ) -> [(id: String, name: String, description: String)] {
        TemplateRegistry.listTemplateIDs(customDirectory: customDirectory).compactMap { id in
            guard let template = try? TemplateRegistry.template(id: id, customDirectory: customDirectory) else {
                return nil
            }
            return (id: id, name: template.name, description: template.description)
        }
    }

    // MARK: - Prompt building (← `build_template_selection_prompt`)

    static func buildTemplateSelectionPrompt(
        options: [(id: String, name: String, description: String)],
        excerpt: String,
        speakerCount: Int?,
        calendarContext: String?
    ) -> (system: String, user: String) {
        let system = "You are a meeting classifier. From the list of templates, choose the single one that best fits the meeting transcript. Respond with ONLY the template id exactly as written in the list — no quotes, no punctuation, no explanation. If none clearly fits, respond with \"standard_meeting\"."

        var optionsBlock = ""
        for option in options {
            optionsBlock += "- \(option.id): \(option.name) — \(option.description)\n"
        }

        var signalsBlock = ""
        if let speakerCount {
            signalsBlock += "- Distinct speakers detected: \(speakerCount)\n"
        }
        if let calendarContext, !calendarContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            signalsBlock += "- Calendar event context: \(calendarContext)\n"
        }
        let signalsSection = signalsBlock.isEmpty ? "" : "\nAdditional signals:\n\(signalsBlock)"

        let user = "Available templates (id: name — description):\n\(optionsBlock)\nTranscript excerpt:\n<transcript>\n\(excerpt)\n</transcript>\(signalsSection)\n\nRespond with exactly one template id from the list above."

        return (system, user)
    }

    // MARK: - Response parsing (← `parse_selected_template_id`)

    /// Maps a raw model response to a valid template id. Tolerant of extra prose, quotes, and
    /// casing; falls back to `standard_meeting` (or the first template) when the response names
    /// nothing valid.
    static func parseSelectedTemplateID(_ response: String, validIDs: [String]) -> String {
        let trimSet: Set<Character> = ["\"", "'", "`", ".", ":"]
        var cleaned = Substring(response)
        while let first = cleaned.first, trimSet.contains(first) || first.isWhitespace {
            cleaned.removeFirst()
        }
        while let last = cleaned.last, trimSet.contains(last) || last.isWhitespace {
            cleaned.removeLast()
        }
        let lowered = cleaned.lowercased()

        // Exact id match wins.
        if let hit = validIDs.first(where: { $0.lowercased() == lowered }) {
            return hit
        }

        // Otherwise, the model may have wrapped the id in extra words. No template id is a
        // substring of another, so a contains-check is unambiguous here.
        if let hit = validIDs.first(where: { lowered.contains($0.lowercased()) }) {
            return hit
        }

        return validIDs.first(where: { $0 == defaultTemplateID }) ?? validIDs.first ?? defaultTemplateID
    }

    // MARK: - Default suggestion (← `default_suggestion`)

    static func defaultSuggestion(_ options: [(id: String, name: String, description: String)]) -> TemplateSuggestion {
        if let match = options.first(where: { $0.id == defaultTemplateID }) {
            return TemplateSuggestion(id: match.id, name: match.name)
        }
        if let first = options.first {
            return TemplateSuggestion(id: first.id, name: first.name)
        }
        return TemplateSuggestion(id: defaultTemplateID, name: "Standard Meeting Notes")
    }
}
