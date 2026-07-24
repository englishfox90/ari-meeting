//
//  SummaryRichTextSerializerTests.swift — AttributedString → markdown serialization + the
//  full round-trip fidelity suite (`docs/plans/rich-summary-editor.md` §2.3, §5 tests 13-26).
//
//  "Round trip" here is document-level (`SummaryEditDocument.make(from:).serialized()`), so
//  the same helper covers prose-only fixtures and the table-bearing corpus fixture alike —
//  tables pass through as verbatim slabs regardless.
//
import SwiftUI
import Testing
@testable import AriKit

@Suite("SummaryRichText serializer + round-trip fidelity")
struct SummaryRichTextSerializerTests {
    private func roundTrip(_ markdown: String) -> String {
        SummaryEditDocument.make(from: markdown).serialized()
    }

    // MARK: - 13-19: per-construct round trips

    @Test("headings round-trip at every level 1...6")
    func roundTripHeadingEachLevel() {
        for level in 1 ... 6 {
            let markdown = String(repeating: "#", count: level) + " Title"
            #expect(roundTrip(markdown) == markdown)
        }
    }

    @Test("a paragraph's internal hard breaks survive the round trip")
    func roundTripParagraphWithHardBreaks() {
        let markdown = "First line\nline two"
        #expect(roundTrip(markdown) == markdown)
    }

    @Test("a bullet list round-trips byte-identical")
    func roundTripBulletList() {
        let markdown = "- First item\n- Second item"
        #expect(roundTrip(markdown) == markdown)
    }

    @Test("a numbered list renumbers from 1 on round trip, dropping source numbering")
    func roundTripNumberedListRenumbers() {
        let markdown = "3. Alpha\n5. Beta"
        let result = roundTrip(markdown)
        #expect(result != markdown)
        #expect(result == "1. Alpha\n2. Beta")
    }

    @Test("bold, italic, and bold+italic combined round-trip")
    func roundTripBoldItalicCombined() {
        let markdown = "**bold** *italic* ***both*** plain"
        #expect(roundTrip(markdown) == markdown)
    }

    @Test("citations round-trip byte-identical in every marker form")
    func roundTripCitationsByteIdentical() {
        let markdown = "Times: [03:09], @ref(04:10), and @mref(m3@05:11) matter."
        #expect(roundTrip(markdown) == markdown)
    }

    @Test("a realistic mixed summary corpus (heading, paragraph, list, table, citation) round-trips structurally")
    func roundTripMixedRealSummaryCorpus() {
        let result = roundTrip(Self.mixedCorpusFixture)
        #expect(MarginaliaMarkdown.parse(result) == MarginaliaMarkdown.parse(Self.mixedCorpusFixture))
        #expect(result.contains("| Amy | Register state | N/A |"))
    }

    // MARK: - 20-21: the load-bearing fidelity invariants

    @Test("round trip is block-stable: parse(roundTrip(md)) == parse(md), for every fixture")
    func roundTripIsBlockStable() {
        for fixture in Self.allFixtures {
            let result = roundTrip(fixture)
            #expect(
                MarginaliaMarkdown.parse(result) == MarginaliaMarkdown.parse(fixture),
                "block mismatch for fixture: \(fixture)"
            )
        }
    }

    @Test("the canonical form is a fixed point: roundTrip(roundTrip(md)) == roundTrip(md)")
    func canonicalFormIsFixedPoint() {
        for fixture in Self.allFixtures {
            let once = roundTrip(fixture)
            let twice = roundTrip(once)
            #expect(twice == once, "not a fixed point for fixture: \(fixture)")
        }
    }

    @Test("two blank-line-separated same-kind lists stay two lists (no silent merge)")
    func adjacentSameKindListsDoNotMerge() {
        // Bullets: two one-item lists must survive as two blocks, not one two-item list.
        let bullets = "- a\n\n- b"
        #expect(roundTrip(bullets) == bullets)
        #expect(MarginaliaMarkdown.parse(roundTrip(bullets)).count == 2)

        // Numbered: each sibling list restarts its numbering from 1.
        let numbered = "1. a\n2. b\n\n1. c"
        #expect(roundTrip(numbered) == numbered)
        let blocks = MarginaliaMarkdown.parse(roundTrip(numbered))
        #expect(blocks == [.numberedList(["a", "b"]), .numberedList(["c"])])
    }

    @Test("adjacent same-emphasis runs canonicalize (accepted, documented — not block-stable)")
    func acceptedEmphasisCanonicalization() {
        // §2.3 intent: `**a****b**` never appears — adjacent same-emphasis runs coalesce. This
        // rewrites the paragraph STRING, so it is deliberately NOT in `allFixtures` (it is not
        // block-stable: the parser stores emphasis markers verbatim). It IS a fixed point, so a
        // stored summary tidies at most once, and the deferred backfill's verify-before-write
        // (parse-equal) would simply skip such a row rather than rewrite it.
        #expect(roundTrip("**a****b**") == "**ab**")
        #expect(roundTrip(roundTrip("**a****b**")) == roundTrip("**a****b**")) // fixed point
    }

    // MARK: - 22-26: no-loss + attribute-authoritative + degenerate inputs

    @Test("unrecognized constructs (fenced code, blockquote, `#foo`) survive as literal paragraph text")
    func noSilentContentLossForUnrecognizedConstructs() {
        let fencedCode = "```\ncode here\n```"
        #expect(roundTrip(fencedCode) == fencedCode)

        let blockquote = "> a blockquote line"
        #expect(roundTrip(blockquote) == blockquote)

        let pseudoHeading = "#foo not a heading"
        #expect(roundTrip(pseudoHeading) == pseudoHeading)
    }

    @Test("a paragraph with no \\.summaryBlock attribute serializes as a plain paragraph")
    func unstampedParagraphSerializesAsParagraph() {
        let text = AttributedString("just plain text, no attribute")
        #expect(SummaryRichText.serialize(text) == "just plain text, no attribute")
    }

    @Test("an Enter-continued bullet paragraph with no literal marker text still serializes as a list item")
    func inheritedBulletKindWithoutMarkerTextStillSerializesAsListItem() {
        var first = AttributedString("First item")
        first.summaryBlock = .bulletItem
        var second = AttributedString("Continued without a visible marker")
        second.summaryBlock = .bulletItem // inherited by Enter, never given a literal "•\t"

        var document = first
        document += AttributedString("\n")
        document += second

        let serialized = SummaryRichText.serialize(document)
        #expect(serialized == "- First item\n- Continued without a visible marker")
    }

    @Test("at most one leading marker is stripped; a second literal marker stays as content")
    func markerStrippedAtMostOnce() {
        let presented = SummaryRichText.present([.bulletList(["• second marker stays"])])
        let serialized = SummaryRichText.serialize(presented)
        #expect(serialized == "- • second marker stays")
    }

    @Test("degenerate inputs never crash and round-trip sanely")
    func degenerateInputs() {
        #expect(roundTrip("").isEmpty)
        #expect(roundTrip("   \n\n  \n").isEmpty)
        #expect(roundTrip("para\n\n\n\n") == "para")
        #expect(roundTrip("[03:09]") == "[03:09]")
    }

    // MARK: - Fixtures

    private static let mixedCorpusFixture = """
    # Team Sync

    We discussed the roadmap and **next steps** for Q3.

    - Ship the *rich editor*
    - Review citations [03:09]

    ## Action Items

    | Owner | Task | Due |
    | --- | --- | --- |
    | Amy | Register state | N/A |
    | Taylor | Send projections | N/A |

    Thanks everyone, see @ref(12:45) for the recap.
    """

    private static let allFixtures: [String] = [
        "# Title",
        "###### Deep heading",
        "First line\nline two",
        "- First item\n- Second item",
        "3. Alpha\n5. Beta",
        // Two SIBLING lists of the same kind, blank-line separated — must NOT merge into one
        // list on reparse (the block-stable-invariant hole the reviewer found).
        "- a\n\n- b",
        "- a\n\n- b\n\n- c",
        "1. a\n2. b\n\n1. c",
        // Different-kind adjacent lists: the parser stops at the kind switch, so they never
        // merge; still worth pinning that the round trip keeps them two blocks.
        "- a\n\n1. b",
        "**bold** *italic* ***both*** plain",
        "Times: [03:09], @ref(04:10), and @mref(m3@05:11) matter.",
        mixedCorpusFixture,
        "```\ncode here\n```",
        "> a blockquote line",
        "#foo not a heading",
        "",
        "   \n\n  \n",
        "para\n\n\n\n",
        "[03:09]"
    ]
}
