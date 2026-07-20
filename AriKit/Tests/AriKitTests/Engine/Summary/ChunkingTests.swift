//
//  ChunkingTests.swift — plan §6 Slice F (← summary/processor.rs; the Rust file itself carries no
//  `#[cfg(test)]` coverage for `rough_token_count`/`chunk_text`/`clean_llm_markdown_output`/
//  `extract_meeting_name_from_markdown`, so these are new tests written directly against the
//  ported behavior, with exact expected chunk boundaries verified against a reference
//  reimplementation of the algorithm before being hard-coded here).
//
import Testing
@testable import AriKit

struct ChunkingTests {

    // MARK: - roughTokenCount

    @Test func roughTokenCountOfEmptyStringIsZero() {
        #expect(Chunking.roughTokenCount("") == 0)
    }

    @Test func roughTokenCountUsesPointThreeFiveMultiplierCeiled() {
        // ceil(1 * 0.35) = 1
        #expect(Chunking.roughTokenCount("a") == 1)
        // ceil(10 * 0.35) = ceil(3.5) = 4
        #expect(Chunking.roughTokenCount(String(repeating: "a", count: 10)) == 4)
        // ceil(100 * 0.35) = 35 (exact)
        #expect(Chunking.roughTokenCount(String(repeating: "a", count: 100)) == 35)
    }

    // MARK: - chunkText: empty / degenerate inputs

    @Test func chunkTextOfEmptyStringReturnsEmptyArray() {
        #expect(Chunking.chunkText("", chunkSizeTokens: 100, overlapTokens: 10).isEmpty)
    }

    @Test func chunkTextWithZeroChunkSizeReturnsEmptyArray() {
        #expect(Chunking.chunkText("hello world", chunkSizeTokens: 0, overlapTokens: 10).isEmpty)
    }

    // MARK: - chunkText: single chunk when under size

    @Test func chunkTextShorterThanChunkSizeReturnsSingleUnmodifiedChunk() {
        let text = "Hello world, this is a short piece of text."
        let chunks = Chunking.chunkText(text, chunkSizeTokens: 1000, overlapTokens: 100)
        #expect(chunks == [text])
    }

    // MARK: - chunkText: multi-chunk, no overlap, word-boundary break

    @Test func chunkTextSplitsOnWordBoundaryWithNoOverlap() {
        // 54-char text, 5 groups of "0123456789" separated by single spaces.
        let text = "0123456789 0123456789 0123456789 0123456789 0123456789"
        // chunkSizeTokens=7 -> chunkSizeChars = ceil(7 * 20/7) = 20 exactly; overlapTokens=0.
        let chunks = Chunking.chunkText(text, chunkSizeTokens: 7, overlapTokens: 0)
        // Note: even with `overlapTokens: 0`, the word-boundary break can still let adjacent
        // windows share a character or two (the boundary search looks *backward* from the raw
        // window edge, but `startChar` still advances by the full non-overlapping `step`) — this
        // matches the Rust algorithm exactly, verified against a reference reimplementation.
        #expect(chunks == ["0123456789 ", "9 0123456789 ", "789 0123456789"])
    }

    // MARK: - chunkText: multi-chunk WITH overlap

    @Test func chunkTextSplitsWithOverlapBetweenWindows() {
        let text = "0123456789 0123456789 0123456789 0123456789 0123456789"
        // chunkSizeTokens=7 -> chunkSizeChars=20; overlapTokens=1 -> overlapChars=ceil(20/7)=3;
        // step = max(20-3, 1) = 17.
        let chunks = Chunking.chunkText(text, chunkSizeTokens: 7, overlapTokens: 1)
        #expect(chunks == ["0123456789 ", "6789 0123456789 ", "123456789 0123456789"])
        // Verify the overlap is real: chunk 1 ends with the same text chunk 2 starts with.
        #expect(chunks[0].hasSuffix("6789 "))
        #expect(chunks[1].hasPrefix("6789"))
    }

    // MARK: - chunkText: sentence-boundary break preferred over word-boundary

    @Test func chunkTextPrefersSentenceBoundaryOverWordBoundary() {
        let text = "Hello world. Next sentence here. Another one continues on and on further out yonder."
        let chunks = Chunking.chunkText(text, chunkSizeTokens: 7, overlapTokens: 0)
        #expect(chunks.count > 1)
        // The first chunk breaks right after the ". " following "Hello world", not mid-word.
        #expect(chunks[0] == "Hello world. ")
    }

    // MARK: - cleanLLMMarkdownOutput

    @Test func cleanLLMMarkdownOutputStripsThinkTags() {
        let raw = "<think>internal reasoning here</think># Title\n\nBody text."
        #expect(Chunking.cleanLLMMarkdownOutput(raw) == "# Title\n\nBody text.")
    }

    @Test func cleanLLMMarkdownOutputStripsThinkingTagsAcrossNewlines() {
        let raw = "<thinking>\nmulti\nline\nreasoning\n</thinking>\n# Title\nBody"
        #expect(Chunking.cleanLLMMarkdownOutput(raw) == "# Title\nBody")
    }

    @Test func cleanLLMMarkdownOutputStripsMarkdownCodeFence() {
        let raw = "```markdown\n# Title\n\nBody text.\n```"
        #expect(Chunking.cleanLLMMarkdownOutput(raw) == "# Title\n\nBody text.")
    }

    @Test func cleanLLMMarkdownOutputStripsBareCodeFence() {
        let raw = "```\n# Title\n\nBody text.\n```"
        #expect(Chunking.cleanLLMMarkdownOutput(raw) == "# Title\n\nBody text.")
    }

    @Test func cleanLLMMarkdownOutputLeavesPlainMarkdownUntouched() {
        let raw = "# Title\n\nBody text."
        #expect(Chunking.cleanLLMMarkdownOutput(raw) == raw)
    }

    @Test func cleanLLMMarkdownOutputTrimsSurroundingWhitespace() {
        let raw = "\n\n  # Title\n\nBody text.  \n\n"
        #expect(Chunking.cleanLLMMarkdownOutput(raw) == "# Title\n\nBody text.")
    }

    // MARK: - extractMeetingName

    @Test func extractMeetingNameFromFirstHeading() {
        let markdown = "# The Quarterly Planning Meeting\n\n**Summary**\n\nBody."
        #expect(Chunking.extractMeetingName(fromMarkdown: markdown) == "The Quarterly Planning Meeting")
    }

    @Test func extractMeetingNameSkipsToFirstMatchingLine() {
        let markdown = "Some preamble\nMore preamble\n# Real Title\nBody"
        #expect(Chunking.extractMeetingName(fromMarkdown: markdown) == "Real Title")
    }

    @Test func extractMeetingNameReturnsNilWhenNoHeadingPresent() {
        let markdown = "Just some prose.\nNo heading here."
        #expect(Chunking.extractMeetingName(fromMarkdown: markdown) == nil)
    }
}
