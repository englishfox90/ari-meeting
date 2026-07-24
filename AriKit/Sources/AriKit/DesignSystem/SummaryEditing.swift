//
//  SummaryEditing.swift — editor-side text transforms for the summary rich editor's formatting
//  toolbar (`docs/plans/rich-summary-editor.md` §2.5, R1 fallback path).
//
//  Pure mutations on the (`AttributedString`, `AttributedTextSelection`) pair via the confirmed
//  macOS 26 `transformAttributes(in:_:)` API. Each writes ONLY canonical values from the same
//  `SummaryFontVariant` set the serializer round-trips and the formatting definition coerces to —
//  so a toolbar-applied bold is byte-identical to a parsed `**…**`. The formatting definition
//  re-runs its constraints after each mutation, so these set the target and let the definition
//  keep the document consistent.
//
//  These live in AriKit (beside the presenter/serializer) so the one canonical-font source is
//  never forked into the app target; the view layer only routes the focused segment's bindings in.
//
import SwiftUI

public enum SummaryEditing {
    /// Toggles bold on the selected text, preserving its italic state. Operates per run over the
    /// selection (each run flips its own bold bit relative to its current emphasis).
    public static func toggleBold(
        in text: inout AttributedString, selection: inout AttributedTextSelection
    ) {
        text.transformAttributes(in: &selection) { container in
            let kind = container.summaryBlock ?? .paragraph
            let emphasis = SummaryCanonicalFont.emphasis(of: container.font, for: kind)
            container.font = SummaryCanonicalFont.font(for: kind, bold: !emphasis.bold, italic: emphasis.italic)
        }
    }

    /// Toggles italic on the selected text, preserving its bold state.
    public static func toggleItalic(
        in text: inout AttributedString, selection: inout AttributedTextSelection
    ) {
        text.transformAttributes(in: &selection) { container in
            let kind = container.summaryBlock ?? .paragraph
            let emphasis = SummaryCanonicalFont.emphasis(of: container.font, for: kind)
            container.font = SummaryCanonicalFont.font(for: kind, bold: emphasis.bold, italic: !emphasis.italic)
        }
    }

    /// Sets the block kind (heading / bullet / numbered / paragraph) across the selection. Because
    /// `\.summaryBlock` is paragraph-scoped (`runBoundaries: .paragraph`), touching any part of a
    /// paragraph re-stamps the whole paragraph. Emphasis is carried onto the new kind's font family
    /// so bold/italic survives a heading↔body switch.
    ///
    /// For LIST kinds the run is then re-presented through the tested `serialize → present`
    /// round-trip, so the visible `•` / `1.` markers actually appear and numbered items renumber
    /// from 1 (setting the attribute alone leaves no marker — which read as "nothing happened").
    /// Re-presenting rebuilds the string, so the selection is collapsed afterward (its indices no
    /// longer map). This canonicalizes the run — the same rewrite Save already accepts (plan D1).
    public static func setBlockKind(
        _ kind: SummaryBlockKind, in text: inout AttributedString, selection: inout AttributedTextSelection
    ) {
        text.transformAttributes(in: &selection) { container in
            let previousKind = container.summaryBlock ?? .paragraph
            let emphasis = SummaryCanonicalFont.emphasis(of: container.font, for: previousKind)
            container.summaryBlock = kind
            container.font = SummaryCanonicalFont.font(for: kind, bold: emphasis.bold, italic: emphasis.italic)
        }
        if kind == .bulletItem || kind == .numberedItem {
            text = SummaryRichText.present(markdown: SummaryRichText.serialize(text))
            selection = AttributedTextSelection()
        }
    }
}
