//
//  SummaryEditorModel.swift — the editing state for the rich-text summary editor, lifted out of
//  the view so the WINDOW TOOLBAR's formatting controls can drive it
//  (`docs/plans/rich-summary-editor.md` §2.5).
//
//  Why a model instead of view-local state: an inline SwiftUI `Button` steals first-responder from
//  the `TextEditor` when tapped, clearing its selection before the transform runs (a no-op edit).
//  `NSToolbar` items — the window toolbar — do NOT resign the text view's first responder (the same
//  reason the native Format menu works mid-edit), so the live selection survives the tap. The model
//  holds `document` + the focused segment + its selection; `SummaryRichEditor` mirrors focus/
//  selection in, and the toolbar buttons call `toggleBold()` / `setBlockKind(_:)` etc.
//
import AriKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SummaryEditorModel {
    /// The segment model being edited (editable prose runs + verbatim table slabs).
    var document: SummaryEditDocument
    /// The id of the editable segment that last held first-responder focus — retained across a
    /// toolbar tap so a format command still targets the right segment.
    var focusedSegment: Int?
    /// Whether an editable segment holds focus RIGHT NOW — unlike `focusedSegment`, this is not
    /// latched and goes `false` on blur.
    ///
    /// Gates publication to the Format menu (⌘B/⌘I). The latch above deliberately survives a blur
    /// so a toolbar tap still targets the last-edited segment, but the menu needs the unlatched
    /// truth: without it, leaving the editor for another field in the same scene (e.g. the rename
    /// alert's `TextField`) would leave ⌘B firing on the stale latched selection with no visible
    /// cause. Menu key equivalents dispatch ahead of the responder chain, so nothing else would
    /// stop it.
    var hasLiveFocus = false
    /// The live selection per editable segment (single-editor selection), keyed by segment id.
    var selections: [Int: AttributedTextSelection] = [:]
    /// The editor's own `Font.Context` (`docs/plans/native-text-formatting.md` §3.4), mirrored in
    /// from `SummaryRichEditor`'s `@Environment(\.fontResolutionContext)` on appear/change. Lets
    /// `SummaryCanonicalFont`'s Tier 2 recover emphasis from a NATIVELY-applied Font ▸ Bold/Italic
    /// command when a toolbar action (or ⌘B/⌘I) subsequently reads/writes the same run.
    var fontContext: Font.Context?

    init(document: SummaryEditDocument = SummaryEditDocument(segments: [])) {
        self.document = document
    }

    /// Resets to a fresh document for a new edit session (or an empty one to discard the draft).
    func load(_ document: SummaryEditDocument) {
        self.document = document
        focusedSegment = nil
        selections = [:]
    }

    func clear() {
        load(SummaryEditDocument(segments: []))
    }

    func serialized() -> String {
        document.serialized()
    }

    /// Whether the current draft would serialize to nothing — Save is disabled so an edit can never
    /// replace a real summary with a blank one (No-Fake-State).
    var isSerializedEmpty: Bool {
        serialized().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Formatting commands (driven by the window toolbar)

    func toggleBold() {
        let context = fontContext
        apply { text, selection in
            SummaryEditing.toggleBold(in: &text, selection: &selection, context: context)
        }
    }

    func toggleItalic() {
        let context = fontContext
        apply { text, selection in
            SummaryEditing.toggleItalic(in: &text, selection: &selection, context: context)
        }
    }

    func setBlockKind(_ kind: SummaryBlockKind) {
        let context = fontContext
        apply { text, selection in
            SummaryEditing.setBlockKind(kind, in: &text, selection: &selection, context: context)
        }
    }

    /// Routes a transform to the focused editable segment's (text, selection) pair. No-op when
    /// nothing is focused or the id no longer resolves to an editable segment.
    private func apply(_ transform: (inout AttributedString, inout AttributedTextSelection) -> Void) {
        guard let id = focusedSegment,
              let index = document.segments.firstIndex(where: { segment in
                  if case let .editable(segmentID, _) = segment {
                      return segmentID == id
                  }
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
}
