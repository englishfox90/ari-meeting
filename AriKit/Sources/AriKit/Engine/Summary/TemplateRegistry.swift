//
//  TemplateRegistry.swift — bundled default templates + custom-directory loader
//  (plan §2.4, ← templates/defaults.rs + templates/loader.rs).
//
//  Rust ships SEVEN default templates from `frontend/src-tauri/templates/`: two are embedded via
//  `include_str!` (`defaults.rs`) and all seven are also loaded from that directory at runtime via
//  the bundled-templates tier (`loader.rs::list_template_ids`) — which is why the old app's picker
//  lists all seven. The `AriKit` package target declares no resource bundle (Package.swift is out
//  of scope for this port), so every one of the seven is inlined as a Swift string constant here —
//  behaviorally identical to `include_str!` (compiled into the binary, no disk read), just a
//  different embedding mechanism. Keep these byte-identical to the Rust template JSON files.
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

    /// ← `frontend/src-tauri/templates/one_on_one.json` (bundled-directory tier, `loader.rs`).
    public static let oneOnOneJSON = """
    {
      "name": "1:1 Meeting",
      "description": "One-on-one between a manager and a team member: check-in, discussion, feedback, growth, and follow-ups.",
      "sections": [
        {
          "title": "Check-in",
          "instruction": "Summarize the opening check-in: how the person said they are doing and any mood, workload, or wellbeing signals they explicitly expressed. Capture only what was actually said, not inferred",
          "format": "paragraph"
        },
        {
          "title": "Discussion Topics",
          "instruction": "Summarize each topic discussed, capturing the key points for each",
          "format": "list",
          "item_format": "| **Topic** | **Key Points** |\\n| --- | --- |"
        },
        {
          "title": "Wins & Progress",
          "instruction": "Capture accomplishments, progress, and positives the person shared since the last conversation",
          "format": "list"
        },
        {
          "title": "Challenges & Blockers",
          "instruction": "Capture difficulties, blockers, or concerns the person raised, with the support they asked for if stated",
          "format": "list",
          "item_format": "| **Challenge** | **Support Needed** |\\n| --- | --- |"
        },
        {
          "title": "Feedback Exchanged",
          "instruction": "Summarize feedback given in either direction (manager to team member or team member to manager). Attribute who gave the feedback. Include only feedback actually voiced in the conversation",
          "format": "list",
          "item_format": "| **From** | **Feedback** |\\n| --- | --- |"
        },
        {
          "title": "Growth & Development",
          "instruction": "Capture any discussion of career goals, skills, learning, or development the person wants to pursue",
          "format": "paragraph"
        },
        {
          "title": "Action Items",
          "instruction": "List agreed follow-up tasks with their owner and due date. Only include an owner or due date if it was actually stated; otherwise leave the cell blank (do not write 'None'). In the Ref column, cite the moment the task was agreed as @ref(MM:SS) — for example @ref(01:05) — whenever clearly identifiable in the transcript; otherwise leave the cell blank",
          "format": "list",
          "item_format": "| **Owner** | **Task** | **Due Date** | **Ref** |\\n| --- | --- | --- | --- |"
        },
        {
          "title": "Follow-ups for Next 1:1",
          "instruction": "Note topics or open threads to revisit at the next one-on-one",
          "format": "list"
        }
      ]
    }
    """

    /// ← `frontend/src-tauri/templates/project_sync.json` (bundled-directory tier, `loader.rs`).
    public static let projectSyncJSON = """
    {
      "name": "Project Sync / Status Update",
      "description": "Weekly or bi-weekly project status meeting focusing on milestones and risks.",
      "sections": [
        {
          "title": "Milestones & Status",
          "instruction": "List each project milestone discussed, with its current status and estimated completion date, using only what was stated.",
          "format": "list",
          "item_format": "| **Milestone** | **Status** | **ETA** |\\n| --- | --- | --- |"
        },
        {
          "title": "Progress Summary",
          "instruction": "Write a short paragraph summarizing progress made since the last sync, based only on what was discussed.",
          "format": "paragraph"
        },
        {
          "title": "Top Risks & Mitigations",
          "instruction": "List the top risks raised, with impact level, mitigation plan, and owner, only where each was actually stated; otherwise leave the cell blank.",
          "format": "list",
          "item_format": "| **Risk** | **Impact** | **Mitigation** | **Owner** |\\n| --- | --- | --- | --- |"
        },
        {
          "title": "Key Decisions",
          "instruction": "List the decisions made in this meeting with their rationale if stated. In the Ref column, cite the moment the decision was made as @ref(MM:SS) — for example @ref(01:05) — whenever that moment is identifiable in the transcript; otherwise leave the cell blank.",
          "format": "list",
          "item_format": "| **Decision** | **Rationale** | **Ref** |\\n| --- | --- | --- |"
        },
        {
          "title": "Action Items",
          "instruction": "List assigned tasks with owner, due date, priority, and status. Only include a field if it was actually stated; otherwise leave the cell blank (do not write 'None'). In the Ref column, cite the moment the task was assigned as @ref(MM:SS) — for example @ref(01:05) — whenever clearly identifiable; otherwise leave blank.",
          "format": "list",
          "item_format": "| **Owner** | **Task** | **Due Date** | **Priority** | **Status** | **Ref** |\\n| --- | --- | --- | --- | --- | --- |"
        },
        {
          "title": "Related Documents",
          "instruction": "List any documents, tickets, or designs referenced by name or link in the transcript, with their type (e.g. doc, ticket, design). Only include documents actually mentioned.",
          "format": "list",
          "item_format": "| **Document Title** | **URL** | **Type** |\\n| --- | --- | --- |"
        }
      ]
    }
    """

    /// ← `frontend/src-tauri/templates/retrospective.json` (bundled-directory tier, `loader.rs`).
    public static let retrospectiveJSON = """
    {
      "name": "Retrospective (Agile)",
      "description": "Sprint retrospective template for continuous improvement.",
      "sections": [
        {
          "title": "Sprint",
          "instruction": "Extract the sprint name/number only if explicitly stated in the transcript; otherwise leave blank. Do not restate the meeting date or attendee list, which are already shown elsewhere",
          "format": "string"
        },
        {
          "title": "Start Doing",
          "instruction": "List actions or experiments the team proposed to start next sprint, with the proposer if stated",
          "format": "list",
          "item_format": "| **Idea** | **Proposer** |\\n| --- | --- |"
        },
        {
          "title": "Stop Doing",
          "instruction": "List practices the team proposed to stop, with the reason if stated",
          "format": "list",
          "item_format": "| **Practice** | **Reason** |\\n| --- | --- |"
        },
        {
          "title": "Continue Doing",
          "instruction": "List practices the team agreed to keep, with supporting notes if stated",
          "format": "list",
          "item_format": "| **Practice** | **Notes** |\\n| --- | --- |"
        },
        {
          "title": "Action Items",
          "instruction": "List concrete follow-up experiments with owner, due date, and success metric, only where each was actually stated; otherwise leave the cell blank (do not write 'None'). In the Ref column, cite the moment the item was agreed as @ref(MM:SS) — for example @ref(01:05) — whenever clearly identifiable in the transcript; otherwise leave the cell blank",
          "format": "list",
          "item_format": "| **Owner** | **Task** | **Due Date** | **Success Metric** | **Ref** |\\n| --- | --- | --- | --- | --- |"
        },
        {
          "title": "Notes & Votes",
          "instruction": "Summarize the discussion and note any top-voted items, based only on what was said",
          "format": "paragraph"
        }
      ]
    }
    """

    /// ← `frontend/src-tauri/templates/sales_marketing_client_call.json` (bundled-directory tier, `loader.rs`).
    public static let salesMarketingClientCallJSON = """
    {
      "name": "Client / Sales Meeting",
      "description": "Capture client goals, deliverables, and next steps.",
      "sections": [
        {
          "title": "Client Goals & Success Criteria",
          "instruction": "Summarize what the client said they want to achieve and how they said success will be measured, based only on what was stated",
          "format": "paragraph"
        },
        {
          "title": "Agreed Deliverables",
          "instruction": "List deliverables discussed, with owner and due date only if actually stated; otherwise leave the cell blank",
          "format": "list",
          "item_format": "| **Deliverable** | **Owner** | **Due Date** |\\n| --- | --- | --- |"
        },
        {
          "title": "Commercial Terms Discussed",
          "instruction": "Summarize any pricing, SLAs, payment terms, or contract items discussed, based only on what was stated",
          "format": "paragraph"
        },
        {
          "title": "Risks & Concerns",
          "instruction": "List client concerns, blockers, or escalation items raised, with impact and owner only if actually stated; otherwise leave the cell blank",
          "format": "list",
          "item_format": "| **Concern** | **Impact** | **Owner** |\\n| --- | --- | --- |"
        },
        {
          "title": "Next Steps",
          "instruction": "List agreed next-step actions with owner and due date, only where each was actually stated; otherwise leave the cell blank (do not write 'None'). In the Ref column, cite the moment the action was agreed as @ref(MM:SS) — for example @ref(01:05) — whenever clearly identifiable in the transcript; otherwise leave the cell blank",
          "format": "list",
          "item_format": "| **Owner** | **Action** | **Due Date** | **Ref** |\\n| --- | --- | --- | --- |"
        }
      ]
    }
    """

    /// ← `frontend/src-tauri/templates/team_meeting.json` (bundled-directory tier, `loader.rs`).
    public static let teamMeetingJSON = """
    {
      "name": "Team Meeting",
      "description": "General recurring team meeting: agenda topics, decisions, action items, and blockers.",
      "sections": [
        {
          "title": "Summary",
          "instruction": "Provide a brief, one-paragraph executive summary of the meeting and its main outcomes",
          "format": "paragraph"
        },
        {
          "title": "Agenda & Topics Discussed",
          "instruction": "Summarize each topic discussed, capturing the key points and arguments raised for each",
          "format": "list",
          "item_format": "| **Topic** | **Key Points** |\\n| --- | --- |"
        },
        {
          "title": "Key Decisions",
          "instruction": "List the important decisions made, with the rationale if it was stated. In the Ref column, cite the moment the decision was made as @ref(MM:SS) — for example @ref(01:05) — whenever clearly identifiable in the transcript; otherwise leave the cell blank",
          "format": "list",
          "item_format": "| **Decision** | **Rationale** | **Ref** |\\n| --- | --- | --- |"
        },
        {
          "title": "Action Items",
          "instruction": "List all assigned tasks with their owner and due date. Only include an owner or due date if it was actually stated; otherwise leave the cell blank (do not write 'None'). In the Ref column, cite the moment the task was assigned as @ref(MM:SS) — for example @ref(01:05) — whenever clearly identifiable in the transcript; otherwise leave the cell blank",
          "format": "list",
          "item_format": "| **Owner** | **Task** | **Due Date** | **Ref** |\\n| --- | --- | --- | --- |"
        },
        {
          "title": "Risks & Blockers",
          "instruction": "List any impediments, risks, or open concerns raised, with the owner if known",
          "format": "list",
          "item_format": "| **Risk / Blocker** | **Owner** |\\n| --- | --- |"
        },
        {
          "title": "Announcements & FYIs",
          "instruction": "Capture any announcements, informational updates, or notes that did not require a decision",
          "format": "paragraph"
        }
      ]
    }
    """

    /// The seven default templates, keyed by identifier (← the two `defaults.rs` built-ins plus the
    /// five that Rust shipped only in the bundled-templates directory, `loader.rs`).
    private static let allBuiltins: [(id: String, json: String)] = [
        ("daily_standup", dailyStandupJSON),
        ("standard_meeting", standardMeetingJSON),
        ("one_on_one", oneOnOneJSON),
        ("project_sync", projectSyncJSON),
        ("retrospective", retrospectiveJSON),
        ("sales_marketing_client_call", salesMarketingClientCallJSON),
        ("team_meeting", teamMeetingJSON)
    ]

    /// ← `get_builtin_templates` (`defaults.rs`), widened to all seven shipped defaults.
    public static func builtinTemplates() -> [(id: String, json: String)] {
        allBuiltins
    }

    /// ← `get_builtin_template` (`defaults.rs`), widened to all seven shipped defaults.
    public static func builtinTemplate(id: String) -> String? {
        allBuiltins.first(where: { $0.id == id })?.json
    }

    /// ← `list_builtin_template_ids` (`defaults.rs`), widened to all seven shipped defaults.
    public static func builtinTemplateIDs() -> [String] {
        allBuiltins.map(\.id)
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
