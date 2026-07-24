//
//  SummaryRichEditor.swift — the "invisible" rich-text editing surface for a meeting summary
//  (`docs/plans/rich-summary-editor.md` §2.5).
//
//  A compact formatting bar over a VStack of the document's segments: each editable run is a
//  macOS 26 `TextEditor(text:selection:)` carrying `MarginaliaSummaryFormattingDefinition`,
//  rendered with NO field chrome so edit mode looks identical to the read view
//  (`MarginaliaMarkdownView`). Table slabs render through `MarginaliaMarkdownView` with no
//  handlers, so their `[MM:SS]` timecodes are inert muted text and the table is never editable.
//
//  The formatting bar (Bold / Italic / Heading / Body / Bullet / Numbered) drives the SAME
//  `\.summaryBlock` + canonical-font model the serializer round-trips, via `SummaryEditing` — so
//  toolbar formatting stays byte-faithful on save. It acts on the last-focused editable segment's
//  selection: select text, then click (or ⌘B / ⌘I). Bullet/numbered markers are presentation the
//  serializer re-derives, so the visible marker appears on the next open; headings restyle live.
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
    /// The currently first-responder editable segment, if any.
    @FocusState private var focusedSegment: Int?
    /// The last segment that HELD focus — retained so a formatting-bar click (which may resign the
    /// editor's first-responder status) still knows which segment to transform.
    @State private var lastFocusedSegment: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            formattingBar
            ForEach(document.segments) { segment in
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
        .onChange(of: focusedSegment) { _, newValue in
            if let newValue { lastFocusedSegment = newValue }
        }
    }

    // MARK: - Formatting bar

    private var formattingBar: some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            // Deterministic button-click formatting (no `.keyboardShortcut` here — it would
            // race the TextEditor's native ⌘B/⌘I and could double-toggle to a no-op). Native
            // ⌘B/⌘I still work at the OS level; these buttons are the canonical path.
            formatButton("bold", help: "Bold") { apply(SummaryEditing.toggleBold) }
            formatButton("italic", help: "Italic") { apply(SummaryEditing.toggleItalic) }
            Divider().frame(height: 16)
            formatButton("textformat.size", help: "Heading") {
                apply { SummaryEditing.setBlockKind(.heading(level: 2), in: &$0, selection: &$1) }
            }
            formatButton("text.alignleft", help: "Body text") {
                apply { SummaryEditing.setBlockKind(.paragraph, in: &$0, selection: &$1) }
            }
            formatButton("list.bullet", help: "Bulleted list") {
                apply { SummaryEditing.setBlockKind(.bulletItem, in: &$0, selection: &$1) }
            }
            formatButton("list.number", help: "Numbered list") {
                apply { SummaryEditing.setBlockKind(.numberedItem, in: &$0, selection: &$1) }
            }
            Spacer()
        }
        .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
    }

    private func formatButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// Routes a transform to the last-focused editable segment's (text, selection) pair. No-op when
    /// nothing has been focused, or when the target id no longer resolves to an editable segment.
    private func apply(_ transform: (inout AttributedString, inout AttributedTextSelection) -> Void) {
        guard let id = focusedSegment ?? lastFocusedSegment,
              let index = document.segments.firstIndex(where: { segment in
                  if case let .editable(segmentID, _) = segment { return segmentID == id }
                  return false
              }),
              case let .editable(_, text) = document.segments[index]
        else { return }
        var newText = text
        var selection = selections[id] ?? AttributedTextSelection()
        transform(&newText, &selection)
        document.segments[index] = .editable(id: id, text: newText)
        selections[id] = selection
    }

    // MARK: - Segment bindings

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
