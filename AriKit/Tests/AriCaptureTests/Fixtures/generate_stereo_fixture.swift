#!/usr/bin/env swift
//
//  generate_stereo_fixture.swift — regenerates `diarization-stereo-1s.m4a`, the fixture consumed
//  by `DiarizationAudioLoaderTests` (docs/plans/arikit-diarization.md §5, D6).
//
//  Deliberately asymmetric: the LEFT channel is silent and the RIGHT channel carries a 330 Hz
//  tone at 0.5 amplitude. A downmix implementation that (incorrectly) maps output <- input
//  channel 0 only, per AVAudioConverter's `downmix = false` default, produces all-zero output
//  against this fixture — the failure `DiarizationAudioLoaderTests.downmixesMultiChannelInput`
//  is written to catch. A correct mono downmix (`converter.downmix = true`) preserves the
//  right-channel signal energy.
//
//  Run from the repo root:
//    swift AriKit/Tests/AriCaptureTests/Fixtures/generate_stereo_fixture.swift \
//      AriKit/Tests/AriCaptureTests/Fixtures/diarization-stereo-1s.m4a
//
import AVFoundation
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "diarization-stereo-1s.m4a"
let outputURL = URL(fileURLWithPath: outputPath)

let sampleRate = 44100.0
let duration = 1.0
let frameCount = AVAudioFrameCount(sampleRate * duration)
let toneHz = 330.0
let amplitude: Float = 0.5

guard let pcmFormat = AVAudioFormat(
    standardFormatWithSampleRate: sampleRate,
    channels: 2
) else {
    fatalError("could not construct source PCM format")
}

guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
    fatalError("could not allocate PCM buffer")
}
buffer.frameLength = frameCount

guard let channelData = buffer.floatChannelData else {
    fatalError("no float channel data")
}
let left = channelData[0]
let right = channelData[1]
for frame in 0 ..< Int(frameCount) {
    left[frame] = 0 // silent left channel — the whole point of this fixture
    let t = Double(frame) / sampleRate
    right[frame] = amplitude * Float(sin(2.0 * Double.pi * toneHz * t))
}

let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 2,
]

do {
    let file = try AVAudioFile(forWriting: outputURL, settings: settings)
    try file.write(from: buffer)
    print("Wrote \(outputURL.path)")
} catch {
    fatalError("failed to write fixture: \(error)")
}
