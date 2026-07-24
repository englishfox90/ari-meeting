//
//  SummaryCanonicalFontTests.swift — acceptance tests for the two-tier emphasis-recovery
//  algorithm (`docs/plans/native-text-formatting.md` §9, N1-N10).
//
//  Tier-2 (resolve-based) assertions use the BODY / SF-Pro family only: AriKit's test target
//  runs without the app bundle, so "Bricolage Grotesque SemiBold/Bold" are unregistered and
//  `Font.custom` silently falls back to the system font — the heading families' measured
//  "carries neither bold nor italic" behaviour (findings §7) can't be reproduced here. That
//  behaviour is instead covered by the font-independent `emphasisRelative` truth table
//  (N7/N8), which needs no live font resolution at all.
//
#if os(macOS)
    import AppKit
#endif
import SwiftUI
import Testing
@testable import AriKit

@Suite("SummaryCanonicalFont — two-tier emphasis recovery")
struct SummaryCanonicalFontTests {
    private let allKinds: [SummaryBlockKind] = [.paragraph, .heading(level: 1), .heading(level: 3), .bulletItem]

    #if os(macOS)
        /// A `Font` boxed over a concrete resolved `NSFont` — exactly what `NSFontManager`'s
        /// `addFontTrait:` (the real Font ▸ Bold/Italic action, findings §3) writes into
        /// `container.font`. Body-family only (see file header).
        private func platformFont(bold: Bool, italic: Bool) -> Font {
            var nsFont = NSFont.systemFont(ofSize: 14, weight: .regular)
            if bold {
                nsFont = NSFontManager.shared.convert(nsFont, toHaveTrait: .boldFontMask)
            }
            if italic {
                nsFont = NSFontManager.shared.convert(nsFont, toHaveTrait: .italicFontMask)
            }
            return Font(nsFont)
        }

        private var fontContext: Font.Context {
            EnvironmentValues().fontResolutionContext
        }
    #endif

    // MARK: - N1-N3, N9, N10: value-equality tier (context nil OR present, behaviour identical)

    @Test("all four canonical variants are fixed points under coerce, with and without a context")
    func canonicalFontsAreFixedPointsUnderCoerce() {
        for kind in allKinds {
            let variants: [Font] = [
                SummaryFontVariant.base(for: kind),
                SummaryFontVariant.bold(for: kind),
                SummaryFontVariant.italic(for: kind),
                SummaryFontVariant.boldItalic(for: kind)
            ]
            for variant in variants {
                #expect(SummaryCanonicalFont.coerce(variant, to: kind, context: nil) == variant)
                #if os(macOS)
                    #expect(SummaryCanonicalFont.coerce(variant, to: kind, context: fontContext) == variant)
                #endif
            }
        }
    }

    @Test("an unrecognized font with no context flattens to the kind's plain base")
    func unrecognizedFontWithoutContextFlattensToBase() {
        let foreign = Font.system(size: 48, weight: .black, design: .rounded)
        let result = SummaryCanonicalFont.coerce(foreign, to: .paragraph, context: nil)
        #expect(result == SummaryFontVariant.base(for: .paragraph))
    }

    @Test("bold emphasis carries across a family/kind change")
    func crossFamilyEmphasisIsStillPreserved() {
        let headingBold = SummaryFontVariant.bold(for: .heading(level: 1))
        let result = SummaryCanonicalFont.coerce(headingBold, to: .bulletItem, context: nil)
        #expect(result == SummaryFontVariant.bold(for: .bulletItem))
    }

    @Test("a size-only native change (Bigger/Smaller) flattens to the canonical size")
    func sizeOnlyChangeFlattensToCanonicalSize() {
        #if os(macOS)
            let biggerBody = Font(NSFont.systemFont(ofSize: 20, weight: .regular))
            let result = SummaryCanonicalFont.coerce(biggerBody, to: .paragraph, context: fontContext)
            #expect(result == SummaryFontVariant.base(for: .paragraph))
        #endif
    }

    @Test("a nil font always coerces to the kind's base, with and without a context")
    func nilFontAlwaysCoercesToBase() {
        for kind in allKinds {
            #expect(SummaryCanonicalFont.coerce(nil, to: kind, context: nil) == SummaryFontVariant.base(for: kind))
            #if os(macOS)
                #expect(SummaryCanonicalFont.coerce(nil, to: kind, context: fontContext) == SummaryFontVariant
                    .base(for: kind))
            #endif
        }
    }

    // MARK: - N4-N6: Tier 2, the headline recovery criterion

    #if os(macOS)
        @Test("native Font ▸ Bold on body text is recovered as canonical bold")
        func nativeBoldOnBodyIsRecoveredAsCanonicalBold() {
            let platformBold = platformFont(bold: true, italic: false)
            let result = SummaryCanonicalFont.coerce(platformBold, to: .paragraph, context: fontContext)
            #expect(result == SummaryFontVariant.bold(for: .paragraph))
        }

        @Test("native Font ▸ Italic on body text is recovered as canonical italic")
        func nativeItalicOnBodyIsRecoveredAsCanonicalItalic() {
            let platformItalic = platformFont(bold: false, italic: true)
            let result = SummaryCanonicalFont.coerce(platformItalic, to: .paragraph, context: fontContext)
            #expect(result == SummaryFontVariant.italic(for: .paragraph))
        }

        @Test("accumulated native Bold then Italic recovers as canonical bold+italic")
        func nativeBoldThenItalicIsRecoveredAsCanonicalBoldItalic() {
            let platformBoldItalic = platformFont(bold: true, italic: true)
            let result = SummaryCanonicalFont.coerce(platformBoldItalic, to: .paragraph, context: fontContext)
            #expect(result == SummaryFontVariant.boldItalic(for: .paragraph))
        }
    #endif

    // MARK: - N7-N8: the pure decision core

    @Test("emphasisRelative truth table — all 16 rows")
    func emphasisRelativeTruthTable() {
        for resolvedIsBold in [false, true] {
            for resolvedIsItalic in [false, true] {
                for baseIsBold in [false, true] {
                    for baseIsItalic in [false, true] {
                        let result = SummaryCanonicalFont.emphasisRelative(
                            resolvedIsBold: resolvedIsBold, resolvedIsItalic: resolvedIsItalic,
                            baseIsBold: baseIsBold, baseIsItalic: baseIsItalic
                        )
                        #expect(result.bold == (resolvedIsBold && !baseIsBold))
                        #expect(result.italic == (resolvedIsItalic && !baseIsItalic))
                    }
                }
            }
        }
    }

    @Test("a run resolving bold on a family whose base is ALREADY bold never reads as bold")
    func boldBaseFamilyNeverReadsAsBold() {
        let result = SummaryCanonicalFont.emphasisRelative(
            resolvedIsBold: true, resolvedIsItalic: false, baseIsBold: true, baseIsItalic: false
        )
        #expect(result.bold == false)
    }
}
