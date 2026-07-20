//
//  PlaceholderTimestampStripTests.swift — plan §6 Slice D.
//
//  1:1 port of `ari-engine/src/apple/text_cleanup.rs`'s `#[cfg(test)] mod tests` — same cases, same
//  expected outputs. Pure; no process, no live model.
//
import Testing
@testable import AriKit

struct PlaceholderTimestampStripTests {
    @Test func removesBareAndWrappedPlaceholders() {
        #expect(
            PlaceholderTimestampCleanup.strip("Integrate MCP for ticket data analysis (MM:SS).")
                == "Integrate MCP for ticket data analysis."
        )
        #expect(
            PlaceholderTimestampCleanup.strip("Decision made [MM:SS] about scope.")
                == "Decision made about scope."
        )
        #expect(
            PlaceholderTimestampCleanup.strip("Ran long HH:MM:SS overall")
                == "Ran long overall"
        )
    }

    @Test func cleansMarkdownTableCellsWithoutBreakingStructure() {
        let input = "| Caleb | Explore MCP | [MM:SS] | [MM:SS] | [MM:SS] |"
        // The placeholder cells become blank; pipes/structure remain intact.
        #expect(PlaceholderTimestampCleanup.strip(input) == "| Caleb | Explore MCP | | | |")
    }

    @Test func preservesRealDigitTimestamps() {
        let input = "Kickoff [12:03] and wrap at [1:02:15]."
        #expect(PlaceholderTimestampCleanup.strip(input) == input)
    }

    @Test func preservesNewlinesAndBlankLines() {
        let input = "Line one (MM:SS)\n\n- bullet [MM:SS]\n"
        #expect(PlaceholderTimestampCleanup.strip(input) == "Line one\n\n- bullet\n")
    }

    @Test func leavesOrdinaryTextUntouched() {
        let input = "No timestamps here — just a normal sentence with times like 3:30 PM."
        #expect(PlaceholderTimestampCleanup.strip(input) == input)
    }

    @Test func doesNotTouchNonTimeColons() {
        // "MS:" style acronyms without the time shape must survive.
        let input = "Owner: Bob; Status: done"
        #expect(PlaceholderTimestampCleanup.strip(input) == input)
    }
}
