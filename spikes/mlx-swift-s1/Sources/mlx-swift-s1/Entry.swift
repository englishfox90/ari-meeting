// mlx-swift-s1 — throwaway S1 spike CLI.
//
// Loads a model by HF repo id via mlx-swift-lm, applies the model's native
// chat template (via ChatSession's `instructions` + `respond(to:)`), runs
// generation over a dumped Call ③ {system, user} prompt, and prints
// {text, tokPerS, loadMs, genMs} as JSON to stdout.
//
// Usage:
//   mlx-swift-s1 <hf-repo-id> <prompt-json-path> [--max-tokens N]
//
// <prompt-json-path> is one of the files produced by
// spikes/mlx-swift-s1/dump-prompts.mjs: {system, user, meetingId, title, ...}.

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

struct PromptFile: Decodable {
    let meetingId: String
    let title: String?
    let templateId: String?
    let lineCount: Int
    let system: String
    let user: String
}

struct RunResult: Encodable {
    let modelId: String
    let meetingId: String
    let title: String?
    let text: String
    let tokPerS: Double?
    let loadMs: Double
    let genMs: Double
    let promptTokenCount: Int?
    let completionTokenCount: Int?
}

struct SpikeError: Error, CustomStringConvertible {
    let message: String
    var description: String {
        message
    }
}

@main
struct MlxSwiftS1 {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(
                "Usage: mlx-swift-s1 <hf-repo-id> <prompt-json-path> [--max-tokens N]\n".data(
                    using: .utf8
                )!
            )
            exit(1)
        }
        let modelId = args[1]
        let promptPath = args[2]
        var maxTokens = 1200
        if let idx = args.firstIndex(of: "--max-tokens"), idx + 1 < args.count,
           let v = Int(args[idx + 1]) {
            maxTokens = v
        }

        do {
            let result = try await run(
                modelId: modelId, promptPath: promptPath, maxTokens: maxTokens
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
        } catch {
            FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
            let errJson: [String: String] = ["error": "\(error)", "modelId": modelId]
            if let data = try? JSONSerialization.data(
                withJSONObject: errJson, options: [.prettyPrinted]
            ),
                let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            exit(1)
        }
    }

    static func run(modelId: String, promptPath: String, maxTokens: Int) async throws -> RunResult {
        let promptData = try Data(contentsOf: URL(fileURLWithPath: promptPath))
        let prompt = try JSONDecoder().decode(PromptFile.self, from: promptData)

        FileHandle.standardError.write(
            "[mlx-swift-s1] loading \(modelId) ...\n".data(using: .utf8)!
        )

        let downloader = #hubDownloader()
        let tokenizerLoader = #huggingFaceTokenizerLoader()

        let loadStart = Date()
        let container = try await loadModelContainer(
            from: downloader,
            using: tokenizerLoader,
            id: modelId,
            progressHandler: { progress in
                let pct = Int(progress.fractionCompleted * 100)
                FileHandle.standardError.write(
                    "[mlx-swift-s1] download \(pct)%\n".data(using: .utf8)!
                )
            }
        )
        let loadMs = Date().timeIntervalSince(loadStart) * 1000

        FileHandle.standardError.write(
            "[mlx-swift-s1] loaded in \(loadMs) ms, generating ...\n".data(using: .utf8)!
        )

        let session = ChatSession(
            container,
            instructions: prompt.system,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.5,
                topP: 0.8
            ),
            additionalContext: ["enable_thinking": false]
        )

        let genStart = Date()
        let text = try await session.respond(to: prompt.user)
        let genMs = Date().timeIntervalSince(genStart) * 1000

        // Rough token-rate proxy: mlx-swift-lm doesn't surface exact token
        // counts through the high-level ChatSession API used here, so we
        // approximate completion tokens via whitespace-splitting (documented
        // as approximate in the report, not treated as exact).
        let approxCompletionTokens = text.split(whereSeparator: { $0.isWhitespace }).count
        let tokPerS =
            genMs > 0 ? Double(approxCompletionTokens) / (genMs / 1000.0) : nil

        return RunResult(
            modelId: modelId,
            meetingId: prompt.meetingId,
            title: prompt.title,
            text: text,
            tokPerS: tokPerS,
            loadMs: loadMs,
            genMs: genMs,
            promptTokenCount: nil,
            completionTokenCount: approxCompletionTokens
        )
    }
}
