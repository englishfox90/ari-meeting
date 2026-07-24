//
//  SummaryFormattingDefinitionTests.swift — acceptance tests for `MarginaliaSummaryFormatting-
//  Definition` (`docs/plans/native-text-formatting.md` §9, N11-N14).
//
#if os(macOS)
    import AppKit
#endif
import SwiftUI
import Testing
@testable import AriKit

@Suite("MarginaliaSummaryFormattingDefinition")
struct SummaryFormattingDefinitionTests {

    // MARK: - N11: serialize stays equality-only (§5.2's boundary)

    #if os(macOS)
        @Test("a platform-boxed bold run serializes as plain text — serialize never gets Tier 2")
        func serializeStaysEqualityOnlyForNonCanonicalFonts() {
            let nsBold = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: 14, weight: .regular), toHaveTrait: .boldFontMask
            )
            var text = AttributedString("Hello")
            text.summaryBlock = .paragraph
            text.font = Font(nsBold)
            let result = SummaryRichText.serialize(text)
            #expect(result == "Hello")
        }
    #endif

    // MARK: - N12: synthesized Hashable/Sendable holds with the new stored property

    @Test("constraints with equal inputs (including fontContext) are value-equal and hash stably")
    func constraintsAreValueEqualForEqualInputs() async {
        // `SummaryFontConstraint.hash(into:)` is hand-written precisely so these assertions hold:
        // `Font.Context.hash(into:)` is THREAD-AFFINE on macOS 26.5 (the same value hashes
        // differently on the main thread vs a background thread, while `==` stays stable), so a
        // synthesized hash that included it would violate `Hashable`'s stability requirement.
        // The cross-thread assertion below is the one that fails without the custom hash.
        let context = EnvironmentValues().fontResolutionContext

        let constraintA = SummaryFontConstraint(fontContext: context)
        let constraintB = SummaryFontConstraint(fontContext: context)
        #expect(constraintA == constraintB)
        #expect(constraintA.hashValue == constraintB.hashValue)

        let onMain = await MainActor.run { constraintA.hashValue }
        let offMain = await Task.detached { constraintA.hashValue }.value
        #expect(onMain == offMain)
        #expect(onMain == constraintB.hashValue)

        // A nil context must not collide-by-accident with a live one: `==` still discriminates.
        let aNil = SummaryFontConstraint(fontContext: nil)
        let bNil = SummaryFontConstraint(fontContext: nil)
        #expect(aNil == bNil)
        #expect(aNil.hashValue == bNil.hashValue)
        #expect(aNil != constraintA)

        let inkA = SummaryInkConstraint(scheme: .dark)
        let inkB = SummaryInkConstraint(scheme: .dark)
        #expect(inkA == inkB)
        #expect(inkA.hashValue == inkB.hashValue)
    }

    // MARK: - N13: the strip constraints target exactly the unserializable keys

    @Test("the three strip constraints target exactly underline/strikethrough/backgroundColor")
    func stripConstraintsTargetExactlyTheUnserializableKeys() {
        // The `constrain(_:)` proxy has no public initializer, so exercising the constraint's
        // WRITE effect end-to-end is a manual check (plan §9, M3) — this pins the KEY each
        // constraint targets, which is what makes that manual check meaningful.
        #expect(
            SummaryNoUnderlineConstraint.AttributeKey.name
                == AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.name
        )
        #expect(
            SummaryNoStrikethroughConstraint.AttributeKey.name
                == AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute.name
        )
        #expect(
            SummaryNoHighlightConstraint.AttributeKey.name
                == AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.name
        )
    }

    // MARK: - N14: the definition constructs via (scheme:fontContext:) and its body composes

    /// A COMPILATION test, deliberately without a runtime assertion: what it pins is that the
    /// definition still constructs through `(scheme:fontContext:)` (not the removed
    /// `init(scheme:)`) and that its constraint list still satisfies the `DefinitionBuilder`
    /// parameter-pack arity. It does NOT verify how many constraints are composed — nothing
    /// public exposes that — so it would still pass if a constraint were removed; the strip
    /// constraints' presence is pinned by N13 and their effect by manual check M3.
    @Test("the definition constructs via (scheme:fontContext:) and its body type-checks")
    func definitionConstructsAndBodyTypeChecks() {
        let definition = MarginaliaSummaryFormattingDefinition(scheme: .light, fontContext: nil)
        _ = definition.body
    }
}
