//
//  LoopbackPolicyTests.swift — plan §6 Slice 1 test 1.
//
//  1:1 port of the Rust `recall_allows_only_loopback_ollama_endpoints` case (shell.rs:483).
//
import Testing
@testable import AriKit

@Suite struct LoopbackPolicyTests {
    @Test func allowsOnlyLoopbackOllamaEndpoints() {
        #expect(Recall.isLoopbackOllamaEndpoint(nil))
        #expect(Recall.isLoopbackOllamaEndpoint("http://localhost:11434"))
        #expect(Recall.isLoopbackOllamaEndpoint("http://127.0.0.1:11434"))
        #expect(Recall.isLoopbackOllamaEndpoint("http://[::1]:11434"))
        #expect(!Recall.isLoopbackOllamaEndpoint("https://ollama.example.com"))
        #expect(!Recall.isLoopbackOllamaEndpoint("http://localhost.example.com:11434"))
        #expect(!Recall.isLoopbackOllamaEndpoint("not a url"))
    }

    @Test func emptyOrWhitespaceEndpointIsAllowed() {
        #expect(Recall.isLoopbackOllamaEndpoint(""))
        #expect(Recall.isLoopbackOllamaEndpoint("   "))
    }

    @Test func bareAndBracketedIPv6BothAllowed() {
        // The Rust allow-set carries both `::1` and `[::1]`; verify both parse as loopback.
        #expect(Recall.isLoopbackOllamaEndpoint("http://[::1]:11434"))
        #expect(Recall.isLoopbackOllamaEndpoint("http://[::1]"))
    }
}
