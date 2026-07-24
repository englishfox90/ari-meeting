//
//  SummaryCanonicalFont.swift — pure canonical-font normalization for the rich summary editor
//  (`docs/plans/native-text-formatting.md` §3.1, extracted from
//  `MarginaliaSummaryFormattingDefinition.swift`).
//
//  Two-tier emphasis recovery:
//
//  - Tier 1 (always, first): exact value equality against `SummaryFontVariant`. Covers everything
//    `present` produces and everything the toolbar writes. Zero `Font.Context` needed — this is
//    what keeps the byte-faithful round trip (tests 20/21) bit-identical.
//
//    It does NOT reliably cover a native no-op write: AppKit swaps the box to
//    `PlatformFontProvider` even when it hands back an identical FACE (findings §7), so Tier-1
//    equality is lost. Known consequence, pre-existing rather than a regression: a canonically
//    BOLD heading run touched by any native font command falls through to Tier 2, resolves
//    `(isBold: true, baseIsBold: true) → bold = false`, and flattens to base — silently dropping
//    its `**…**`. The heading families cannot represent bold visually anyway (findings §7), so
//    there is nothing better to map it to; it is documented, not papered over.
//  - Tier 2 (only when Tier 1 matched nothing AND a `Font.Context` is supplied): resolve-based
//    recovery, keyed RELATIVE to the target kind's own base font. This is the fix for native
//    Font ▸ Bold/Italic, which replaces `container.font` with a platform-font-boxed `Font` that
//    fails Tier-1 equality outright (`docs/plans/native-text-formatting-findings.md` §3-4).
//    Recovering relative to the base — never absolute `isBold` — is required because the heading
//    families' base already resolves bold on this platform (findings §6): an absolute test would
//    misread every plain heading run as bold.
//
import SwiftUI

/// Maps an arbitrary run font onto the closed canonical set for a target `SummaryBlockKind`.
/// Module-internal (not public) — the same visibility as before this file was split out.
enum SummaryCanonicalFont {
    /// Representative kinds covering all three font FAMILIES the ramp collapses to — body
    /// (`paragraph`/lists), `title2` (`heading ≤ 2`), `headline` (`heading ≥ 3`). Testing the
    /// incoming font against each family's four emphasis variants recovers "is this bold / italic
    /// / both / plain" even when the run's kind differs from its current font's family.
    private static let families: [SummaryBlockKind] = [.paragraph, .heading(level: 1), .heading(level: 3)]

    /// The canonical font for a kind at an explicit bold/italic state — used by the formatting
    /// toolbar (`SummaryEditing`) to SET emphasis directly, mirroring the values `coerce` produces.
    static func font(for kind: SummaryBlockKind, bold: Bool, italic: Bool) -> Font {
        switch (bold, italic) {
        case (false, false): SummaryFontVariant.base(for: kind)
        case (true, false): SummaryFontVariant.bold(for: kind)
        case (false, true): SummaryFontVariant.italic(for: kind)
        case (true, true): SummaryFontVariant.boldItalic(for: kind)
        }
    }

    /// Recovers the (bold, italic) state of a run font.
    ///
    /// Tier 1 matches by value-equality against the canonical set of ANY family (so a toolbar
    /// toggle can flip one axis while keeping the other, and a kind change carries emphasis
    /// across families). Tier 2 runs only when Tier 1 matched nothing and `context` is non-nil:
    /// it resolves the font AND the target kind's own base in that context, and reports emphasis
    /// relative to the base — never absolute.
    static func emphasis(
        of font: Font?, for kind: SummaryBlockKind, context: Font.Context?
    ) -> (bold: Bool, italic: Bool) {
        guard let font else { return (false, false) }
        for family in families {
            if font == SummaryFontVariant.boldItalic(for: family) {
                return (true, true)
            }
            if font == SummaryFontVariant.bold(for: family) {
                return (true, false)
            }
            if font == SummaryFontVariant.italic(for: family) {
                return (false, true)
            }
            if font == SummaryFontVariant.base(for: family) {
                return (false, false)
            }
        }
        guard let context else { return (false, false) }
        let resolved = font.resolve(in: context)
        let base = SummaryFontVariant.base(for: kind).resolve(in: context)
        return emphasisRelative(
            resolvedIsBold: resolved.isBold, resolvedIsItalic: resolved.isItalic,
            baseIsBold: base.isBold, baseIsItalic: base.isItalic
        )
    }

    /// The pure decision core behind Tier 2 — `Bool` in / `Bool` out, exhaustively
    /// table-testable without constructing a `Font.Resolved` (which has no public initializer).
    /// Bold/italic are each `true` only when the run resolves that trait AND the kind's own base
    /// does NOT — the direct fix for a family (heading) whose base already resolves bold, where
    /// plain and "bolded" runs would otherwise be indistinguishable.
    static func emphasisRelative(
        resolvedIsBold: Bool, resolvedIsItalic: Bool, baseIsBold: Bool, baseIsItalic: Bool
    ) -> (bold: Bool, italic: Bool) {
        (bold: resolvedIsBold && !baseIsBold, italic: resolvedIsItalic && !baseIsItalic)
    }

    /// Reimplemented in terms of `emphasis(of:for:context:)` so the toolbar's read and this
    /// constraint's write can never disagree (plan §3.1). `nil` and every unrecognized font
    /// flatten to the kind's plain base, exactly as `emphasis` reports `(false, false)` for them.
    static func coerce(_ font: Font?, to kind: SummaryBlockKind, context: Font.Context?) -> Font {
        let emphasis = emphasis(of: font, for: kind, context: context)
        return SummaryCanonicalFont.font(for: kind, bold: emphasis.bold, italic: emphasis.italic)
    }
}
