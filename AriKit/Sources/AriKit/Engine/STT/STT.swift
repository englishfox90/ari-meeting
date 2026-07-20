///
///  STT.swift — module namespace for the ported speech-to-text layer
///  (docs/plans/arikit-stt.md).
///
///  Phase 3.3 replaces the frozen Rust `TranscriptionProvider` trait + whisper.cpp/Parakeet-ONNX
///  engines (`frontend/src-tauri/src/audio/transcription/provider.rs`, `whisper_engine/`,
///  `parakeet_engine/`) with a capture-agnostic Swift STT layer under `Engine/STT/`, built on
///  Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber` (macOS/iOS 26). Unlike the recall/summary
///  ports, the STT engines DISSOLVE into a system framework — there is no whisper.cpp/ONNX inference
///  loop to reproduce in Swift; `SpeechAnalyzer`/`SpeechTranscriber` IS the replacement engine
///  (plan §0). `STT` is stateless — it produces `[TranscriptionSegment]`, never writes the DB
///  (persistence is the capture/orchestration layer's job, Phase 3.2, through `TranscriptRepository`).
///
///  Landed so far:
///  - **Slice A** (pure, no deps) — the `TranscriptionProvider` protocol, its value types
///    (`TranscriptionResult`/`TranscriptionSegment`/`WordTiming`) and `TranscriptionError`,
///    `STTLocale`'s sentinel locale mapping, `CMTimeMapping`'s `CMTime`→seconds guard and per-run
///    word/confidence extraction, and the `#if DEBUG` `StubTranscriptionProvider` test double.
///  - **Slice B** — `SpeechAssetManager`, absorbing `EnsureAssets`/`Probe`'s asset half in-process.
///  - **Slice D** — `TranscriptMapping`, the pure `TranscriptionSegment → Models.Transcript` map.
///  - **Slice C** — `SpeechTranscriberProvider`, the recorded-file (`transcribe(fileURL:language:)`)
///    conformer over `SpeechAnalyzer`/`SpeechTranscriber`, absorbing the S2 spike's whole-file
///    driver (`Entry.swift`). Its live-stream entrypoint is a Slice-E stub for now — designed, not
///    verified.
///
///  Later slices (plan §5) complete the live-stream interface (E). The accuracy-eval harness
///  (plan §8/§11) is main-loop-side, outside this package — not a subagent slice.
///
public enum STT {}
