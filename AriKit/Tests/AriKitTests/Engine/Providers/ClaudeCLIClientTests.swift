//
//  ClaudeCLIClientTests.swift — plan §6 Slice C.
//
//  `ClaudeCLIArgsTests` asserts argument-vector parity with `claude_cli.rs:130-143` (pure, no
//  process spawn). The fake-binary tests exercise the real `Process` spawn path against an
//  injected script (never a real `claude` install) — stdout → answer on success, non-zero exit →
//  `LLMError.requestFailed`.
//
#if os(macOS)
    import Foundation
    import Testing
    @testable import AriKit

    struct ClaudeCLIArgsTests {
        @Test func realModelAppendsModelFlagLast() {
            let args = ClaudeCLIClient.arguments(
                model: "opus",
                systemPrompt: "You are a summarizer.",
                userPrompt: "Summarize this meeting."
            )
            #expect(args == [
                "-p", "Summarize this meeting.",
                "--system-prompt", "You are a summarizer.",
                "--output-format", "text",
                "--model", "opus"
            ])
        }

        @Test func emptyModelOmitsModelFlag() {
            let args = ClaudeCLIClient.arguments(model: "", systemPrompt: "sys", userPrompt: "usr")
            #expect(args == ["-p", "usr", "--system-prompt", "sys", "--output-format", "text"])
        }

        @Test func defaultModelCaseInsensitiveOmitsModelFlag() {
            for candidate in ["default", "Default", "DEFAULT", "DeFauLt"] {
                let args = ClaudeCLIClient.arguments(model: candidate, systemPrompt: "sys", userPrompt: "usr")
                #expect(args == ["-p", "usr", "--system-prompt", "sys", "--output-format", "text"])
            }
        }

        @Test func whitespaceOnlyModelOmitsModelFlag() {
            let args = ClaudeCLIClient.arguments(model: "   ", systemPrompt: "sys", userPrompt: "usr")
            #expect(args == ["-p", "usr", "--system-prompt", "sys", "--output-format", "text"])
        }

        @Test func modelWithSurroundingWhitespaceIsTrimmedInTheModelFlag() {
            let args = ClaudeCLIClient.arguments(model: "  sonnet  ", systemPrompt: "sys", userPrompt: "usr")
            #expect(args == [
                "-p", "usr",
                "--system-prompt", "sys",
                "--output-format", "text",
                "--model", "sonnet"
            ])
        }
    }

    struct ClaudeCLIFakeBinaryTests {
        @Test func stdoutOnSuccessBecomesTheAnswer() async throws {
            let script = try FakeClaudeScript.write(
                shellBody: #"printf '  hello from fake claude  \n'; exit 0"#
            )
            defer { script.cleanUp() }

            let client = try ClaudeCLIClient(
                config: ProviderConfig(kind: .claudeCLI, model: "default"),
                binaryResolver: { script.url }
            )
            let result = try await client.generate(LLMRequest(system: "s", user: "u"))
            #expect(result == "hello from fake claude")
        }

        @Test func nonZeroExitThrowsRequestFailed() async throws {
            let script = try FakeClaudeScript.write(
                shellBody: #"echo 'boom: something broke' 1>&2; exit 1"#
            )
            defer { script.cleanUp() }

            let client = try ClaudeCLIClient(
                config: ProviderConfig(kind: .claudeCLI, model: "default"),
                binaryResolver: { script.url }
            )
            await #expect(throws: LLMError.self) {
                _ = try await client.generate(LLMRequest(system: "s", user: "u"))
            }
        }

        @Test func nonZeroExitErrorMessageIncludesStderr() async throws {
            let script = try FakeClaudeScript.write(
                shellBody: #"echo 'boom: something broke' 1>&2; exit 1"#
            )
            defer { script.cleanUp() }

            let client = try ClaudeCLIClient(
                config: ProviderConfig(kind: .claudeCLI, model: "default"),
                binaryResolver: { script.url }
            )
            do {
                _ = try await client.generate(LLMRequest(system: "s", user: "u"))
                Issue.record("expected .requestFailed")
            } catch let LLMError.requestFailed(message) {
                #expect(message.contains("boom: something broke"))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        @Test func unresolvableBinaryThrowsNotConfigured() async throws {
            let client = try ClaudeCLIClient(
                config: ProviderConfig(kind: .claudeCLI, model: "default"),
                binaryResolver: { nil }
            )
            do {
                _ = try await client.generate(LLMRequest(system: "s", user: "u"))
                Issue.record("expected .notConfigured")
            } catch LLMError.notConfigured {
                // expected
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        @Test func generateReceivesTheExactArgumentVector() async throws {
            // The fake script echoes its own argv back so we can assert the exact vector `generate`
            // invoked it with, matching `arguments(model:systemPrompt:userPrompt:)`.
            let script = try FakeClaudeScript.write(
                shellBody: #"for a in "$@"; do printf '%s\n' "$a"; done"#
            )
            defer { script.cleanUp() }

            let client = try ClaudeCLIClient(
                config: ProviderConfig(kind: .claudeCLI, model: "opus"),
                binaryResolver: { script.url }
            )
            let result = try await client.generate(LLMRequest(system: "sys prompt", user: "user prompt"))
            #expect(result == [
                "-p", "user prompt",
                "--system-prompt", "sys prompt",
                "--output-format", "text",
                "--model", "opus"
            ].joined(separator: "\n"))
        }
    }

    /// A temporary, executable `sh` script standing in for the real `claude` binary.
    private struct FakeClaudeScript {
        let url: URL

        static func write(shellBody: String) throws -> FakeClaudeScript {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeCLIClientTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("claude")
            let contents = "#!/bin/sh\n\(shellBody)\n"
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return FakeClaudeScript(url: url)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
#endif
