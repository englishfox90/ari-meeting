//
//  ClaudeCLIClient.swift — the local Claude Code CLI conformer (plan §2.3, Slice C).
//
//  ← `ari-engine/src/summary/claude_cli.rs`: uses the user's locally-installed Claude Code CLI
//  (`claude`) as a summarization provider by shelling out to it in non-interactive ("print") mode
//  rather than making an HTTP request. No API key is stored in Ari — the CLI supplies its own
//  authentication (interactive login / keychain / `ANTHROPIC_API_KEY`).
//
//  `#if os(macOS)` ONLY — `Process` spawn + login-shell `PATH` resolution are Foundation-process
//  concepts that only make sense on macOS; `ProviderFactory` (and the app's provider picker) omit
//  `.claudeCLI` on iOS. This mirrors the plan's framing ("the kind is absent from the factory on
//  iOS") — the case still exists in `ProviderKind` (shared enum), only the conformer is gated.
//
//  No streaming (← `llm_stream.rs:69-97`: ClaudeCLI has no incremental output path) — relies on
//  the `LLMClient` extension's single-yield fallback (`LLMClient.swift`).
//
#if os(macOS)
    import Foundation

    public struct ClaudeCLIClient: LLMClient {
        public let kind: ProviderKind = .claudeCLI

        /// ← `CLAUDE_CLI_TIMEOUT` (`claude_cli.rs:24`).
        static let timeout: Duration = .seconds(300)

        let model: String

        /// Resolves the `claude` binary to launch. Injectable so tests can point at a fake
        /// `claude` script instead of depending on a real Claude Code install
        /// (← plan: "Make the launcher INJECTABLE so tests use a fake binary/script").
        let binaryResolver: @Sendable () -> URL?

        public init(
            config: ProviderConfig,
            binaryResolver: (@Sendable () -> URL?)? = nil
        ) throws {
            guard config.kind == .claudeCLI else {
                throw LLMError.notConfigured("ClaudeCLIClient only supports .claudeCLI, got \(config.kind)")
            }
            model = config.model
            self.binaryResolver = binaryResolver ?? { Self.resolveClaudeBinary() }
        }

        // MARK: - LLMClient

        public func generate(_ request: LLMRequest) async throws -> String {
            try Task.checkCancellation()

            guard let binary = binaryResolver() else {
                throw LLMError.notConfigured(
                    "Claude CLI not found. Install Claude Code and make sure `claude` is on your PATH."
                )
            }

            let arguments = Self.arguments(
                model: model,
                systemPrompt: request.system,
                userPrompt: request.user
            )
            // ← "Run in a neutral cwd so the project's CLAUDE.md / skills are not loaded"
            // (`claude_cli.rs:145-146`).
            let workingDirectory = FileManager.default.temporaryDirectory

            return try await Self.run(
                binary: binary,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeout: Self.timeout
            )
        }

        // MARK: - Argument building (pure — ClaudeCLIArgsTests)

        /// ← the argument vector built in `generate_with_claude_cli` (`claude_cli.rs:130-143`):
        /// fully replaces the CLI's default agentic system prompt with our own instruction so it
        /// behaves as a plain completion endpoint. `model` of `""`/`"default"` (case-insensitive,
        /// trimmed) omits `--model` entirely — the CLI then uses its own configured default.
        static func arguments(model: String, systemPrompt: String, userPrompt: String) -> [String] {
            var args = [
                "-p", userPrompt,
                "--system-prompt", systemPrompt,
                "--output-format", "text"
            ]
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedModel.isEmpty, trimmedModel.lowercased() != "default" {
                args.append(contentsOf: ["--model", trimmedModel])
            }
            return args
        }

        // MARK: - Binary resolution (← resolve_claude_binary / resolve_via_login_shell,

        // claude_cli.rs:40-80)

        /// A macOS `.app` bundle inherits a minimal `PATH` (not the user's shell `PATH`), so this
        /// (1) asks a login shell where `claude` lives, then (2) falls back to well-known install
        /// locations. Blocking (spawns subprocesses synchronously) — a faithful port of Rust's own
        /// `resolve_claude_binary`, which is likewise a blocking `std::process::Command` call made
        /// from inside an async fn (`claude_cli.rs:111,123`).
        static func resolveClaudeBinary() -> URL? {
            if let viaShell = resolveViaLoginShell() {
                return viaShell
            }

            var candidates: [URL] = []
            if let home = ProcessInfo.processInfo.environment["HOME"] {
                let homeURL = URL(fileURLWithPath: home)
                candidates.append(homeURL.appendingPathComponent(".claude/local/claude"))
                candidates.append(homeURL.appendingPathComponent(".local/bin/claude"))
            }
            candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/claude"))
            candidates.append(URL(fileURLWithPath: "/usr/local/bin/claude"))

            return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }

        /// Ask the user's login shell to resolve `claude` (respects Homebrew, the native
        /// installer, and `/etc/paths`). Uses `-lc` (login, non-interactive) to avoid a tty-less
        /// interactive shell hanging (← `claude_cli.rs:59-80`).
        private static func resolveViaLoginShell() -> URL? {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lc", "command -v claude"]
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            // `command -v` can emit multiple lines for aliases/functions; the resolved path is the
            // last non-empty line.
            guard let last = output
                .split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { !$0.isEmpty })
            else { return nil }

            let url = URL(fileURLWithPath: last)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        // MARK: - Process spawn (← the `tokio::process::Command` + `tokio::select!` race,

        // claude_cli.rs:148-188)

        /// Races the process run against a hard timeout; either path kills the child (`Process` is
        /// `Sendable` on this SDK, so it can be captured by the cancellation handler safely — no
        /// `@unchecked Sendable` needed).
        private static func run(
            binary: URL,
            arguments: [String],
            workingDirectory: URL,
            timeout: Duration
        ) async throws -> String {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await runProcess(binary: binary, arguments: arguments, workingDirectory: workingDirectory)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw LLMError.requestFailed("Claude CLI timed out")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw LLMError.requestFailed("Claude CLI produced no result")
                }
                return result
            }
        }

        /// Spawns `binary`, drains stdout/stderr concurrently with execution (never after — reading
        /// only once the process exits risks the classic `Process` deadlock if output exceeds the
        /// pipe buffer, since the child would block writing with no one draining it), then resolves
        /// on termination. `onCancel` terminates the child immediately (kill-on-cancel, ←
        /// `kill_on_drop(true)`, `claude_cli.rs:154`).
        private static func runProcess(
            binary: URL,
            arguments: [String],
            workingDirectory: URL
        ) async throws -> String {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardInput = FileHandle.nullDevice
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw LLMError.requestFailed("Failed to launch Claude CLI: \(error)")
            }

            return try await withTaskCancellationHandler {
                async let stdoutData = readAll(stdoutPipe.fileHandleForReading)
                async let stderrData = readAll(stderrPipe.fileHandleForReading)
                await waitForExit(process)

                let stdout = await stdoutData
                let stderr = await stderrData

                if Task.isCancelled {
                    throw CancellationError()
                }

                guard process.terminationStatus == 0 else {
                    let stderrText = (String(data: stderr, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw LLMError.requestFailed("Claude CLI exited with an error: \(stderrText)")
                }

                let stdoutText = String(data: stdout, encoding: .utf8) ?? ""
                return stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                }
            }
        }

        private static func readAll(_ handle: FileHandle) async -> Data {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: handle.readDataToEndOfFile())
                }
            }
        }

        private static func waitForExit(_ process: Process) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }
    }
#endif
