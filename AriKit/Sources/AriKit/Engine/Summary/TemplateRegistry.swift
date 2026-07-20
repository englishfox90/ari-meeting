//
//  TemplateRegistry.swift — bundled default templates + custom-directory loader
//  (plan §2.4, ← templates/defaults.rs + templates/loader.rs).
//
//  Rust bundles the two default templates via `include_str!` against files that physically live
//  in `frontend/src-tauri/templates/`. The `AriKit` package target declares no resource bundle
//  (Package.swift is out of scope for this port), so the JSON is inlined as Swift string constants
//  instead — behaviorally identical to `include_str!` (compiled into the binary, no disk read),
//  just a different embedding mechanism. Keep these byte-identical to the Rust-bundled JSON files.
//
import Foundation

public enum TemplateRegistry {
    /// ← `frontend/src-tauri/templates/daily_standup.json` (`defaults.rs::DAILY_STANDUP`).
    public static let dailyStandupJSON = """
    {
      "name": "Daily Standup",
      "description": "Time-boxed daily updates for engineering/product teams.",
      "sections": [
        {
          "title": "Date",
          "instruction": "Extract the meeting date in YYYY-MM-DD format only if explicitly stated in the transcript; otherwise leave blank",
          "format": "string"
        },
        {
          "title": "Attendees",
          "instruction": "List each participant named in the transcript",
          "format": "list"
        },
        {
          "title": "Yesterday",
          "instruction": "For each participant, list what they said they completed yesterday, as short bullets",
          "format": "list",
          "example_item_format": "| **Owner** | **Completed Work** |\\n| --- | --- |"
        },
        {
          "title": "Today",
          "instruction": "For each participant, list the work they said they plan to do today, as short bullets",
          "format": "list",
          "example_item_format": "| **Owner** | **Planned Work** |\\n| --- | --- |"
        },
        {
          "title": "Blockers",
          "instruction": "List any impediments raised, with the owner and impact only if actually stated; otherwise leave the cell blank",
          "format": "list",
          "item_format": "| **Owner** | **Blocker** | Impact |\\n| --- | --- | --- |"
        },
        {
          "title": "Notes",
          "instruction": "Capture any announcements or quick notes mentioned that don't fit the sections above; leave blank if none",
          "format": "paragraph"
        }
      ]
    }
    """

    /// ← `frontend/src-tauri/templates/standard_meeting.json` (`defaults.rs::STANDARD_MEETING`).
    public static let standardMeetingJSON = """
    {
      "name": "Standard Meeting Notes",
      "description": "A standard template for general meetings, focusing on key outcomes and actions.",
      "sections": [
        {
          "title": "Summary",
          "instruction": "Provide a brief, one-paragraph executive summary of the entire meeting.",
          "format": "paragraph"
        },
        {
          "title": "Key Decisions",
          "instruction": "List the most important decisions made during the meeting.",
          "format": "list"
        },
        {
          "title": "Action Items",
          "instruction": "List all assigned tasks with their owner and due date. Only include an owner or due date if it was actually stated; otherwise leave the cell blank (do not write 'None'). In the Ref column, cite the moment the task was assigned as @ref(MM:SS) — for example @ref(01:05) — whenever that moment is identifiable in the transcript; otherwise leave the cell blank.",
          "format": "list",
          "item_format": "| **Owner** | Task | Due | Ref |\\n| --- | --- | --- | --- |"
        },
        {
          "title": "Discussion Highlights",
          "instruction": "Summarize the main topics of discussion, key arguments, and important insights.",
          "format": "paragraph"
        }
      ]
    }
    """

    /// ← `get_builtin_templates` (`defaults.rs`).
    public static func builtinTemplates() -> [(id: String, json: String)] {
        [("daily_standup", dailyStandupJSON), ("standard_meeting", standardMeetingJSON)]
    }

    /// ← `get_builtin_template` (`defaults.rs`).
    public static func builtinTemplate(id: String) -> String? {
        switch id {
        case "daily_standup": dailyStandupJSON
        case "standard_meeting": standardMeetingJSON
        default: nil
        }
    }

    /// ← `list_builtin_template_ids` (`defaults.rs`).
    public static func builtinTemplateIDs() -> [String] {
        ["daily_standup", "standard_meeting"]
    }

    /// Parses and validates raw template JSON (← `validate_and_parse_template`, `loader.rs`).
    public static func validateAndParseTemplate(_ jsonContent: String) throws -> Template {
        let template: Template
        do {
            template = try JSONDecoder().decode(Template.self, from: Data(jsonContent.utf8))
        } catch {
            throw TemplateError.invalid("Failed to parse template JSON: \(error)")
        }
        try template.validate()
        return template
    }

    /// Loads a template by identifier (← `get_template`, `loader.rs`), falling back:
    /// 1. `customDirectory/<id>.json` (← the user's custom-templates directory — path resolution
    ///    is the app target's job; this never hardcodes a path, matching the plan).
    /// 2. The bundled built-in template.
    /// 3. Throws `TemplateError.invalid` (← "Template '{id}' not found. Available templates: …").
    public static func template(id: String, customDirectory: URL? = nil) throws -> Template {
        if let customDirectory, let content = loadCustomTemplate(id: id, directory: customDirectory) {
            return try validateAndParseTemplate(content)
        }
        if let builtin = builtinTemplate(id: id) {
            return try validateAndParseTemplate(builtin)
        }
        let available = listTemplateIDs(customDirectory: customDirectory).joined(separator: ", ")
        throw TemplateError.invalid("Template '\(id)' not found. Available templates: \(available)")
    }

    /// ← `list_template_ids` (`loader.rs`), minus the "bundled app resources" tier (folded into
    /// the built-in constants above since this port has no resource bundle to distinguish).
    public static func listTemplateIDs(customDirectory: URL? = nil) -> [String] {
        var ids = Set(builtinTemplateIDs())
        if let customDirectory,
           let entries = try? FileManager.default.contentsOfDirectory(
               at: customDirectory,
               includingPropertiesForKeys: nil
           ) {
            for entry in entries where entry.pathExtension == "json" {
                ids.insert(entry.deletingPathExtension().lastPathComponent)
            }
        }
        return ids.sorted()
    }

    private static func loadCustomTemplate(id: String, directory: URL) -> String? {
        let path = directory.appendingPathComponent("\(id).json")
        return try? String(contentsOf: path, encoding: .utf8)
    }
}
