//
//  OpenAICompatibleClient.swift — the shared OpenAI-shaped HTTP conformer (plan §2.3, Slice B).
//
//  ← `LLMProvider::{OpenAI,Groq,OpenRouter,Ollama,CustomOpenAI}` (`llm_client.rs:181-210`,
//  `llm_stream.rs:102-192`): one request/response shape, only the base URL differs per kind.
//  `messages: [system, user]`. Only `.customOpenAI` applies `max_tokens`/`temperature`/`top_p`
//  (`llm_client.rs:260`, `llm_stream.rs:171`) — every other kind in this family ignores them,
//  exactly like Rust.
//
import Foundation

/// ← Rust's `REQUEST_TIMEOUT_DURATION = Duration::from_secs(300)`, applied to every LLM HTTP
/// request via `.timeout(REQUEST_TIMEOUT_DURATION)` (`llm_client.rs:8,301`; `llm_stream.rs:24,198`)
/// — a deliberately generous timeout since summary/answer generations can legitimately run long.
/// Shared with `AnthropicClient.swift` (same module) so both conformers stay in lockstep.
enum ProviderHTTPDefaults {
    static let requestTimeout: TimeInterval = 300
}

public struct OpenAICompatibleClient: LLMClient {
    public let kind: ProviderKind
    let model: String
    let apiKey: String
    let baseURL: URL
    /// Only `.customOpenAI` forwards `LLMRequest.{maxTokens,temperature,topP}` into the body
    /// (← the `provider == &LLMProvider::CustomOpenAI` branch, `llm_client.rs:260`).
    let applyTunableParams: Bool
    let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) throws {
        kind = config.kind
        model = config.model
        apiKey = config.apiKey
        applyTunableParams = config.kind == .customOpenAI
        baseURL = try Self.resolveBaseURL(for: config)
        self.session = session
    }

    // MARK: - LLMClient

    public func generate(_ request: LLMRequest) async throws -> String {
        try Task.checkCancellation()
        let urlRequest = try makeURLRequest(for: request, streaming: false)
        let (data, response) = try await send(urlRequest)
        try Self.validate(response: response, data: data)
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw LLMError.requestFailed("Failed to parse LLM response: \(error)")
        }
        guard let content = decoded.choices.first?.message.content else {
            throw LLMError.requestFailed("No content in LLM response")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let urlRequest = try makeURLRequest(for: request, streaming: true)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    // Documented simplification vs. Rust (plan §3): a failing status here is
                    // reported without the response body — reading it would require draining
                    // `bytes` (the same async sequence the SSE loop below consumes), whereas Rust
                    // can call `response.text()` because it hasn't started reading `bytes_stream()`
                    // yet either way. Not a behavioral divergence recall/summary depend on.
                    try Self.validate(response: response, data: nil)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let delta = SSELineDecoder.delta(forLine: Substring(line), isClaude: false) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request building

    /// ← the per-provider `match` arm computing `(api_url, headers)` (`llm_client.rs:181-210`).
    /// `internal` (not `private`) so `OllamaEndpointTests` can assert endpoint resolution directly,
    /// without a network round trip.
    static func resolveBaseURL(for config: ProviderConfig) throws -> URL {
        switch config.kind {
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .openRouter:
            return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .ollama:
            // ← `ollama_endpoint.map(...).unwrap_or_else(|| "http://localhost:11434")`
            // (`llm_client.rs:195-197`) — used verbatim, no trimming (Rust doesn't trim here
            // either; the loopback *policy* check, which DOES trim, lives separately in
            // `LoopbackPolicy.swift` and runs before this client is ever constructed).
            let host = config.ollamaEndpoint ?? "http://localhost:11434"
            guard let url = URL(string: "\(host)/v1/chat/completions") else {
                throw LLMError.notConfigured("invalid Ollama endpoint: \(host)")
            }
            return url
        case .customOpenAI:
            guard let rawEndpoint = config.customOpenAIEndpoint,
                  !rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw LLMError.notConfigured("customOpenAIEndpoint is required for .customOpenAI")
            }
            // ← `endpoint.trim_end_matches('/')` (`llm_client.rs:207`) — strips ALL trailing
            // slashes, not just one.
            var trimmed = rawEndpoint
            while trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            guard let url = URL(string: "\(trimmed)/chat/completions") else {
                throw LLMError.notConfigured("invalid customOpenAIEndpoint: \(rawEndpoint)")
            }
            return url
        case .claude, .claudeCLI, .appleFoundation, .mlx:
            throw LLMError.notConfigured("\(config.kind) is not an OpenAI-compatible provider")
        }
    }

    private func makeURLRequest(for request: LLMRequest, streaming: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = ProviderHTTPDefaults.requestTimeout
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: request.system),
                ChatMessage(role: "user", content: request.user)
            ],
            maxTokens: applyTunableParams ? request.maxTokens : nil,
            temperature: applyTunableParams ? request.temperature : nil,
            topP: applyTunableParams ? request.topP : nil,
            stream: streaming ? true : nil
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw LLMError.requestFailed("Failed to send request to LLM: \(error)")
        }
    }

    private static func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("invalid response (not HTTP)")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(http.statusCode)"
            throw LLMError.requestFailed("LLM API request failed: \(bodyText)")
        }
    }
}

// MARK: - Wire shapes (← llm_client.rs ChatMessage/ChatRequest/ChatResponse)

/// Shared with `AnthropicClient.swift` (same module) — Claude's `messages` array uses the same
/// `{role, content}` shape, just with a single "user" entry.
struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: MessageContent
    }

    struct MessageContent: Decodable {
        let content: String
    }
}

// MARK: - SSE delta decoding (shared with AnthropicClient.swift)

/// Shared SSE line/delta decoding for both the OpenAI-compatible family and Anthropic streaming
/// (← the per-line body of the `while let Some(nl) = ...` loop + `extract_delta`,
/// `llm_stream.rs:233-279`).
///
/// Documented simplification vs. Rust (plan §3): Rust manually byte-buffers because it reads raw
/// `bytes_stream()` chunks that can split a line (or a multibyte UTF-8 character) across network
/// packets (`llm_stream.rs:217-234`). Swift's `URLSession.AsyncBytes.lines` already reassembles
/// complete, UTF-8-correct lines for us, so only the per-line SSE/JSON parsing below is ported —
/// no manual buffering is needed.
enum SSELineDecoder {
    /// The delta text carried by one SSE line, or `nil` if the line carries none — a non-`data:`
    /// line (blank/comment/`event:`), the `[DONE]` sentinel, unparsable JSON, or a JSON payload
    /// whose delta path is missing/empty (← `llm_stream.rs:237-251`).
    static func delta(forLine rawLine: Substring, isClaude: Bool) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else {
            return nil
        }
        let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !data.isEmpty, data != "[DONE]" else {
            return nil
        }
        guard let jsonData = data.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            return nil
        }
        let text = extractDelta(isClaude: isClaude, json: value)
        return text.isEmpty ? nil : text
    }

    /// ← `extract_delta` (`llm_stream.rs:259-279`).
    static func extractDelta(isClaude: Bool, json: [String: Any]) -> String {
        if isClaude {
            guard let delta = json["delta"] as? [String: Any],
                  let text = delta["text"] as? String
            else {
                return ""
            }
            return text
        } else {
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let content = delta["content"] as? String
            else {
                return ""
            }
            return content
        }
    }

    /// Test convenience: accumulate every delta in a raw, multi-line SSE text blob (mirrors the
    /// production per-line loop without needing a real network stream).
    static func accumulate(rawSSE text: String, isClaude: Bool) -> String {
        var full = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let delta = delta(forLine: line, isClaude: isClaude) {
                full += delta
            }
        }
        return full
    }
}
