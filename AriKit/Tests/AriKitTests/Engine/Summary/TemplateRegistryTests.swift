//
//  TemplateRegistryTests.swift — plan §6 Slice F (← templates/defaults.rs + templates/loader.rs
//  `#[cfg(test)]`).
//
import Foundation
import Testing
@testable import AriKit

struct TemplateRegistryTests {
    @Test func builtinTemplatesContainValidJSON() throws {
        for entry in TemplateRegistry.builtinTemplates() {
            _ = try JSONSerialization.jsonObject(with: Data(entry.json.utf8))
        }
    }

    @Test func getBuiltinTemplateReturnsKnownIDs() {
        #expect(TemplateRegistry.builtinTemplate(id: "daily_standup") != nil)
        #expect(TemplateRegistry.builtinTemplate(id: "standard_meeting") != nil)
        #expect(TemplateRegistry.builtinTemplate(id: "nonexistent") == nil)
    }

    @Test func templateLoadsDailyStandupWithExpectedShape() throws {
        let template = try TemplateRegistry.template(id: "daily_standup")
        #expect(template.name == "Daily Standup")
        #expect(!template.sections.isEmpty)
    }

    @Test func templateLoadsStandardMeetingWithExpectedShape() throws {
        let template = try TemplateRegistry.template(id: "standard_meeting")
        #expect(template.name == "Standard Meeting Notes")
        #expect(!template.sections.isEmpty)
    }

    /// All seven shipped defaults (the two `defaults.rs` built-ins plus the five Rust served only
    /// from its bundled-templates directory) must be inlined, parse as valid JSON, and expose the
    /// display name the old app's picker showed.
    @Test func allSevenDefaultTemplatesLoadWithExpectedNames() throws {
        let expected: [(id: String, name: String)] = [
            ("daily_standup", "Daily Standup"),
            ("standard_meeting", "Standard Meeting Notes"),
            ("one_on_one", "1:1 Meeting"),
            ("project_sync", "Project Sync / Status Update"),
            ("retrospective", "Retrospective (Agile)"),
            ("sales_marketing_client_call", "Client / Sales Meeting"),
            ("team_meeting", "Team Meeting"),
        ]
        #expect(Set(TemplateRegistry.builtinTemplateIDs()) == Set(expected.map(\.id)))
        for entry in expected {
            let template = try TemplateRegistry.template(id: entry.id)
            #expect(template.name == entry.name)
            #expect(!template.sections.isEmpty)
        }
    }

    @Test func templateThrowsForNonexistentID() {
        #expect(throws: TemplateError.self) { try TemplateRegistry.template(id: "nonexistent_template") }
    }

    @Test func listTemplateIDsContainsBothBuiltins() {
        let ids = TemplateRegistry.listTemplateIDs()
        #expect(ids.contains("daily_standup"))
        #expect(ids.contains("standard_meeting"))
    }

    @Test func validateAndParseTemplateThrowsForInvalidJSON() {
        #expect(throws: TemplateError.self) { try TemplateRegistry.validateAndParseTemplate("invalid json") }
    }

    @Test func customDirectoryTemplateOverridesBuiltin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let customJSON = """
        {"name": "Custom Standup", "description": "Overridden", "sections": [
            {"title": "Notes", "instruction": "Write notes", "format": "paragraph"}
        ]}
        """
        try customJSON.write(to: dir.appendingPathComponent("daily_standup.json"), atomically: true, encoding: .utf8)

        let template = try TemplateRegistry.template(id: "daily_standup", customDirectory: dir)
        #expect(template.name == "Custom Standup")
    }

    @Test func customDirectoryDoesNotShadowUnrelatedBuiltin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // No custom file for "standard_meeting" — should still resolve to the bundled default.
        let template = try TemplateRegistry.template(id: "standard_meeting", customDirectory: dir)
        #expect(template.name == "Standard Meeting Notes")
    }

    @Test func listTemplateIDsIncludesCustomDirectoryEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: dir.appendingPathComponent("my_custom_template.json"), atomically: true, encoding: .utf8)

        let ids = TemplateRegistry.listTemplateIDs(customDirectory: dir)
        #expect(ids.contains("my_custom_template"))
        #expect(ids.contains("daily_standup"))
    }
}
