//
//  MarginaliaSummaryFormattingDefinition.swift — the formatting definition applied to the
//  rich-text summary editor's `TextEditor` (`docs/plans/rich-summary-editor.md` §2.4,
//  `docs/plans/native-text-formatting.md`).
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
/// active `ColorScheme` (so `SummaryInkConstraint` can re-apply the *scheme's* ink — `present`
/// hardcodes the light-scheme ink) and the active `Font.Context` (so `SummaryFontConstraint` can
/// recover native-command emphasis via Tier 2 — `docs/plans/native-text-formatting.md` §4). `nil`
/// context is a legitimate value (e.g. no live environment yet); it degrades Tier 2 gracefully to
/// Tier 1 only, never to a wrong canonical value.
public struct MarginaliaSummaryFormattingDefinition: AttributedTextFormattingDefinition {
    public typealias Scope = AttributeScopes.AriAttributes

    private let scheme: ColorScheme
    private let fontContext: Font.Context?

    public init(scheme: ColorScheme, fontContext: Font.Context?) {
        self.scheme = scheme
        self.fontContext = fontContext
    }

    public var body: some AttributedTextFormattingDefinition<Scope> {
        // Order: default/clamp the block kind first, so font + ink read a resolved kind. (The
        // font/ink constraints also fall back to `.paragraph` on a nil kind, so the result is
        // order-independent — this ordering is only for clarity.)
        SummaryBlockDefaultConstraint()
        SummaryFontConstraint(fontContext: fontContext)
        SummaryInkConstraint(scheme: scheme)
        // Non-grammar attributes the editor's scope makes applicable but the closed markdown
        // grammar can't round-trip (plan §6). Stripped, not left as a dead checkmark that
        // silently loses data on Save (No-Fake-State).
        SummaryNoUnderlineConstraint()
        SummaryNoStrikethroughConstraint()
        SummaryNoHighlightConstraint()
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
/// round-trip stable regardless of what a paste, a shortcut, or a NATIVE Font ▸ Bold/Italic
/// command wrote.
///
/// `fontContext` (threaded from the editor's own `\.fontResolutionContext`, plan §4) lets
/// `SummaryCanonicalFont` recover emphasis from a native command's platform-boxed font (Tier 2)
/// when Tier 1's value equality finds no exact canonical match.
struct SummaryFontConstraint: AttributedTextValueConstraint {
    typealias Scope = AttributeScopes.AriAttributes
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.FontAttribute

    let fontContext: Font.Context?

    func constrain(_ container: inout Attributes) {
        let kind = container.summaryBlock ?? .paragraph
        container.font = SummaryCanonicalFont.coerce(container.font, to: kind, context: fontContext)
    }

    /// Hand-written because `Font.Context.hash(into:)` is **thread-affine** on macOS 26.5: the same
    /// value hashes differently on the main thread than on a background thread (`==` is stable
    /// across threads; only the hash moves). Feeding it into our hash would break `Hashable`'s
    /// stability requirement on a type the SDK requires to be `Hashable` — measurably so: identical
    /// values inserted into a `Set` on one thread miss on lookup from another.
    ///
    /// Excluding it is legal — `Hashable` only requires *equal ⇒ equal hash*, never the converse —
    /// and `==` stays synthesized, so `fontContext` is still compared and a genuinely different
    /// context still reads as a changed definition. Hashing the nil-ness keeps one bit of stable
    /// discrimination for free.
    func hash(into hasher: inout Hasher) {
        hasher.combine(fontContext != nil)
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

/// Unconditionally strips underline — `Font ▸ Underline` is applicable in the editor's scope but
/// has no representation in the closed Marginalia markdown grammar (`docs/plans/
/// native-text-formatting.md` §6). Leaving it would round-trip to a dead checkmark that silently
/// loses the styling on Save — a No-Fake-State violation. Mirrors how `SummaryInkConstraint`
/// already force-overwrites `foregroundColor` every pass.
struct SummaryNoUnderlineConstraint: AttributedTextValueConstraint {
    typealias Scope = AttributeScopes.AriAttributes
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute

    func constrain(_ container: inout Attributes) {
        container.underlineStyle = nil
    }
}

/// Unconditionally strips strikethrough — reachable via the Font panel / Format… even though no
/// context-menu item exposes it directly (findings §9). Same rationale as
/// `SummaryNoUnderlineConstraint`.
struct SummaryNoStrikethroughConstraint: AttributedTextValueConstraint {
    typealias Scope = AttributeScopes.AriAttributes
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute

    func constrain(_ container: inout Attributes) {
        container.strikethroughStyle = nil
    }
}

/// Unconditionally strips highlight (background color) — `Font ▸ Highlight ▸ any color`. Same
/// rationale as `SummaryNoUnderlineConstraint`.
struct SummaryNoHighlightConstraint: AttributedTextValueConstraint {
    typealias Scope = AttributeScopes.AriAttributes
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute

    func constrain(_ container: inout Attributes) {
        container.backgroundColor = nil
    }
}
