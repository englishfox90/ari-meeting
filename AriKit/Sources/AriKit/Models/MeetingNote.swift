//
//  MeetingNote.swift — user-authored meeting notes (NEW type, kept per data-preservation;
//  plan §0.1(1), §4.12).
//
//  Ports the legacy `meeting_notes` table
//  (`frontend/src-tauri/migrations/20251223000000_add_meeting_notes.sql`) in its exact shape:
//
//  ```sql
//  CREATE TABLE meeting_notes (
//      meeting_id TEXT PRIMARY KEY NOT NULL,
//      notes_markdown TEXT,
//      notes_json TEXT,
//      created_at TEXT NOT NULL,
//      updated_at TEXT NOT NULL,
//      FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
//  );
//  ```
//
//  The legacy primary key is `meeting_id` itself — one note row per meeting, not a synthetic
//  UUID — so this type's identity is `meetingId`, not a separate generated `id` (a deliberate
//  deviation from the plan's literal "id(PK)" wording in §4.12: matching the real legacy shape
//  exactly beats inventing an id column that never existed). Both free-text fields the legacy
//  row carries are kept — `notesMarkdown` (flattened markdown) and `notesJson` (the BlockNote/
//  Tiptap rich-text document) — since dropping either would silently lose real user data.
//
import Foundation

public struct MeetingNote: Codable, Hashable, Sendable, Identifiable {
    public var meetingId: MeetingID
    public var notesMarkdown: String?
    public var notesJson: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// `Identifiable` conformance keyed on `meetingId` (see file header — there is no separate
    /// id column, either here or in the legacy row this ports).
    public var id: MeetingID {
        meetingId
    }

    public init(
        meetingId: MeetingID,
        notesMarkdown: String? = nil,
        notesJson: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.meetingId = meetingId
        self.notesMarkdown = notesMarkdown
        self.notesJson = notesJson
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
