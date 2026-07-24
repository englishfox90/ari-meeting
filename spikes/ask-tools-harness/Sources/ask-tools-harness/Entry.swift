// ask-tools-harness — throwaway Slice 1 risk-validation spike CLI.
//
// docs/plans/ask-meetings-agentic-tools.md §9 risks 1/2/5: does the real, on-device
// Qwen3.5-4B-MLX-4bit model (a) call the right dummy tool for tool-shaped questions, (b) stay
// silent (no tool call) for small talk, (c) actually reach a final answer after a tool call (the
// live TemplateException finding, 2026-07-23 — see MLXClient+Tools.swift's header), with
// `enable_thinking: true` turned on the whole time?
//
// Calls the PRODUCTION `MLXClient.respondWithTools` directly (via a local path dependency on
// ../../AriKit) — this harness exercises the exact conformer Slice 2 builds on, not a duplicate of
// its logic.
//
// Reuses the already-downloaded HF cache at ~/.cache/huggingface/hub (the app's own model store)
// — never triggers a fresh multi-GB download. If the model isn't cached, this SKIPS the run and
// reports why, rather than downloading.
//
// Usage: ask-tools-harness [--max-tokens N]

import AriKit
import AriKitEngineMLX
import Foundation

let defaultModelID = "mlx-community/Qwen3.5-4B-MLX-4bit"

// MARK: - Dummy tools

struct DummyTool {
    let name: String
    let description: String
    let parametersJSONSchema: String
    /// Canned result text returned to the model regardless of the arguments it passed — this
    /// harness measures ROUTING (did it call the right tool) and LOOP COMPLETION (does a final
    /// answer land), not argument-extraction fidelity.
    let cannedResult: String

    var definition: AgenticToolDefinition {
        AgenticToolDefinition(name: name, description: description, parametersJSONSchema: parametersJSONSchema)
    }
}

let todaysEventsTool = DummyTool(
    name: "todays_events",
    description: "Look up events on the user's calendar for today, optionally filtered by hour or attendee.",
    parametersJSONSchema: """
    {"type":"object","properties":{"hour":{"type":"integer","description":"Hour 0-23 to filter to, e.g. 18 for 6pm"},"attendee":{"type":"string","description":"Attendee name or email to filter to"}},"required":[]}
    """,
    cannedResult: """
    [S-cal] "Q3 Planning Sync" today 18:00-18:30, attendees: Landon Star, Priya Chen. Not yet recorded.
    """
)

let searchTranscriptsTool = DummyTool(
    name: "search_transcripts",
    description: "Search the user's past meeting transcripts for relevant excerpts.",
    parametersJSONSchema: """
    {"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}
    """,
    cannedResult: """
    [S1] "Landon 1:1" (2026-07-10) — "We agreed the migration would land by end of month, Landon owns the timeline."
    """
)

let allTools = [todaysEventsTool, searchTranscriptsTool]

// MARK: - Canned questions

enum Expectation: String {
    case todaysEvents = "todays_events"
    case searchTranscripts = "search_transcripts"
    case none = "(no tool)"
}

struct CannedQuestion {
    let text: String
    let expect: Expectation
}

let questions: [CannedQuestion] = [
    // Should call todays_events
    CannedQuestion(text: "Who is in the 6pm meeting later today?", expect: .todaysEvents),
    CannedQuestion(text: "What's on my calendar for today?", expect: .todaysEvents),
    CannedQuestion(text: "Do I have anything scheduled this afternoon?", expect: .todaysEvents),
    CannedQuestion(text: "Is Priya in any of my meetings today?", expect: .todaysEvents),
    // Should call search_transcripts
    CannedQuestion(text: "What did we decide about the migration timeline with Landon?", expect: .searchTranscripts),
    CannedQuestion(text: "Remind me what was discussed in my last 1:1 with Landon.", expect: .searchTranscripts),
    CannedQuestion(text: "Did anyone mention the Q3 budget in a past meeting?", expect: .searchTranscripts),
    CannedQuestion(text: "Find the meeting where we talked about hiring a new engineer.", expect: .searchTranscripts),
    // Small talk — should call nothing
    CannedQuestion(text: "Hi there, how are you?", expect: .none),
    CannedQuestion(text: "Thanks, that's helpful.", expect: .none),
    CannedQuestion(text: "What's 2 + 2?", expect: .none),
    CannedQuestion(text: "Tell me a fun fact about octopuses.", expect: .none)
]

// MARK: - Per-question call log

actor CallLog {
    private(set) var calls: [String] = []
    /// Mirrors the REAL iteration budget Slice 2's `AskToolset.dispatch` will enforce
    /// (`RecallBounds.maxAgenticIterations`, 8) — this harness's dummy dispatch had no budget at
    /// all, which let one canned-result-repeating question spin past this file's defensive
    /// 12-turn circuit breaker (a harness artifact of always returning an identical string
    /// regardless of arguments, not a bug in `MLXClient`'s manual loop). Enforcing the same real
    /// budget here makes the harness a faithful stand-in for the production dispatch shape.
    func recordAndCheckBudget(_ name: String) -> Bool {
        calls.append(name)
        return calls.count <= RecallBounds.maxAgenticIterations
    }
}

// MARK: - Per-question result

struct QuestionResult {
    let question: CannedQuestion
    let toolsCalled: [String]
    /// A proxy for turn count: one entry per dispatched tool call (each real turn in
    /// `MLXClient`'s manual loop dispatches every tool call it received that generation pass, so
    /// for these single-tool-per-turn canned questions this equals turn count; a genuinely
    /// multi-tool-per-turn model response would undercount turns here — noted as a proxy, not
    /// exact instrumentation of the private loop).
    let toolCallCount: Int
    let thinkingPresent: Bool
    let thinkingText: String
    let answer: String
    let error: String?
    let wallClockMs: Double
    /// True only when the loop actually reached a final `.done`-equivalent (the stream finished
    /// without throwing) — the exact thing the 2026-07-23 TemplateException finding broke.
    let completedToFinalAnswer: Bool

    var routedCorrectly: Bool {
        switch question.expect {
        case .none:
            toolsCalled.isEmpty
        case .todaysEvents, .searchTranscripts:
            toolsCalled.contains(question.expect.rawValue)
        }
    }
}

// MARK: - Cache presence check (never trigger a fresh download)

func isModelCached(repoId: String) -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let folderName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
    let snapshotsDir = home
        .appendingPathComponent(".cache/huggingface/hub/\(folderName)/snapshots")
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path),
          let firstSnapshot = entries.first
    else {
        return false
    }
    let snapshotPath = snapshotsDir.appendingPathComponent(firstSnapshot)
    // A real snapshot has weights + config, not just an empty dir from an interrupted download.
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: snapshotPath.path) else {
        return false
    }
    let hasWeights = files.contains { $0.hasSuffix(".safetensors") }
    let hasConfig = files.contains { $0 == "config.json" }
    return hasWeights && hasConfig
}

// MARK: - Main

@main
struct AskToolsHarness {
    static func main() async {
        let args = CommandLine.arguments
        var maxTokens = 512
        if let idx = args.firstIndex(of: "--max-tokens"), idx + 1 < args.count,
           let v = Int(args[idx + 1]) {
            maxTokens = v
        }

        guard isModelCached(repoId: defaultModelID) else {
            print("SKIP: \(defaultModelID) is not present in ~/.cache/huggingface/hub — this harness")
            print("never triggers a fresh multi-GB download. Run the app once (or the S1 spike) to")
            print("warm the cache, then re-run this harness.")
            exit(0)
        }

        await run(maxTokens: maxTokens)
    }

    static func run(maxTokens: Int) async {
        FileHandle.standardError
            .write("[ask-tools-harness] using \(defaultModelID) (cached), production MLXClient.respondWithTools ...\n"
                .data(using: .utf8)!)

        let config = ProviderConfig(kind: .mlx, model: defaultModelID, maxTokens: maxTokens)
        let client = MLXClient(config: config)
        let definitions = allTools.map(\.definition)

        var results: [QuestionResult] = []
        for question in questions {
            let result = await runOne(question: question, client: client, definitions: definitions)
            results.append(result)
            print("")
            print("Q: \(question.text)")
            print("  expected:  \(question.expect.rawValue)")
            print("  called:    \(result.toolsCalled.isEmpty ? "(none)" : result.toolsCalled.joined(separator: ", "))")
            print("  tool calls (turn proxy): \(result.toolCallCount)")
            print("  thinking:  \(result.thinkingPresent)")
            if result.thinkingPresent {
                let thinkingSnippet = result.thinkingText.prefix(220)
                print("  thinking text: \(thinkingSnippet)\(result.thinkingText.count > 220 ? "…" : "")")
            }
            print("  wall-clock: \(Int(result.wallClockMs))ms")
            print("  completed to final answer: \(result.completedToFinalAnswer)")
            if let error = result.error {
                print("  ERROR: \(error)")
            } else {
                let containsCloseTag = result.answer.contains("</think>")
                print("  answer contains </think>: \(containsCloseTag)")
                let snippet = result.answer.prefix(200)
                print("  answer:    \(snippet)\(result.answer.count > 200 ? "…" : "")")
            }
            print("  routed \(result.routedCorrectly ? "CORRECTLY" : "INCORRECTLY")")
        }

        printSummary(results)
    }

    static func runOne(
        question: CannedQuestion,
        client: MLXClient,
        definitions: [AgenticToolDefinition]
    ) async -> QuestionResult {
        let system = """
        You are Ari, a private meeting assistant. You have tools. Use them when the question \
        concerns the user's meetings, people, or today's calendar; answer directly without tools \
        for greetings/small talk. Never invent facts you don't have from a tool result.
        """
        let request = LLMRequest(system: system, user: question.text)

        let log = CallLog()
        let dispatch: AgenticToolDispatch = { call in
            guard await log.recordAndCheckBudget(call.name) else {
                return "Tool budget exhausted. Answer now from the information you already have."
            }
            switch call.name {
            case todaysEventsTool.name:
                return todaysEventsTool.cannedResult
            case searchTranscriptsTool.name:
                return searchTranscriptsTool.cannedResult
            default:
                return "Unknown tool: \(call.name)"
            }
        }

        var thinkingText = ""
        var answer = ""
        var errorText: String?
        var completed = false

        let clock = ContinuousClock()
        let start = clock.now
        do {
            for try await event in client.respondWithTools(request, tools: definitions, dispatch: dispatch) {
                switch event {
                case let .thinking(text):
                    thinkingText += text
                case let .answerDelta(text):
                    answer += text
                case .toolStarted, .toolFinished:
                    break
                }
            }
            completed = true
        } catch {
            errorText = "\(error)"
        }
        let elapsedMs = Double((clock.now - start).components.seconds) * 1000
            + Double((clock.now - start).components.attoseconds) / 1e15
        let toolsCalled = await log.calls

        return QuestionResult(
            question: question,
            toolsCalled: toolsCalled,
            toolCallCount: toolsCalled.count,
            thinkingPresent: !thinkingText.isEmpty,
            thinkingText: thinkingText,
            answer: answer,
            error: errorText,
            wallClockMs: elapsedMs,
            completedToFinalAnswer: completed
        )
    }

    static func printSummary(_ results: [QuestionResult]) {
        print("")
        print(String(repeating: "=", count: 72))
        print("SUMMARY")
        print(String(repeating: "=", count: 72))
        let correct = results.filter(\.routedCorrectly).count
        let completed = results.filter(\.completedToFinalAnswer).count
        for result in results {
            let routeMark = result.routedCorrectly ? "ROUTE-OK  " : "ROUTE-FAIL"
            let doneMark = result.completedToFinalAnswer ? "DONE" : "NEVER-FINISHED"
            print(
                "[\(routeMark)] [\(doneMark)] expect=\(result.question.expect.rawValue) called=\(result.toolsCalled) wallClock=\(Int(result.wallClockMs))ms"
            )
        }
        print("")
        print("Routing: \(correct)/\(results.count) correct")
        print("Completed to a final answer: \(completed)/\(results.count)")
        let thinkingSeen = results.contains(where: \.thinkingPresent)
        print("Non-empty .thinking events observed in at least one response: \(thinkingSeen)")

        let goNoGo = (correct >= 8 && completed == results.count) ? "GO" : "NO-GO"
        print("")
        print(
            "VERDICT: \(goNoGo) (bars: >= 8/\(results.count) correct routing AND every question reaches a final answer)"
        )
        if goNoGo == "NO-GO" {
            if completed != results.count {
                print("Tool-invoking turns are not completing to a final answer — see MLXClient+Tools.swift's")
                print("header for the manual-loop fix already applied; if this still fails, the loop itself")
                print("needs further investigation before Slice 2 can rely on ladder rung 1.")
            }
            if correct < 8 {
                print("Mitigation per plan §9 risk 1: ship Ask with enable_thinking:false first (tools")
                print("still work; thinking UI becomes a later toggle).")
            }
        }
    }
}
