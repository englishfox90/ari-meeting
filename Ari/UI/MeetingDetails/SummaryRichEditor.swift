//
//  SummaryRichEditor.swift — the "invisible" rich-text editing surface for a meeting summary
//  (`docs/plans/rich-summary-editor.md` §2.5).
//
//  A VStack of the document's segments: each editable run is a macOS 26
//  `TextEditor(text:selection:)` carrying `MarginaliaSummaryFormattingDefinition`, rendered with
//  NO field chrome so edit mode looks identical to the read view (`MarginaliaMarkdownView`) — the
//  user's explicit design intent. Table slabs render through `MarginaliaMarkdownView` with no
//  handlers, so their `[MM:SS]` timecodes are inert muted text (never dead play chips) and the
//  table is never editable or rewritten.
//
//  Structure/serialization is entirely the transform library's job (`SummaryEditDocument` /
//  `SummaryRichText`); this view only presents the segments and owns per-segment selection state.
//
import AriKit
import SwiftUI

struct SummaryRichEditor: View {
    @Binding var document: SummaryEditDocument
    let scheme: ColorScheme
    /// Minimum height for the whole editor, so a summary that's a single editable segment fills
    /// the summary column the way the old plain-markdown editor did (it used `minHeight: 320`).
    var minHeight: CGFloat = 320

    /// One selection per editable segment (a selection is single-editor). Keyed by the segment's
    /// stable `id`; a missing entry defaults to an empty selection. Table segments have no entry.
    @State private var selections: [Int: AttributedTextSelection] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            ForEach(document.segments) { segment in
                switch segment {
                case let .editable(id, _):
                    TextEditor(text: editableBinding(id: id), selection: selectionBinding(id: id))
                        .attributedTextFormattingDefinition(MarginaliaSummaryFormattingDefinition(scheme: scheme))
                        .textEditorStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .font(MarginaliaTextStyle.body.font)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case let .table(_, rawMarkdown):
                    // Inert in edit mode: no `onSeek` / `onOpenMeetingMoment`, so timecodes render
                    // as muted text, matching the read view's honest no-handler state.
                    MarginaliaMarkdownView(markdown: rawMarkdown)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
    }

    /// A binding into the editable text of the segment with `id`. Reads/writes the segment in
    /// place; a table id (or a stale id) reads as empty and drops writes — never mutates a
    /// `.table` slab.
    private func editableBinding(id: Int) -> Binding<AttributedString> {
        Binding(
            get: {
                for segment in document.segments {
                    if case let .editable(segmentID, text) = segment, segmentID == id {
                        return text
                    }
                }
                return AttributedString()
            },
            set: { newText in
                guard let index = document.segments.firstIndex(where: { segment in
                    if case let .editable(segmentID, _) = segment { return segmentID == id }
                    return false
                }) else { return }
                document.segments[index] = .editable(id: id, text: newText)
            }
        )
    }

    private func selectionBinding(id: Int) -> Binding<AttributedTextSelection> {
        Binding(
            get: { selections[id] ?? AttributedTextSelection() },
            set: { selections[id] = $0 }
        )
    }
}
