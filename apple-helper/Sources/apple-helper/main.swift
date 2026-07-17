//
//  main.swift
//  apple-helper
//
//  Entry point for the Apple Helper sidecar.
//
//  Lifecycle (mirrors ari-notch's line-reading + flush discipline, minus the UI
//  run loop — this sidecar is a pure request/response NDJSON tool, no AppKit):
//    1. Read stdin line-by-line (NDJSON, one JSON object per line).
//    2. Decode each non-empty line into `AppleRequest`.
//    3. Dispatch:
//         .probe    → compute availability, write one `.probeResult` line + flush.
//         .shutdown → exit(0) cleanly.
//         .unknown / decode failure → write one `.error(message:)` line + flush,
//                     then keep reading.
//    4. On EOF (parent closed the pipe), exit(0).
//
//  ENTITLEMENTS: Phase 1 (probe) needs NONE. `SystemLanguageModel.availability`
//  and `SpeechTranscriber.isAvailable` / asset-inventory queries are
//  availability checks that do not require entitlements. Phase 2 (summarize)
//  ALSO needs NONE: on-device FoundationModels generation is an in-process,
//  on-device inference API with no TCC-guarded resource and no network — no
//  entitlement key exists for it in the SDK. See Summarize.swift for the full
//  finding. Phase 3 (ensureAssets) ALSO needs NONE: on-device SpeechTranscriber
//  asset installation via AssetInventory is a system-managed model download that
//  does NOT use the classic `com.apple.developer.speech-recognition` entitlement
//  (that gates the older server-backed SFSpeechRecognizer). See EnsureAssets.swift
//  for the full finding. A future `transcribe` phase should re-verify.
//

import Foundation

// MARK: - Outbound writer (line-buffered, flushed)

/// Serializes and writes one `AppleResponse` to stdout as an NDJSON line.
enum AppleIO {
    static func send(_ response: AppleResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(response),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
        // Flush the C stdio layer too, in case anything downstream shares fd 1.
        fflush(stdout)
    }
}

// MARK: - Synchronous bridge to the async probe

/// Runs the async `Probe.run()` to completion and blocks until it returns, so
/// the synchronous stdin read loop can stay simple and strictly ordered.
func runProbeBlocking() -> ProbeResult {
    let semaphore = DispatchSemaphore(value: 0)
    // Conservative default in case the Task never completes (it always does).
    let box = ProbeResultBox()
    Task {
        box.value = await Probe.run()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

/// Tiny reference box so the detached Task can hand the result back across the
/// semaphore without capturing an `inout`.
final class ProbeResultBox: @unchecked Sendable {
    var value = ProbeResult(
        speechAvailable: false,
        foundationAvailable: false,
        osOk: false,
        appleIntelligence: false,
        speechAssetsInstalled: false
    )
}

// MARK: - Synchronous bridge to the async summarize

/// Runs the async `Summarize.run(...)` to completion and blocks until it
/// returns, mirroring `runProbeBlocking()`. Returns `.success(text)` on a real
/// generation or `.failure(message)` on any honest failure — the read loop
/// stays synchronous and strictly ordered.
func runSummarizeBlocking(text: String, instruction: String, maxTokens: Int) -> Result<String, SummarizeError> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SummarizeResultBox()
    Task {
        do {
            box.value = .success(try await Summarize.run(text: text, instruction: instruction, maxTokens: maxTokens))
        } catch let e as SummarizeError {
            box.value = .failure(e)
        } catch {
            box.value = .failure(SummarizeError(message: "on-device summarization failed: \(error.localizedDescription)"))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

/// Reference box carrying the summarize outcome back across the semaphore.
final class SummarizeResultBox: @unchecked Sendable {
    var value: Result<String, SummarizeError> = .failure(SummarizeError(message: "summarization did not complete"))
}

// MARK: - Synchronous bridge to the async transcribe

/// Runs the async `Transcribe.run(...)` to completion and blocks until it
/// returns, mirroring `runSummarizeBlocking()`. Returns `.success((text,
/// confidence))` on a real transcription or `.failure(message)` on any honest
/// failure — the read loop stays synchronous and strictly ordered.
func runTranscribeBlocking(pcmBase64: String, locale: String) -> Result<(String, Double?), TranscribeError> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = TranscribeResultBox()
    Task {
        do {
            let r = try await Transcribe.run(pcmBase64: pcmBase64, locale: locale)
            box.value = .success((r.text, r.confidence))
        } catch let e as TranscribeError {
            box.value = .failure(e)
        } catch {
            box.value = .failure(TranscribeError(message: "on-device transcription failed: \(error.localizedDescription)"))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

/// Reference box carrying the transcribe outcome back across the semaphore.
final class TranscribeResultBox: @unchecked Sendable {
    var value: Result<(String, Double?), TranscribeError> = .failure(TranscribeError(message: "transcription did not complete"))
}

// MARK: - Synchronous bridge to the async embedBatch

/// Runs the async `Embed.run(...)` to completion and blocks until it returns,
/// mirroring `runSummarizeBlocking()`. Returns `.success(vectors)` on real
/// embeddings or `.failure(message)` on any honest failure — the read loop stays
/// synchronous and strictly ordered.
func runEmbedBlocking(texts: [String]) -> Result<[[Float]], EmbedError> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = EmbedResultBox()
    Task {
        do {
            box.value = .success(try Embed.run(texts: texts))
        } catch let e as EmbedError {
            box.value = .failure(e)
        } catch {
            box.value = .failure(EmbedError(message: "on-device embedding failed: \(error.localizedDescription)"))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

/// Reference box carrying the embed outcome back across the semaphore.
final class EmbedResultBox: @unchecked Sendable {
    var value: Result<[[Float]], EmbedError> = .failure(EmbedError(message: "embedding did not complete"))
}

// MARK: - Synchronous bridge to the async ensureAssets (streams progress)

/// Runs the async `EnsureAssets.run(...)` to completion and blocks until it
/// returns, mirroring `runSummarizeBlocking()`. UNLIKE the others, this streams:
/// the `onProgress` closure emits one `AppleResponse.progress(fraction:)` LINE
/// per callback (flushed immediately) BEFORE control returns, so the Rust side
/// sees incremental progress in order. Returns `.success(true)` once installed
/// or `.failure(message)` on any honest failure — the read loop stays
/// synchronous and strictly ordered, and the terminal line is written by the
/// caller AFTER all progress lines.
func runEnsureAssetsBlocking(which: String) -> Result<Bool, EnsureAssetsError> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = EnsureAssetsResultBox()
    Task {
        do {
            // Each real fraction becomes its own flushed progress LINE, in order.
            let installed = try await EnsureAssets.run(which: which) { fraction in
                AppleIO.send(.progress(fraction: fraction))
            }
            box.value = .success(installed)
        } catch let e as EnsureAssetsError {
            box.value = .failure(e)
        } catch {
            box.value = .failure(EnsureAssetsError(message: "asset installation failed: \(error.localizedDescription)"))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

/// Reference box carrying the ensure-assets outcome back across the semaphore.
final class EnsureAssetsResultBox: @unchecked Sendable {
    var value: Result<Bool, EnsureAssetsError> = .failure(EnsureAssetsError(message: "asset installation did not complete"))
}

// MARK: - Dispatch

func handle(_ request: AppleRequest) {
    switch request {
    case .probe:
        let r = runProbeBlocking()
        AppleIO.send(.probeResult(
            speechAvailable: r.speechAvailable,
            foundationAvailable: r.foundationAvailable,
            osOk: r.osOk,
            appleIntelligence: r.appleIntelligence,
            speechAssetsInstalled: r.speechAssetsInstalled
        ))
    case let .summarize(text, instruction, maxTokens):
        switch runSummarizeBlocking(text: text, instruction: instruction, maxTokens: maxTokens) {
        case let .success(summary):
            AppleIO.send(.summarizeResult(text: summary))
        case let .failure(error):
            // No-Fake-State: surface the truthful reason, never a fake summary.
            AppleIO.send(.error(message: error.message))
        }
    case let .transcribe(pcmBase64, locale):
        switch runTranscribeBlocking(pcmBase64: pcmBase64, locale: locale) {
        case let .success((text, confidence)):
            AppleIO.send(.transcribeResult(text: text, confidence: confidence))
        case let .failure(error):
            // No-Fake-State: surface the truthful reason, never fake a transcript.
            AppleIO.send(.error(message: error.message))
        }
    case let .embedBatch(texts):
        switch runEmbedBlocking(texts: texts) {
        case let .success(vectors):
            AppleIO.send(.embedResult(vectors: vectors))
        case let .failure(error):
            // No-Fake-State: surface the truthful reason, never fake a vector.
            AppleIO.send(.error(message: error.message))
        }
    case let .ensureAssets(which):
        // Progress lines are emitted from inside the blocking call (in order,
        // each flushed). Here we only write the ONE terminal line afterwards.
        switch runEnsureAssetsBlocking(which: which) {
        case let .success(installed):
            AppleIO.send(.ensureResult(installed: installed))
        case let .failure(error):
            // No-Fake-State: surface the truthful reason, never a fake success.
            AppleIO.send(.error(message: error.message))
        }
    case .shutdown:
        exit(0)
    case .unknown:
        AppleIO.send(.error(message: "unknown or unsupported request type"))
    }
}

// MARK: - Read loop

let decoder = JSONDecoder()
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }
    guard let data = trimmed.data(using: .utf8) else {
        AppleIO.send(.error(message: "line was not valid UTF-8"))
        continue
    }

    // AppleRequest never throws on unknown `type` (→ .unknown); a throw here
    // means genuinely malformed JSON. Report it and keep reading.
    let request: AppleRequest
    do {
        request = try decoder.decode(AppleRequest.self, from: data)
    } catch {
        AppleIO.send(.error(message: "failed to decode request: \(error)"))
        continue
    }

    handle(request)
}

// EOF on stdin (parent closed the pipe): exit cleanly.
exit(0)
