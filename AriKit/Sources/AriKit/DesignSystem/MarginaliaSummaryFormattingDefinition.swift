//
//  MarginaliaSummaryFormattingDefinition.swift — the formatting definition applied to the
//  rich-text summary editor's `TextEditor` (`docs/plans/rich-summary-editor.md` §2.4).
//
//  An `AttributedTextFormattingDefinition` over `AttributeScopes.AriAttributes` (block kind +
//  SwiftUI font/foregroundColor). Its constraints run over EVERY mutation the editor makes —
//  typed text, pasted text, and shortcut-toggled emphasis — and coerce each run back into the
//  closed Marginalia set. That is what makes rich paste safe (a pasted 48 pt Comic Sans run
//  lands as canonical body) and what makes edit mode look identical to the read view (same
//  fonts, same scheme ink).
//
//  NOTE (Step-0 verdict, plan §7): `AttributedTextFormattingDefinition`,
//  `AttributedTextValueConstraint`, and `.attributedTextFormattingDefinition(_:)` live in
//  `SwiftUICore`, imported transitively via `import SwiftUI`. The custom-constraint protocol's
//  `constrain(_:)` receives a `@dynamicMemberLookup` proxy that READS sibling attributes (the
//  block kind) and WRITES its own key (font / color / block) — the exact mechanism the spike
//  compiled against `MacOSX26.5.sdk`.
//
import SwiftUI

/// The formatting definition for the summary rich-text editor. Constructed per render with the
/// active `ColorScheme` so `SummaryInkConstraint` can re-apply the *scheme's* ink — `present`
/// hardcodes the light-scheme ink (ink is irrelevant to the markdown round-trip, so it has no
/// `ColorScheme` param), which would leave dark mode wrong-colored until this fires (plan §2.4,
/// review LOW / Step-5 must-do).
public struct MarginaliaSummaryFormattingDefinition: AttributedTextFormattingDefinition {
    public typealias Scope = AttributeScopes.AriAttributes

    private let scheme: ColorScheme

    public init(scheme: ColorScheme) {
        self.scheme = scheme
    }

    public var body: some AttributedTextFormattingDefinition<Scope> {
        // Order: default/clamp the block kind first, so font + ink read a resolved kind. (The
        // font/ink constraints also fall back to `.paragraph` on a nil kind, so the result is
        // order-independent — this ordering is only for clarity.)
        SummaryBlockDefaultConstraint()
        SummaryFontConstraint()
        SummaryInkConstraint(scheme: scheme)
    }
}

// MARK: - Constraints

/// Fills in `\.summaryBlock` where it's absent and clamps heading levels into `1...6`.
///
/// A run typed into a fresh, never-stamped segment has no block attribute; without this it would
/// serialize as `paragraph` (the serializer already defaults that way), but the font/ink
/// constraints want a concrete kind to key off, and the editor wants a stable structural identity
/// from the first keystroke.
struct SummaryBlockDefaultConstraint: AttributedTextValueConstraint {
    typealias Scope = AttributeScopes.AriAttributes
    typealias AttributeKey = SummaryBlockAttribute

    func constrain(_ container: inout Attributes) {
        switch container.summaryBlock {
        case .none:
            container.summaryBlock = .paragraph
        case let .heading(level) where !(1 ... 6).contains(level):
            container.summaryBlock = .heading(level: min(max(level, 1), 6))
        default:
            break
        }
    }
}

/// Coerces every run's font to the closed canonical set for its paragraph's `SummaryBlockKind` +
/// emphasis — the ONLY bold/italic representation the document uses (plan §2.4). `serialize`
/// compares run fonts against exactly these values, so normalizing here is what keeps the
/// round-trip stable regardless of what a paste or a shortcut wrote.
///
/// Emphasis is preserved across a kind change: if the incoming font is a canonical *bold* of ANY
/// family (e.g. the run was a heading and became a bullet), it maps to *this* kind's bold. A font
/// that matches nothing in the canonical set (a foreign paste) flattens to the kind's plain base —
/// deliberate: the closed grammar has no representation for arbitrary fonts.
struct SummaryFontConstraint: AttributedTextValueConstraint {
    typealias Scope = AttributeScopes.AriAttributes
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.FontAttribute

    func constrain(_ container: inout Attributes) {
        let kind = container.summaryBlock ?? .paragraph
        container.font = SummaryCanonicalFont.coerce(container.font, to: kind)
    }
}

/// Forces the foreground color to the block's Marginalia ink role in the *active scheme*
/// (headings → `inkHeading`, body/list → `inkBody`). `present` bakes in the light-scheme ink;
/// this re-applies the correct scheme ink so the editor is right-colored in dark mode from the
/// first render (plan §2.4).
struct SummaryInkConstraint: AttributedTextValueConstraint {
    typealias Scope = AttributeScopes.AriAttributes
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute

    let scheme: ColorScheme

    func constrain(_ container: inout Attributes) {
        let kind = container.summaryBlock ?? .paragraph
        let role: MarginaliaColorRole = switch kind {
        case .heading: .inkHeading
        case .paragraph, .bulletItem, .numberedItem: .inkBody
        }
        container.foregroundColor = MarginaliaColors.resolve(role, for: scheme)
    }
}

// MARK: - Canonical font coercion

/// Maps an arbitrary run font onto the closed canonical set for a target `SummaryBlockKind`,
/// preserving the bold/italic dimension when the source font is already one of our canonical
/// values. Uses ONLY value-equality against `SummaryFontVariant` (the single source the serializer
/// also compares against), so a coerced run is identity-canonical by construction.
enum SummaryCanonicalFont {
    /// Representative kinds covering all three font FAMILIES the ramp collapses to — body
    /// (`paragraph`/lists), `title2` (`heading ≤ 2`), `headline` (`heading ≥ 3`). Testing the
    /// incoming font against each family's four emphasis variants recovers "is this bold / italic /
    /// both / plain" even when the run's kind differs from its current font's family.
    private static let families: [SummaryBlockKind] = [.paragraph, .heading(level: 1), .heading(level: 3)]

    static func coerce(_ font: Font?, to kind: SummaryBlockKind) -> Font {
        guard let font else { return SummaryFontVariant.base(for: kind) }
        for family in families {
            if font == SummaryFontVariant.boldItalic(for: family) {
                return SummaryFontVariant.boldItalic(for: kind)
            }
            if font == SummaryFontVariant.bold(for: family) {
                return SummaryFontVariant.bold(for: kind)
            }
            if font == SummaryFontVariant.italic(for: family) {
                return SummaryFontVariant.italic(for: kind)
            }
            if font == SummaryFontVariant.base(for: family) {
                return SummaryFontVariant.base(for: kind)
            }
        }
        // Unrecognized (foreign paste, native-command font we don't mint) → plain base for the kind.
        return SummaryFontVariant.base(for: kind)
    }

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

    /// Recovers the (bold, italic) state of a run font by matching it against the canonical set of
    /// any family (so a toolbar toggle can flip one axis while keeping the other). A font we don't
    /// recognize reads as plain — the same conservative default as `coerce`.
    static func emphasis(of font: Font?, for _: SummaryBlockKind) -> (bold: Bool, italic: Bool) {
        guard let font else { return (false, false) }
        for family in families {
            if font == SummaryFontVariant.boldItalic(for: family) { return (true, true) }
            if font == SummaryFontVariant.bold(for: family) { return (true, false) }
            if font == SummaryFontVariant.italic(for: family) { return (false, true) }
            if font == SummaryFontVariant.base(for: family) { return (false, false) }
        }
        return (false, false)
    }
}
