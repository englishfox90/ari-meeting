// fluidaudio-s3 — throwaway CLI spike for the Swift-migration S3 diarization eval.
//
// Runs FluidAudio's OFFLINE (pyannote community-1) CoreML diarization pipeline
// over a 16 kHz mono WAV file and emits a standard RTTM file, so the existing
// Python DER rig (tools/diarization-sweep/der.py) can score it against the
// hand-labelled reference exactly like the app's own sherpa-onnx diarize-helper
// output. Offline (not streaming/LS-EEND) is used deliberately — see README.
//
// Usage:
//   fluidaudio-s3 <input.wav> <output.rttm> <uri> [--threshold <double>]
//
// Example:
//   fluidaudio-s3 /tmp/adhoc-nia-16k.wav /tmp/adhoc-nia.rttm adhoc-nia --threshold 0.6

import FluidAudio
import Foundation

// MARK: - CLI argument parsing

struct CLIArguments {
    let inputWAVPath: String
    let outputRTTMPath: String
    let uri: String
    let clusteringThreshold: Double?
    let numSpeakers: Int?
    let minSpeakers: Int?
    let maxSpeakers: Int?
}

func printUsage() {
    print(
        """
        Usage: fluidaudio-s3 <input.wav> <output.rttm> <uri> [--threshold <double>]

        Arguments:
          input.wav     16 kHz mono WAV file (the diarization-sweep rig pre-decodes
                        with ffmpeg -ar 16000 -ac 1; this CLI validates and refuses
                        anything else rather than silently resampling).
          output.rttm   Path to write the RTTM result to.
          uri           The <uri> field stamped into every RTTM line (meeting id).

        Options:
          --threshold <double>   Override FluidAudio's AHC clustering threshold
                                  (community-1 default is 0.6). Must be in (0, sqrt(2)].
        """
    )
}

func parseArguments(_ args: [String]) -> CLIArguments? {
    guard args.count >= 3 else { return nil }

    let inputWAVPath = args[0]
    let outputRTTMPath = args[1]
    let uri = args[2]
    var clusteringThreshold: Double?
    var numSpeakers: Int?
    var minSpeakers: Int?
    var maxSpeakers: Int?

    func intArg(_ i: Int) -> Int? {
        guard i < args.count, let v = Int(args[i]) else { return nil }
        return v
    }

    var index = 3
    while index < args.count {
        switch args[index] {
        case "--threshold":
            guard index + 1 < args.count, let value = Double(args[index + 1]) else {
                FileHandle.standardError.write(Data("--threshold requires a numeric value\n".utf8))
                return nil
            }
            clusteringThreshold = value
            index += 2
        case "--num-speakers":
            guard let v = intArg(index + 1) else {
                FileHandle.standardError.write(Data("--num-speakers requires an integer\n".utf8)); return nil
            }
            numSpeakers = v; index += 2
        case "--min-speakers":
            guard let v = intArg(index + 1) else {
                FileHandle.standardError.write(Data("--min-speakers requires an integer\n".utf8)); return nil
            }
            minSpeakers = v; index += 2
        case "--max-speakers":
            guard let v = intArg(index + 1) else {
                FileHandle.standardError.write(Data("--max-speakers requires an integer\n".utf8)); return nil
            }
            maxSpeakers = v; index += 2
        default:
            FileHandle.standardError.write(Data("Unknown argument: \(args[index])\n".utf8))
            return nil
        }
    }

    return CLIArguments(
        inputWAVPath: inputWAVPath,
        outputRTTMPath: outputRTTMPath,
        uri: uri,
        clusteringThreshold: clusteringThreshold,
        numSpeakers: numSpeakers,
        minSpeakers: minSpeakers,
        maxSpeakers: maxSpeakers
    )
}

// MARK: - Minimal WAV loader (validates 16 kHz mono, no external decode dependency)

struct WAVFile {
    let sampleRate: Int
    let channelCount: Int
    let bitsPerSample: Int
    let samples: [Float]
}

enum WAVError: Error, CustomStringConvertible {
    case notRIFF
    case notWAVE
    case missingFormatChunk
    case missingDataChunk
    case unsupportedBitDepth(Int)
    case unsupportedFormatTag(Int)
    case wrongSampleRateOrChannels(sampleRate: Int, channels: Int)

    var description: String {
        switch self {
        case .notRIFF: "Not a RIFF file"
        case .notWAVE: "Not a WAVE file"
        case .missingFormatChunk: "Missing fmt chunk"
        case .missingDataChunk: "Missing data chunk"
        case let .unsupportedBitDepth(bits): "Unsupported bit depth: \(bits) (expected 16-bit PCM)"
        case let .unsupportedFormatTag(tag): "Unsupported WAV format tag: \(tag) (expected PCM = 1)"
        case let .wrongSampleRateOrChannels(sampleRate, channels):
            "Input WAV is \(sampleRate) Hz / \(channels) channel(s); this CLI requires 16000 Hz mono. "
                + "Pre-decode with: ffmpeg -i <input> -ar 16000 -ac 1 -y <output>.wav"
        }
    }
}

/// Reads a PCM WAV file into [Float] samples in [-1, 1], validating the header
/// declares exactly 16 kHz mono. This CLI intentionally does not resample —
/// the diarization-sweep rig always pre-decodes with ffmpeg, so a mismatched
/// header means the caller pointed at the wrong file, which should be a loud
/// error, not a silent reinterpretation.
func loadWAV16kMono(at path: String) throws -> WAVFile {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)

    func fourCC(_ offset: Int) -> String {
        String(data: data[offset ..< offset + 4], encoding: .ascii) ?? ""
    }
    func u32(_ offset: Int) -> UInt32 {
        data.subdata(in: offset ..< offset + 4).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }
    func u16(_ offset: Int) -> UInt16 {
        data.subdata(in: offset ..< offset + 2).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
    }

    guard data.count >= 12, fourCC(0) == "RIFF" else { throw WAVError.notRIFF }
    guard fourCC(8) == "WAVE" else { throw WAVError.notWAVE }

    var offset = 12
    var formatTag: Int?
    var channelCount: Int?
    var sampleRate: Int?
    var bitsPerSample: Int?
    var dataRange: Range<Int>?

    while offset + 8 <= data.count {
        let chunkID = fourCC(offset)
        let chunkSize = Int(u32(offset + 4))
        let bodyStart = offset + 8
        let bodyEnd = min(bodyStart + chunkSize, data.count)

        if chunkID == "fmt " {
            formatTag = Int(u16(bodyStart))
            channelCount = Int(u16(bodyStart + 2))
            sampleRate = Int(u32(bodyStart + 4))
            bitsPerSample = Int(u16(bodyStart + 14))
        } else if chunkID == "data" {
            dataRange = bodyStart ..< bodyEnd
        }

        // Chunks are word-aligned; skip the pad byte if chunkSize is odd.
        offset = bodyStart + chunkSize + (chunkSize % 2)
    }

    guard let formatTag, let channelCount, let sampleRate, let bitsPerSample else {
        throw WAVError.missingFormatChunk
    }
    guard let dataRange else { throw WAVError.missingDataChunk }

    // 1 = PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE (ffmpeg-produced 16-bit mono
    // sometimes tags this way even though the payload is plain PCM16).
    guard formatTag == 1 || formatTag == 0xFFFE else {
        throw WAVError.unsupportedFormatTag(formatTag)
    }
    guard bitsPerSample == 16 else {
        throw WAVError.unsupportedBitDepth(bitsPerSample)
    }
    guard sampleRate == 16000, channelCount == 1 else {
        throw WAVError.wrongSampleRateOrChannels(sampleRate: sampleRate, channels: channelCount)
    }

    let pcmData = data.subdata(in: dataRange)
    let sampleCount = pcmData.count / 2
    var samples = [Float](repeating: 0, count: sampleCount)
    pcmData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
        let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
        for i in 0 ..< sampleCount {
            samples[i] = Float(Int16(littleEndian: int16Buffer[i])) / 32768.0
        }
    }

    return WAVFile(
        sampleRate: sampleRate, channelCount: channelCount, bitsPerSample: bitsPerSample, samples: samples
    )
}

// MARK: - RTTM writer

/// Standard RTTM: `SPEAKER <uri> 1 <start> <duration> <NA> <NA> <speakerLabel> <NA> <NA>`
func writeRTTM(segments: [TimedSpeakerSegment], uri: String, to path: String) throws {
    var lines: [String] = []
    for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
        let start = Double(segment.startTimeSeconds)
        let duration = Double(segment.endTimeSeconds - segment.startTimeSeconds)
        guard duration > 0 else { continue }
        let line = String(
            format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>",
            uri, start, duration, segment.speakerId
        )
        lines.append(line)
    }
    let contents = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Main

func run() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let cli = parseArguments(arguments) else {
        printUsage()
        exit(64) // EX_USAGE
    }

    let overallStart = Date()

    let wav: WAVFile
    do {
        wav = try loadWAV16kMono(at: cli.inputWAVPath)
    } catch {
        FileHandle.standardError.write(Data("Failed to load WAV: \(error)\n".utf8))
        exit(1)
    }
    print("Loaded \(cli.inputWAVPath): \(wav.samples.count) samples @ \(wav.sampleRate) Hz mono")

    var config = OfflineDiarizerConfig.default
    if let threshold = cli.clusteringThreshold {
        config.clusteringThreshold = threshold
    }
    if let n = cli.numSpeakers {
        config.clustering.numSpeakers = n
    }
    if let mn = cli.minSpeakers {
        config.clustering.minSpeakers = mn
    }
    if let mx = cli.maxSpeakers {
        config.clustering.maxSpeakers = mx
    }
    print(
        "clustering: threshold=\(config.clustering.threshold) numSpeakers=\(String(describing: config.clustering.numSpeakers)) min=\(String(describing: config.clustering.minSpeakers)) max=\(String(describing: config.clustering.maxSpeakers))"
    )

    let modelsDirectory = OfflineDiarizerModels.defaultModelsDirectory()
    print("FluidAudio CoreML model cache: \(modelsDirectory.path)")

    let manager = OfflineDiarizerManager(config: config)

    do {
        let modelsStart = Date()
        try await manager.prepareModels()
        print("Models ready in \(String(format: "%.1f", Date().timeIntervalSince(modelsStart)))s")
    } catch {
        FileHandle.standardError.write(Data("Failed to prepare FluidAudio models: \(error)\n".utf8))
        exit(1)
    }

    let result: DiarizationResult
    do {
        result = try await manager.process(audio: wav.samples) { chunksProcessed, totalChunks in
            if chunksProcessed % 20 == 0 || chunksProcessed == totalChunks {
                print("  segmentation chunk \(chunksProcessed)/\(totalChunks)")
            }
        }
    } catch {
        FileHandle.standardError.write(Data("Diarization failed: \(error)\n".utf8))
        exit(1)
    }

    do {
        try writeRTTM(segments: result.segments, uri: cli.uri, to: cli.outputRTTMPath)
    } catch {
        FileHandle.standardError.write(Data("Failed to write RTTM: \(error)\n".utf8))
        exit(1)
    }

    let distinctSpeakers = Set(result.segments.map(\.speakerId))
    let totalSpeechSeconds = result.segments.reduce(0.0) { $0 + Double($1.durationSeconds) }
    let elapsed = Date().timeIntervalSince(overallStart)

    print(
        """

        --- fluidaudio-s3 summary ---
        segments:            \(result.segments.count)
        distinct speakers:   \(distinctSpeakers.count) (\(distinctSpeakers.sorted().joined(separator: ", ")))
        total speech (s):    \(String(format: "%.1f", totalSpeechSeconds))
        model cache path:    \(modelsDirectory.path)
        elapsed (s):         \(String(format: "%.1f", elapsed))
        RTTM written to:     \(cli.outputRTTMPath)
        """
    )
}

await run()
