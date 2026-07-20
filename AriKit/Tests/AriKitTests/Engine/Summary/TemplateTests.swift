//
//  TemplateTests.swift — plan §6 Slice F (← templates/types.rs `#[cfg(test)]`).
//
import Foundation
import Testing
@testable import AriKit

struct TemplateTests {
    @Test func validTemplatePassesValidation() throws {
        let template = Template(
            name: "Test Template",
            description: "A test template",
            sections: [
                TemplateSection(title: "Summary", instruction: "Provide a summary", format: "paragraph")
            ]
        )
        try template.validate()
    }

    @Test func emptyNameFailsValidation() {
        let template = Template(name: "", description: "A test template", sections: [])
        #expect(throws: TemplateError.self) { try template.validate() }
    }

    @Test func emptyDescriptionFailsValidation() {
        let template = Template(name: "Test", description: "", sections: [])
        #expect(throws: TemplateError.self) { try template.validate() }
    }

    @Test func emptySectionsFailsValidation() {
        let template = Template(name: "Test", description: "Test", sections: [])
        #expect(throws: TemplateError.self) { try template.validate() }
    }

    @Test func emptySectionTitleFailsValidation() {
        let template = Template(
            name: "Test",
            description: "Test",
            sections: [TemplateSection(title: "", instruction: "Test", format: "paragraph")]
        )
        #expect(throws: TemplateError.self) { try template.validate() }
    }

    @Test func emptySectionInstructionFailsValidation() {
        let template = Template(
            name: "Test",
            description: "Test",
            sections: [TemplateSection(title: "Test", instruction: "", format: "paragraph")]
        )
        #expect(throws: TemplateError.self) { try template.validate() }
    }

    @Test func invalidFormatFailsValidation() {
        let template = Template(
            name: "Test",
            description: "Test",
            sections: [
                TemplateSection(title: "Test", instruction: "Test", format: "invalid")
            ]
        )
        #expect(throws: TemplateError.self) { try template.validate() }
    }

    @Test("valid formats pass validation", arguments: ["paragraph", "list", "string"])
    func validFormatsPassValidation(format: String) throws {
        let template = Template(
            name: "Test",
            description: "Test",
            sections: [TemplateSection(title: "Test", instruction: "Test", format: format)]
        )
        try template.validate()
    }

    @Test func toMarkdownStructureListsAllSectionTitles() {
        let template = Template(
            name: "T",
            description: "D",
            sections: [
                TemplateSection(title: "Summary", instruction: "x", format: "paragraph"),
                TemplateSection(title: "Action Items", instruction: "y", format: "list")
            ]
        )
        let markdown = template.toMarkdownStructure()
        #expect(markdown.hasPrefix("# <Add Title here>\n\n"))
        #expect(markdown.contains("**Summary**\n\n"))
        #expect(markdown.contains("**Action Items**\n\n"))
    }

    @Test func toSectionInstructionsIncludesMainTitleInstruction() {
        let template = Template(
            name: "T",
            description: "D",
            sections: [TemplateSection(title: "Summary", instruction: "Provide a summary", format: "paragraph")]
        )
        let instructions = template.toSectionInstructions()
        #expect(instructions.contains("main title"))
        #expect(instructions.contains("For the 'Summary' section:** Provide a summary."))
    }

    @Test func toSectionInstructionsPrefersItemFormatOverExampleItemFormat() {
        let template = Template(
            name: "T",
            description: "D",
            sections: [
                TemplateSection(
                    title: "Action Items",
                    instruction: "List tasks",
                    format: "list",
                    itemFormat: "| Owner | Task |",
                    exampleItemFormat: "| Should Not Appear |"
                )
            ]
        )
        let instructions = template.toSectionInstructions()
        #expect(instructions.contains("| Owner | Task |"))
        #expect(!instructions.contains("Should Not Appear"))
    }

    @Test func toSectionInstructionsFallsBackToExampleItemFormat() {
        let template = Template(
            name: "T",
            description: "D",
            sections: [
                TemplateSection(
                    title: "Yesterday",
                    instruction: "List work",
                    format: "list",
                    exampleItemFormat: "| Owner | Work |"
                )
            ]
        )
        let instructions = template.toSectionInstructions()
        #expect(instructions.contains("| Owner | Work |"))
    }

    @Test func codableRoundTripsThroughJSON() throws {
        let template = Template(
            name: "T",
            description: "D",
            sections: [
                TemplateSection(
                    title: "Action Items",
                    instruction: "List tasks",
                    format: "list",
                    itemFormat: "| Owner |"
                )
            ]
        )
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(Template.self, from: data)
        #expect(decoded == template)
    }
}
