//
//  SummaryFormatCommands.swift — a minimal Format menu (Bold / Italic only) for the rich summary
//  editor (`docs/plans/native-text-formatting.md` §7).
//
//  ⌘B / ⌘I are unbound in Ari today (no `.commands` at all — findings §8). Adopting
//  `SwiftUI.TextFormattingCommands` would also bring Underline (⌘U), Bigger/Smaller, Show Fonts/
//  Colors, and alignment along — Underline would be a dead checkmark once §6's strip constraints
//  land, and Bigger/Smaller would resolve non-canonical and visibly flash-then-revert. So this is
//  a minimal custom group with only the two items the closed grammar actually represents, driven
//  through `SummaryEditorModel` (the ONE canonical writer the inline formatting bar already uses)
//  rather than attempting to edit the native context menu.
//
//  `@FocusedValue(SummaryEditorModel.self)` reads whatever `MeetingDetailView` publishes via
//  `.focusedSceneValue(_:)` while the summary is being edited — `nil` (items disabled) otherwise,
//  so ⌘B in, say, a rename text field does nothing rather than something surprising.
//
//  Deliberately NOT toggle-checkmarked: per-selection emphasis isn't authoritatively mirrored
//  here, and a checkmark this menu can't derive truthfully would be fake state.
//
import SwiftUI

struct SummaryFormatCommands: Commands {
    @FocusedValue(SummaryEditorModel.self) private var editor

    var body: some Commands {
        CommandGroup(replacing: .textFormatting) {
            Button("Bold") { editor?.toggleBold() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(editor == nil)
            Button("Italic") { editor?.toggleItalic() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(editor == nil)
        }
    }
}
