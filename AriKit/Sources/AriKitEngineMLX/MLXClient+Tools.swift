//
//  MLXClient+Tools.swift — `MLXClient: ToolCapableLLMClient` (docs/plans/
//  ask-meetings-agentic-tools.md §3.5, Slice 1). The MLX ladder-rung-1 conformer for the tool-first
//  Ask pipeline; the summary path (`generate`/`stream`, MLXClient.swift) is completely untouched —
//  thinking stays off there (`additionalContext: ["enable_thinking": false]`), only `Ask` opts in.
//
//  DIVERGENCE FROM THE ORIGINAL §3.5 DESIGN (found live via `spikes/ask-tools-harness`,
//  2026-07-23): the plan's original shape let `ChatSession`'s own internal `restart:` loop
//  (ChatSession.swift:635-784) drive tool continuation via an installed `toolDispatch`. Running the
//  harness against the app's REAL default model (`mlx-community/Qwen3.5-4B-MLX-4bit`) showed that
//  design hard-errors on every tool call: that checkpoint's `chat_template.jinja` does a backward
//  scan for the last `user`-role message before rendering a tool continuation (Qwen3.5's
//  "multi_step_tool" logic) and raises `TemplateException("No user query found in messages.")`
//  when it finds none — which it never will, because `ChatSession`'s restart loop only feeds the
//  NEW `.tool(result, id:)` message into that turn's `UserInput(chat:...)` (history lives in the
//  KV cache, not the re-rendered messages). This conformer therefore drives the multi-turn loop
//  itself instead:
//
//    1. `toolDispatch` is NOT installed. Per the verified 3.31.4 behavior (ChatSession.swift:
//       756-767), when `toolDispatch == nil` the `.toolCall` `Generation` items ARE forwarded to
//       the stream consumer (only diverted away when a dispatch closure is installed) — so
//       `session.streamDetails(to:)` (raw `Generation`, not just chunk text) surfaces them to us.
//    2. Each turn is a FRESH `ChatSession` fed the FULL conversation so far (`[Chat.Message]`,
//       correctness over KV-cache reuse — acceptable given short ask prompts and
//       `RecallBounds.maxToolResultChars`-bounded tool results). This is the actual fix: every
//       turn's re-rendered message array always contains the original `.user(...)` message, so the
//       template's backward scan always finds it.
//    3. We build the next turn's `.assistant(rawText, toolCalls:)` + `.tool(result, id:)` messages
//       ourselves, mirroring exactly what `ChatSession`'s own restart loop appends
//       (ChatSession.swift:774-783), and emit `.toolStarted`/`.toolFinished` around each dispatch
//       call (there is no other observable seam once we're not using `toolDispatch`).
//    4. A turn with zero tool calls is the final answer (matches ChatSession's own "no
//       toolDispatch/no pending calls ⇒ stop" exit, ChatSession.swift:775).
//
//  `AgenticEvent`/`ToolCapableLLMClient` (§3.1, Slice 0) are UNCHANGED — this is purely an internal
//  reimplementation of how the conformer drives generation.
//
import AriKit
import Foundation
import MLXLMCommon
import os

extension MLXClient: ToolCapableLLMClient {
    private static let toolLog = Logger(
        subsystem: "com.arivo.ari.AriKitEngineMLX", category: "mlx.client.tools"
    )

    /// Thinking-mode sampling per Qwen3's model card and plan §2.5/§3.5 — deliberately fixed
    /// (not derived from `ProviderConfig`/`LLMRequest`, unlike the summary path's tunables): this
    /// is a distinct generation mode with its own proven parameters, not a variant of the summary
    /// defaults (0.5/0.8).
    static let toolTemperature: Float = 0.6
    static let toolTopP: Float = 0.95
    /// Output cap when neither the request nor a resolved config supplies one.
    static let toolDefaultMaxTokens = 4096
    /// Defensive absolute bound on our own turn loop — strictly ABOVE the dispatch side's real
    /// budget (`RecallBounds.maxAgenticIterations`, 8): the dispatch is the actual iteration-budget
    /// owner (plan §4.3) and returns an honest exhaustion string well before this fires. This is
    /// only a last-resort circuit breaker against a dispatch that (incorrectly) never honors its
    /// own budget — it must never be the normal way a loop ends.
    static let absoluteMaxTurns = 12

    /// Runs the agentic loop OURSELVES (see file header for why `ChatSession`'s own internal
    /// `restart:` continuation is not used): repeatedly builds a fresh `ChatSession` over the full
    /// conversation-so-far, collects `.chunk` text (through `ThinkTagSplitter`) and `.toolCall`
    /// items from one generation pass, dispatches every requested call, appends the resulting
    /// assistant/tool messages, and loops — until a turn requests zero tools (final answer) or the
    /// defensive `absoluteMaxTurns` bound trips.
    public func respondWithTools(
        _ request: LLMRequest,
        tools: [AgenticToolDefinition],
        dispatch: @escaping AgenticToolDispatch
    ) -> AsyncThrowingStream<AgenticEvent, Error> {
        _ = mlxRuntimeConfigured // one-time GPU cache-limit install (see MLXClient.swift)

        return AsyncThrowingStream { continuation in
            let task = Task {
                // Brackets the WHOLE multi-turn span — same discipline as `generate`/`stream`
                // (MLXClient.swift:103-212): every exit path below decrements exactly once.
                await MLXActivityTracker.shared.begin()
                do {
                    try Task.checkCancellation()
                    let container = try await self.resolveContainer()
                    let toolSpecs = try tools.map { try Self.toolSpec(for: $0) }
                    try await self.runToolLoop(
                        container: container,
                        request: request,
                        toolSpecs: toolSpecs,
                        dispatch: dispatch,
                        continuation: continuation
                    )
                    await Self.endActivityReclaimingCacheIfIdle()
                    continuation.finish()
                } catch let error as LLMError {
                    await Self.endActivityReclaimingCacheIfIdle()
                    continuation.finish(throwing: error)
                } catch {
                    await Self.endActivityReclaimingCacheIfIdle()
                    continuation.finish(throwing: LLMError.requestFailed("MLX tool-loop generation failed: \(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - The manual multi-turn loop

    private func runToolLoop(
        container: ModelContainer,
        request: LLMRequest,
        toolSpecs: [ToolSpec],
        dispatch: @escaping AgenticToolDispatch,
        continuation: AsyncThrowingStream<AgenticEvent, Error>.Continuation
    ) async throws {
        let maxTokens = request.maxTokens ?? Self.toolDefaultMaxTokens
        // `instructions:` on each fresh session supplies the system message; `conversation` never
        // duplicates it. Turn 1 is exactly the single user question (mirrors `respond`/`stream`'s
        // `session.streamResponse(to: request.user)` shape).
        var conversation: [Chat.Message] = [.user(request.user)]

        for turn in 0 ..< Self.absoluteMaxTurns {
            if Task.isCancelled {
                throw LLMError.cancelled
            }

            // Fresh `ChatSession` per turn, fed the FULL conversation so far — no `toolDispatch`
            // installed (see file header: this is the fix for the template's backward user-scan,
            // and it's also what makes `.toolCall` items visible to `streamDetails`).
            let session = ChatSession(
                container,
                instructions: request.system,
                generateParameters: GenerateParameters(
                    maxTokens: maxTokens,
                    temperature: Self.toolTemperature,
                    topP: Self.toolTopP
                ),
                // ← the reverse of the summary path's `false` (MLXClient.swift): Ask wants Qwen3's
                // `<think>` reasoning, split out by `ThinkTagSplitter` below.
                additionalContext: ["enable_thinking": true],
                tools: toolSpecs
            )

            // A FRESH splitter EVERY turn, starting `insideThink`: `additionalContext:
            // ["enable_thinking": true]` above is always on for this loop, and the real
            // Qwen3.5-4B-MLX-4bit checkpoint's chat template injects the opening `<think>` into
            // the GENERATION PROMPT rather than the completion — so the model's own output stream
            // never contains a literal opening tag, only the closing `</think>` (found live
            // 2026-07-23 via `spikes/ask-tools-harness`; see `ThinkTagSplitter`'s own doc comment
            // for the full rationale). Because each turn is an independently fresh `ChatSession`,
            // its generation prompt re-injects `<think>` every time — sharing ONE splitter across
            // turns would leave it stuck in `outsideThink` after the first turn's close and
            // misclassify every later turn's reasoning as answer text.
            var splitter = ThinkTagSplitter(startsInsideThink: true)
            // M2 (code review 2026-07-23): holds this turn's non-think text back until the turn's
            // outcome is known — a turn that goes on to request a tool call DISCARDS its held
            // chatter (e.g. "Let me check.") instead of letting it stream as answer text; only a
            // turn with zero tool calls flushes it as the real final answer. `.thinking` is
            // UNAFFECTED — it always streams live via `absorb`'s passthrough. Consequence (accepted,
            // plan review): the answer no longer token-streams on MLX — it appears once the final
            // turn completes.
            var turnAnswerBuffer = AgenticTurnAnswerBuffer()

            var rawTurnText = ""
            var pendingToolCalls: [ToolCall] = []
            for try await item in session.streamDetails(to: conversation) {
                if Task.isCancelled {
                    throw LLMError.cancelled
                }
                if let toolCall = item.toolCall {
                    pendingToolCalls.append(toolCall)
                } else if let chunk = item.chunk {
                    rawTurnText += chunk
                    for event in splitter.consume(chunk) {
                        if let toEmit = turnAnswerBuffer.absorb(event) {
                            continuation.yield(toEmit)
                        }
                    }
                }
                // `.info` (token/perf metrics) is not part of the `AgenticEvent` contract.
            }
            // Flush THIS turn's splitter unconditionally — whether it ends in a final answer or a
            // tool call, nothing this turn's generation produced should carry pending state into
            // the next turn's brand-new splitter.
            for event in splitter.flush() {
                if let toEmit = turnAnswerBuffer.absorb(event) {
                    continuation.yield(toEmit)
                }
            }
            // Resolve the turn's held-back answer text now that its outcome (tool calls or not) is
            // known (M2) — discarded if this turn requested a tool, flushed otherwise.
            if let resolved = turnAnswerBuffer.resolve(hadToolCalls: !pendingToolCalls.isEmpty) {
                continuation.yield(resolved)
            }

            guard !pendingToolCalls.isEmpty else {
                // Zero tool calls this turn ⇒ final answer (mirrors ChatSession's own exit,
                // ChatSession.swift:775).
                return
            }

            Self.toolLog.info(
                "MLX tool turn \(turn, privacy: .public): \(pendingToolCalls.count, privacy: .public) call(s): \(pendingToolCalls.map(\.function.name).joined(separator: ","), privacy: .public)"
            )

            // Mirrors exactly what ChatSession's own restart loop appends per turn
            // (ChatSession.swift:774-783): the assistant's raw turn text (untouched — the chat
            // template does its own <think>/content split when re-rendering history) plus its
            // tool-call markup, then one `.tool(result, id:)` message per call.
            conversation.append(.assistant(rawTurnText, toolCalls: pendingToolCalls))
            for toolCall in pendingToolCalls {
                try await conversation.append(.tool(
                    Self.dispatchAndReport(toolCall, dispatch: dispatch, continuation: continuation),
                    id: toolCall.id
                ))
            }
        }

        // The dispatch side owns the real ≤`RecallBounds.maxAgenticIterations` (8) budget (plan
        // §4.3) and should have already returned an honest exhaustion string well before this
        // fires — reaching it means a dispatch conformer didn't honor its own budget. Throwing
        // (never fabricating a final answer) keeps this an honest failure, not silent truncation.
        throw LLMError.requestFailed(
            "MLX tool loop exceeded its defensive \(Self.absoluteMaxTurns)-turn bound without a final answer"
        )
    }

    /// Dispatches one requested tool call, emitting `.toolStarted`/`.toolFinished` around it (the
    /// only place tool activity is observable now that we drive the loop ourselves) and never
    /// throwing back into the turn loop — a dispatch or argument-encoding failure degrades to an
    /// honest `"Tool failed: …"` result string instead (plan §4.3).
    private static func dispatchAndReport(
        _ toolCall: ToolCall,
        dispatch: @escaping AgenticToolDispatch,
        continuation: AsyncThrowingStream<AgenticEvent, Error>.Continuation
    ) async throws -> String {
        let name = toolCall.function.name
        continuation.yield(.toolStarted(name: name))

        let argumentsJSON: String
        do {
            argumentsJSON = try Self.encodeArguments(toolCall.function.arguments)
        } catch {
            continuation.yield(.toolFinished(name: name, ok: false))
            return "Tool failed: could not encode arguments (\(error))"
        }

        let call = AgenticToolCall(
            id: toolCall.id ?? UUID().uuidString,
            name: name,
            argumentsJSON: argumentsJSON
        )
        do {
            let result = try await dispatch(call)
            // M1: `dispatch` never throws for a tool-level failure (plan §4.3) — the ACTUAL
            // outcome lives only in the result string's fixed prefix (`AgenticToolResultPrefix`),
            // so `ok:` must be derived from it rather than hardcoded `true`.
            continuation.yield(.toolFinished(name: name, ok: !AgenticToolOutcome.isFailure(result)))
            return result
        } catch {
            // `AgenticToolDispatch` documents itself as "must not throw for tool-level failures"
            // — this catch is defense-in-depth so a conformer that DOES throw still degrades to an
            // honest string instead of aborting our turn loop.
            continuation.yield(.toolFinished(name: name, ok: false))
            return "Tool failed: \(error)"
        }
    }

    private static func encodeArguments(_ arguments: [String: JSONValue]) throws -> String {
        let data = try JSONEncoder().encode(arguments)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LLMError.requestFailed("Tool arguments could not be decoded as UTF-8 JSON")
        }
        return json
    }

    // MARK: - Tool-schema decoding

    /// Decodes one `AgenticToolDefinition.parametersJSONSchema` (already a JSON-schema object,
    /// e.g. `{"type":"object","properties":{...},"required":[...]}`) into the OpenAI-style
    /// `ToolSpec` dict `ChatSession`/mlx-swift-lm expects: `{"type":"function","function":
    /// {"name":…,"description":…,"parameters":…}}`.
    private static func toolSpec(for definition: AgenticToolDefinition) throws -> ToolSpec {
        guard let data = definition.parametersJSONSchema.data(using: .utf8) else {
            throw LLMError.requestFailed(
                "Tool \"\(definition.name)\" has a non-UTF8 parameter schema"
            )
        }
        let decoded: JSONValue
        do {
            decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw LLMError.requestFailed(
                "Tool \"\(definition.name)\" parameter schema is not valid JSON: \(error)"
            )
        }
        guard case let .object(parameters) = decoded else {
            throw LLMError.requestFailed(
                "Tool \"\(definition.name)\" parameter schema must be a JSON object"
            )
        }

        let parametersDict = parameters.mapValues(Self.sendableSchemaValue)
        return [
            "type": "function",
            "function": [
                "name": definition.name,
                "description": definition.description,
                "parameters": parametersDict
            ] as [String: any Sendable]
        ]
    }

    /// Recursively converts a decoded JSON-schema `JSONValue` tree into the plain Swift
    /// `any Sendable` values `ToolSpec` is built from (`JSONValue.sendableValue` does the same
    /// job but is package-internal to mlx-swift-lm, not visible here).
    private static func sendableSchemaValue(_ value: JSONValue) -> any Sendable {
        switch value {
        case .null:
            NSNull()
        case let .bool(bool):
            bool
        case let .int(int):
            int
        case let .double(double):
            double
        case let .string(string):
            string
        case let .array(items):
            items.map(sendableSchemaValue)
        case let .object(object):
            object.mapValues(sendableSchemaValue)
        }
    }
}
