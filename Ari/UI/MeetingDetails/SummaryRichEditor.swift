//
//  SummaryRichEditor.swift — the "invisible" rich-text editing surface for a meeting summary
//  (`docs/plans/rich-summary-editor.md` §2.5).
//
//  A VStack of the document's segments: each editable run is a macOS 26
//  `TextEditor(text:selection:)` carrying `MarginaliaSummaryFormattingDefinition`, rendered with
//  NO field chrome so edit mode looks identical to the read view (`MarginaliaMarkdownView`). Table
//  slabs render through `MarginaliaMarkdownView` with no handlers, so their `[MM:SS]` timecodes are
//  inert muted text and the table is never editable.
//
//  Editing state (document, focus, per-segment selection) lives in `SummaryEditorModel` so the
//  window toolbar's formatting controls can drive it (an inline button would steal the editor's
//  first responder and clear the selection). This view only renders the segments and mirrors the
//  focused segment into the model.
//
import AriKit
import SwiftUI

struct SummaryRichEditor: View {
    let model: SummaryEditorModel
    let scheme: ColorScheme
    /// Minimum height for the whole editor, so a summary that's a single editable segment fills
    /// the summary column the way the old plain-markdown editor did (it used `minHeight: 320`).
    var minHeight: CGFloat = 320

    @FocusState private var focusedSegment: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            ForEach(model.document.segments) { segment in
                switch segment {
                case let .editable(id, _):
                    TextEditor(text: editableBinding(id: id), selection: selectionBinding(id: id))
                        .attributedTextFormattingDefinition(MarginaliaSummaryFormattingDefinition(scheme: scheme))
                        .textEditorStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .font(MarginaliaTextStyle.body.font)
                        .focused($focusedSegment, equals: id)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case let .table(_, rawMarkdown):
                    // Inert in edit mode: no `onSeek` / `onOpenMeetingMoment`, so timecodes render
                    // as muted text, matching the read view's honest no-handler state.
                    MarginaliaMarkdownView(markdown: rawMarkdown)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        // Mirror focus into the model, but only on a real focus (ignore the nil on blur) so a
        // toolbar tap that briefly resigns focus still targets the last-edited segment.
        .onChange(of: focusedSegment) { _, newValue in
            if let newValue { model.focusedSegment = newValue }
        }
    }

    // MARK: - Segment bindings

    /// A binding into the editable text of the segment with `id`. Reads/writes the segment in
    /// place; a table id (or a stale id) reads as empty and drops writes — never mutates a
    /// `.table` slab.
    private func editableBinding(id: Int) -> Binding<AttributedString> {
        Binding(
            get: {
                for segment in model.document.segments {
                    if case let .editable(segmentID, text) = segment, segmentID == id {
                        return text
                    }
                }
                return AttributedString()
            },
            set: { newText in
                guard let index = model.document.segments.firstIndex(where: { segment in
                    if case let .editable(segmentID, _) = segment { return segmentID == id }
                    return false
                }) else { return }
                model.document.segments[index] = .editable(id: id, text: newText)
            }
        )
    }

    private func selectionBinding(id: Int) -> Binding<AttributedTextSelection> {
        Binding(
            get: { model.selections[id] ?? AttributedTextSelection() },
            set: { model.selections[id] = $0 }
        )
    }
}
