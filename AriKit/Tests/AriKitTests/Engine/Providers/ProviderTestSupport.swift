//
//  ProviderTestSupport.swift — shared helpers for the Slice B HTTP provider tests.
//
import Foundation
import Testing
@testable import AriKit

enum ProviderTestSupport {
    /// An ephemeral `URLSession` routed entirely through `StubURLProtocol` — no real network.
    static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func chatCompletionResponse(content: String) -> Data {
        let json: [String: Any] = ["choices": [["message": ["content": content]]]]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    static func claudeMessagesResponse(text: String) -> Data {
        let json: [String: Any] = ["content": [["text": text]]]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    static func capturedJSONBody(sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        let data = try #require(StubURLProtocol.lastCapturedBody(), sourceLocation: sourceLocation)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any], sourceLocation: sourceLocation)
    }

    /// Runs `body` with exclusive access to `StubURLProtocol`'s shared (class-level) captured
    /// request/response state.
    ///
    /// `StubURLProtocol`'s storage is necessarily class-scoped (`URLProtocol` registers a TYPE via
    /// `protocolClasses`, so every request handled by any `URLSession` configured with it lands in
    /// the same static storage — there is no per-instance isolation `URLProtocol` offers here).
    /// Swift Testing runs independent test functions/suites concurrently by default, so without
    /// this gate two HTTP-provider tests racing on that shared storage can read back each other's
    /// captured request — exactly the request-shape assertions this suite exists to make
    /// trustworthy. `NetworkStubGate` serializes ONLY the tests that opt in via this helper
    /// (an async, non-blocking actor-backed queue — no `@unchecked Sendable`/`nonisolated(unsafe)`
    /// needed), so the rest of the test target keeps its normal parallelism.
    static func withExclusiveNetworkStub<R>(_ body: () async throws -> R) async throws -> R {
        await NetworkStubGate.shared.acquire()
        do {
            let result = try await body()
            await NetworkStubGate.shared.release()
            return result
        } catch {
            await NetworkStubGate.shared.release()
            throw error
        }
    }
}

/// A tiny async mutual-exclusion queue (FIFO), used only to serialize the `StubURLProtocol`-backed
/// tests against each other (see `ProviderTestSupport.withExclusiveNetworkStub`).
private actor NetworkStubGate {
    static let shared = NetworkStubGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
