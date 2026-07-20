//
//  AnthropicClient.swift — the Claude messages-API conformer (plan §2.3, Slice B).
//
//  ← `LLMProvider::Claude` (`llm_client.rs:211-226`, `llm_stream.rs:129-140`): a DISTINCT body
//  shape from the OpenAI-compatible family — `system` is a top-level field (not a "system"-role
//  message), `messages` carries only the "user" turn, `max_tokens` is HARDCODED to 2048 (never
//  `LLMRequest.maxTokens`), and auth is `x-api-key`/`anthropic-version` headers, never a Bearer
//  `Authorization` header (`llm_client.rs:242` explicitly skips Authorization for Claude).
//
import Foundation

public struct AnthropicClient: LLMClient {
    public let kind: ProviderKind = .claude

    /// ← `max_tokens: 2048` hardcoded in both `ClaudeRequest` construction sites
    /// (`llm_client.rs:286`, `llm_stream.rs:165`) — NOT `LLMRequest.maxTokens`.
    static let hardcodedMaxTokens = 2048
    static let anthropicVersion = "2023-06-01"
    static let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    let model: String
    let apiKey: String
    let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) throws {
        guard config.kind == .claude else {
            throw LLMError.notConfigured("AnthropicClient only supports .claude, got \(config.kind)")
        }
        model = config.model
        apiKey = config.apiKey
        self.session = session
    }

    // MARK: - LLMClient

    public func generate(_ request: LLMRequest) async throws -> String {
        try Task.checkCancellation()
        let urlRequest = try makeURLRequest(for: request, streaming: false)
        let (data, response) = try await send(urlRequest)
        try Self.validate(response: response, data: data)
        let decoded: ClaudeMessagesResponse
        do {
            decoded = try JSONDecoder().decode(ClaudeMessagesResponse.self, from: data)
        } catch {
            throw LLMError.requestFailed("Failed to parse LLM response: \(error)")
        }
        guard let text = decoded.content.first?.text else {
            throw LLMError.requestFailed("No content in LLM response")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let urlRequest = try makeURLRequest(for: request, streaming: true)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    // Same documented simplification as OpenAICompatibleClient (plan §3): a
                    // failing status is reported without the response body here.
                    try Self.validate(response: response, data: nil)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let delta = SSELineDecoder.delta(forLine: Substring(line), isClaude: true) {
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

    private func makeURLRequest(for request: LLMRequest, streaming: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = ProviderHTTPDefaults.requestTimeout
        // ← Claude never gets a Bearer Authorization header (`llm_client.rs:242`); auth is these
        // two headers only.
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ClaudeMessagesRequest(
            model: model,
            maxTokens: Self.hardcodedMaxTokens,
            system: request.system,
            stream: streaming ? true : nil,
            messages: [ChatMessage(role: "user", content: request.user)]
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

// MARK: - Wire shapes (← llm_client.rs ClaudeRequest/ClaudeChatResponse)

private struct ClaudeMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let stream: Bool?
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case model, system, stream, messages
        case maxTokens = "max_tokens"
    }
}

private struct ClaudeMessagesResponse: Decodable {
    let content: [Content]

    struct Content: Decodable {
        let text: String
    }
}
