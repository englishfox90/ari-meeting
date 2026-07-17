//
//  Entry.swift
//  speechanalyzer-s2 — throwaway S2 spike.
//
//  CLI: runs Apple's SpeechAnalyzer (macOS 26) against one audio file using
//  either the SpeechTranscriber module (raw words, minimal formatting) or the
//  DictationTranscriber module (punctuation + sentence structure), and emits
//  JSON: {text, segments:[{text,start,end,confidence?}], mode, wall_ms,
//  word_timestamp_count, error?}.
//
//  Usage:
//    speechanalyzer-s2 --input <audio.wav> --mode transcriber|dictation
//                       [--locale en-US] [--output <path>]
//
//  Input audio: any format AVAudioFile can open. We feed the WHOLE file to a
//  single SpeechAnalyzer session via analyzeSequence(from:) — no manual
//  chunking — to test whether the framework truncates long (up to ~80 min)
//  meeting audio on its own. Findings about that are the point of this spike.
//
//  NOT product code. Do not import into apple-helper/AriKit.
//

import AVFoundation
import Foundation
import Speech

struct CLIError: Error, CustomStringConvertible {
    let message: String
    var description: String {
        message
    }
}

struct Segment: Codable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Double?
}

struct OutputJSON: Codable {
    let mode: String
    let locale: String
    let inputPath: String
    let text: String
    let segments: [Segment]
    let wallMs: Double
    let wordTimestampCount: Int
    let segmentCount: Int
    let audioDurationSec: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case mode, locale, text, segments, error
        case inputPath = "input_path"
        case wallMs = "wall_ms"
        case wordTimestampCount = "word_timestamp_count"
        case segmentCount = "segment_count"
        case audioDurationSec = "audio_duration_sec"
    }
}

func parseArgs() throws -> (input: String, mode: String, locale: String, output: String?) {
    var input: String?
    var mode = "transcriber"
    var locale = "en-US"
    var output: String?
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--input": input = args.next()
        case "--mode": mode = args.next() ?? mode
        case "--locale": locale = args.next() ?? locale
        case "--output": output = args.next()
        default:
            throw CLIError(message: "unknown argument: \(arg)")
        }
    }
    guard let input else { throw CLIError(message: "--input is required") }
    guard mode == "transcriber" || mode == "dictation" else {
        throw CLIError(message: "--mode must be 'transcriber' or 'dictation'")
    }
    return (input, mode, locale, output)
}

func writeOutput(_ json: OutputJSON, to path: String?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(json)
    if let path {
        try data.write(to: URL(fileURLWithPath: path))
    } else {
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}

func cmTimeToSec(_ t: CMTime) -> Double {
    guard t.isValid, !t.isIndefinite else { return 0 }
    return CMTimeGetSeconds(t)
}

@main
struct SpeechAnalyzerS2 {
    static func main() async {
        let start = Date()
        do {
            let (inputPath, mode, localeID, outputPath) = try parseArgs()
            let result = try await run(inputPath: inputPath, mode: mode, localeID: localeID, wallStart: start)
            try writeOutput(result, to: outputPath)
        } catch {
            let wallMs = Date().timeIntervalSince(start) * 1000
            let errJSON = OutputJSON(
                mode: "unknown", locale: "unknown", inputPath: "unknown",
                text: "", segments: [], wallMs: wallMs, wordTimestampCount: 0,
                segmentCount: 0, audioDurationSec: nil,
                error: "\(error)"
            )
            try? writeOutput(errJSON, to: nil)
            exit(1)
        }
    }

    static func run(inputPath: String, mode: String, localeID: String, wallStart: Date) async throws -> OutputJSON {
        // 1. Locale resolution + availability gate — an honest failure if the
        //    module or the requested locale's assets aren't available on this
        //    machine, which is itself an S2 finding (OS/beta state).
        let requestedLocale = Locale(identifier: localeID)

        if mode == "transcriber" {
            guard SpeechTranscriber.isAvailable else {
                throw CLIError(message: "SpeechTranscriber.isAvailable == false on this machine")
            }
        }
        // DictationTranscriber does not expose a static `isAvailable`; its
        // availability is implied by successful construction + asset checks
        // below (mirrors what a real port would have to do).

        let audioURL = URL(fileURLWithPath: inputPath)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioDurationSec = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        /// 2. Build the requested module, resolving to its supported-locale
        ///    equivalent and requiring installed assets (no silent download).
        func resolvedLocale<M: LocaleDependentSpeechModule>(for moduleType: M.Type) async throws -> Locale {
            guard let supported = await M.supportedLocale(equivalentTo: requestedLocale) else {
                throw CLIError(message: "\(moduleType) has no supported locale equivalent to \(localeID)")
            }
            return supported
        }

        var transcriberModule: SpeechTranscriber?
        var dictationModule: DictationTranscriber?
        let resolvedLocaleID: String

        switch mode {
        case "transcriber":
            let locale = try await resolvedLocale(for: SpeechTranscriber.self)
            resolvedLocaleID = locale.identifier(.bcp47)
            let installed = await SpeechTranscriber.installedLocales
            guard installed.contains(where: { $0.identifier(.bcp47) == resolvedLocaleID }) else {
                throw CLIError(message: "SpeechTranscriber assets for \(resolvedLocaleID) are not installed")
            }
            transcriberModule = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
        case "dictation":
            let locale = try await resolvedLocale(for: DictationTranscriber.self)
            resolvedLocaleID = locale.identifier(.bcp47)
            dictationModule = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
        default:
            throw CLIError(message: "unreachable mode \(mode)")
        }

        let modules: [any SpeechModule] = transcriberModule.map { [$0] } ?? dictationModule.map { [$0] } ?? []
        guard !modules.isEmpty else { throw CLIError(message: "no module constructed") }

        // 3. Whole-file, single-session analysis — the thing S2 needs to
        //    verify: does this truncate/hang on long (up to ~80 min) audio?
        let analyzer = SpeechAnalyzer(modules: modules)

        // Drain results concurrently with feeding the file. The Task's return
        // value (not a captured outer `var`) carries the collected segments,
        // so the closure has no mutable outer captures and stays Sendable
        // under Swift 6 strict concurrency.
        let collector: Task<([Segment], Int), Error>
        if let transcriberModule {
            collector = Task {
                var segments: [Segment] = []
                var wordTimestampCount = 0
                for try await result in transcriberModule.results {
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                    let startSec = cmTimeToSec(result.range.start)
                    let endSec = cmTimeToSec(result.range.end)
                    var confidences: [Double] = []
                    for run in result.text.runs {
                        if let c = run.transcriptionConfidence {
                            confidences.append(c)
                        }
                        if run.audioTimeRange != nil {
                            wordTimestampCount += 1
                        }
                    }
                    let avgConf = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                    segments.append(Segment(text: text, start: startSec, end: endSec, confidence: avgConf))
                }
                return (segments, wordTimestampCount)
            }
        } else if let dictationModule {
            collector = Task {
                var segments: [Segment] = []
                var wordTimestampCount = 0
                for try await result in dictationModule.results {
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                    let startSec = cmTimeToSec(result.range.start)
                    let endSec = cmTimeToSec(result.range.end)
                    for run in result.text.runs {
                        if run.audioTimeRange != nil {
                            wordTimestampCount += 1
                        }
                    }
                    segments.append(Segment(text: text, start: startSec, end: endSec, confidence: nil))
                }
                return (segments, wordTimestampCount)
            }
        } else {
            throw CLIError(message: "no module to drain")
        }

        // Feed the whole file to the analyzer. analyzeSequence(from:) reads
        // the file to completion and returns the last sample time (or nil if
        // nothing was analyzed); we then finalize through that point so the
        // results sequence completes and `collector` above returns.
        let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let (segments, wordTimestampCount) = try await collector.value

        let fullText = segments.map(\.text).joined(separator: " ")
        let wallMs = Date().timeIntervalSince(wallStart) * 1000

        return OutputJSON(
            mode: mode,
            locale: resolvedLocaleID,
            inputPath: inputPath,
            text: fullText,
            segments: segments,
            wallMs: wallMs,
            wordTimestampCount: wordTimestampCount,
            segmentCount: segments.count,
            audioDurationSec: audioDurationSec,
            error: nil
        )
    }
}
