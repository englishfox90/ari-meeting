//
//  Template.swift — meeting summary template model (plan §2.4, ← templates/types.rs).
//
//  1:1 port of the Rust `Template`/`TemplateSection` model: `validate()`, `toMarkdownStructure()`,
//  and `toSectionInstructions()` reproduce the Rust methods (and error messages) exactly so the
//  LLM-facing prompts stay byte-identical across the port.
//
import Foundation

/// A single section within a `Template` (← `TemplateSection`, `templates/types.rs`).
public struct TemplateSection: Codable, Sendable, Equatable {
    /// Section title (e.g., "Summary", "Action Items").
    public var title: String
    /// Instruction for the LLM on what to extract/include.
    public var instruction: String
    /// Format type: "paragraph", "list", or "string".
    public var format: String
    /// Optional markdown formatting hint for list items (e.g., table structure).
    public var itemFormat: String?
    /// Alternative formatting hint.
    public var exampleItemFormat: String?

    public init(
        title: String,
        instruction: String,
        format: String,
        itemFormat: String? = nil,
        exampleItemFormat: String? = nil
    ) {
        self.title = title
        self.instruction = instruction
        self.format = format
        self.itemFormat = itemFormat
        self.exampleItemFormat = exampleItemFormat
    }

    enum CodingKeys: String, CodingKey {
        case title
        case instruction
        case format
        case itemFormat = "item_format"
        case exampleItemFormat = "example_item_format"
    }
}

/// A complete meeting template (← `Template`, `templates/types.rs`).
public struct Template: Codable, Sendable, Equatable {
    /// Template display name.
    public var name: String
    /// Brief description of the template's purpose.
    public var description: String
    /// List of sections in the template.
    public var sections: [TemplateSection]

    public init(name: String, description: String, sections: [TemplateSection]) {
        self.name = name
        self.description = description
        self.sections = sections
    }

    /// Validates the template structure (← `Template::validate`). Throws `TemplateError.invalid`
    /// carrying the exact Rust error message on the first violation found.
    public func validate() throws {
        if name.isEmpty {
            throw TemplateError.invalid("Template name cannot be empty")
        }
        if description.isEmpty {
            throw TemplateError.invalid("Template description cannot be empty")
        }
        if sections.isEmpty {
            throw TemplateError.invalid("Template must have at least one section")
        }
        for (index, section) in sections.enumerated() {
            if section.title.isEmpty {
                throw TemplateError.invalid("Section \(index) has empty title")
            }
            if section.instruction.isEmpty {
                throw TemplateError.invalid("Section '\(section.title)' has empty instruction")
            }
            switch section.format {
            case "paragraph", "list", "string":
                continue
            default:
                throw TemplateError.invalid(
                    "Section '\(section.title)' has invalid format '\(section.format)'. Must be 'paragraph', 'list', or 'string'"
                )
            }
        }
    }

    /// Generates a clean markdown template structure (← `Template::to_markdown_structure`).
    public func toMarkdownStructure() -> String {
        var markdown = "# <Add Title here>\n\n"
        for section in sections {
            markdown += "**\(section.title)**\n\n"
        }
        return markdown
    }

    /// Generates section-specific instructions for the LLM (← `Template::to_section_instructions`).
    public func toSectionInstructions() -> String {
        var instructions =
            "- **For the main title (`# [AI-Generated Title]`):** Analyze the entire transcript and create a concise, descriptive title for the meeting.\n"

        for section in sections {
            instructions += "- **For the '\(section.title)' section:** \(section.instruction).\n"

            // Item format hint: `item_format` takes precedence over `example_item_format`
            // (← `section.item_format.as_ref().or(section.example_item_format.as_ref())`).
            if let format = section.itemFormat ?? section.exampleItemFormat {
                instructions += "  - Items in this section should follow the format: `\(format)`.\n"
            }
        }

        return instructions
    }
}

/// ← the `Result<_, String>` error surface of `Template::validate` / template loading.
public enum TemplateError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}
