//
//  AgenticTooling.swift — the engine-neutral tool-calling contract for tool-first Ask Meetings
//  (docs/plans/ask-meetings-agentic-tools.md §3.1, Slice 0 — the FROZEN inter-slice contract).
//
//  `AriKit` cannot import `MLXLMCommon` (core stays Metal-toolchain-free, ProviderFactory.swift),
//  so tool definitions/calls/events are plain Sendable values here; `AriKitEngineMLX` adapts them
//  to mlx-swift-lm's `ToolSpec`/`ToolCall`, and the prompt-JSON ladder rung prints them verbatim.
//
//  Do not extend these shapes casually: Slice 1 (MLX loop) and Slice 2 (RecallEngine
//  orchestration) both build against them in parallel — signature changes require touching both.
//
import Foundation

/// One declared tool: name + description + JSON-schema parameters, engine-neutral.
public struct AgenticToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON-encoded parameter schema (`{"type":"object","properties":{…},"required":[…]}`).
    /// A `String` (not `[String: Any]`) keeps this Sendable/Equatable; the MLX conformer decodes
    /// it into a `ToolSpec` dict, the prompt-JSON path prints it verbatim.
    public var parametersJSONSchema: String

    public init(name: String, description: String, parametersJSONSchema: String) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

/// One tool invocation the model requested. Arguments arrive as a JSON object string; each tool
/// decodes its own typed `Input` via Codable (never a stringly free-for-all downstream).
public struct AgenticToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Executes one requested tool call and returns the result text fed back to the model.
/// Implementations must not throw for tool-level failures — they return an honest
/// "Tool failed: …" string so the model can recover (plan §4.3); a thrown error aborts the loop.
public typealias AgenticToolDispatch = @Sendable (AgenticToolCall) async throws -> String

/// Events from a tool-capable generation. `.thinking` carries reasoning text (already stripped
/// of `<think>` tags); `.answerDelta` carries user-visible answer text. `.toolStarted` /
/// `.toolFinished` are emitted by the CLIENT around each dispatch invocation — they are the only
/// observable tool activity, because mlx-swift-lm's `ChatSession` diverts `.toolCall` generations
/// away from the stream consumer when a `toolDispatch` is installed (plan §2.4).
public enum AgenticEvent: Sendable, Equatable {
    case thinking(String)
    case answerDelta(String)
    case toolStarted(name: String)
    case toolFinished(name: String, ok: Bool)
}

/// Optional refinement of `LLMClient` — NO existing conformer changes. The recall orchestrator
/// downcasts (`client as? any ToolCapableLLMClient`) to pick the native tool loop (ladder rung 1,
/// plan §4.4); only `MLXClient` adopts this in the current plan.
public protocol ToolCapableLLMClient: LLMClient {
    /// Runs a full agentic generation: the conformer drives its model's native tool loop,
    /// invoking `dispatch` for each requested call and feeding the returned string back to the
    /// model, until the model produces a final answer. Iteration budgets are enforced by the
    /// DISPATCH side (plan §4.3), not the conformer.
    func respondWithTools(
        _ request: LLMRequest,
        tools: [AgenticToolDefinition],
        dispatch: @escaping AgenticToolDispatch
    ) -> AsyncThrowingStream<AgenticEvent, Error>
}
