//
//  NotesReadView.swift — read-only render of `MeetingNote.notesMarkdown`, or an honest
//  "No notes" when `nil` (plan §2.2 MeetingDetails; block editing is Phase 4 — this view
//  never touches `notesJson`).
//
import AriKit
import AriViewModels
import SwiftUI

struct NotesReadView: View {
    let notes: MeetingNote?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let notes, let markdown = notes.notesMarkdown, !markdown.isEmpty {
            ScrollView {
                MarkdownText(markdown: markdown)
                    .padding(MarginaliaSpacing.md.value)
            }
        } else {
            VStack(spacing: MarginaliaSpacing.xs.value) {
                Text("No notes")
                    .marginaliaTextStyle(.body, in: scheme)
                Text("Nothing has been written for this meeting yet.")
                    .marginaliaTextStyle(.callout, in: scheme)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(MarginaliaSpacing.xl.value)
        }
    }
}
