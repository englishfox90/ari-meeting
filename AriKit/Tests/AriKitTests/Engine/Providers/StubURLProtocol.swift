//
//  StubURLProtocol.swift — test-only network stub for the HTTP provider tests (plan §6 Slice B).
//
//  Captures the outgoing request (headers + body) and returns a canned response, so
//  `OpenAIRequestShapeTests` / `AnthropicRequestShapeTests` never touch the real network.
//  Registered via `URLSessionConfiguration.protocolClasses`.
//
import Foundation

/// `Storage` is marked `@unchecked Sendable`: `URLProtocol`'s override points (`startLoading`,
/// the `class func` hooks) are invoked directly by `URLSession`'s own loading machinery on
/// whatever thread it chooses — there is no actor we can safely hop to from inside a synchronous
/// `URLProtocol` override. All access to the shared state below is serialized by `lock`, which is
/// the actual concurrency guarantee (a standard, narrowly-scoped pattern for `URLProtocol` test
/// doubles, isolated to this test-only file).
final class StubURLProtocol: URLProtocol {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var statusCode = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
        var capturedRequest: URLRequest?
        var capturedBody: Data?
    }

    private static let storage = Storage()

    static func reset() {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.statusCode = 200
        storage.headers = ["Content-Type": "application/json"]
        storage.body = Data()
        storage.capturedRequest = nil
        storage.capturedBody = nil
    }

    static func stub(status: Int = 200, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.statusCode = status
        storage.body = body
        storage.headers = headers
    }

    static func lastCapturedRequest() -> URLRequest? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.capturedRequest
    }

    static func lastCapturedBody() -> Data? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.capturedBody
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let bodyData = Self.readBody(of: request)

        Self.storage.lock.lock()
        Self.storage.capturedRequest = request
        Self.storage.capturedBody = bodyData
        let statusCode = Self.storage.statusCode
        let headers = Self.storage.headers
        let body = Self.storage.body
        Self.storage.lock.unlock()

        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data? {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
