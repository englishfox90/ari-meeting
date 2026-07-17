# samples/ — third-party reference projects (gitignored)

A dropzone for **read-only reference code** during the Swift migration: Apple
documentation sample projects, vendor examples, and small proofs pulled from the
web. Drop a sample here so it's co-located with the repo and easy for Claude Code
(and you) to reference while porting the engine to Swift.

## Rules

- **Gitignored.** Everything in this directory is ignored except this `README.md`
  (see the `/samples/*` + `!/samples/README.md` rule in the root `.gitignore`).
  Nothing here is committed, built, or shipped.
- **Reference only — never import.** These are for reading patterns. Do **not**
  add them as SwiftPM dependencies, `#include` them, or copy licensed code
  verbatim into `AriKit/`, the app targets, or the sidecars. Learn the pattern,
  then write our own implementation. (Apple sample code carries Apple's sample
  license; other samples carry their own — respect them.)
- **Throwaway.** Safe to delete any subfolder at any time; re-download from the
  source when needed. Note where each sample came from below.

## Contents

| Folder | Source | Why it's here |
|--------|--------|---------------|
| `RecognizingSpeechInLiveAudio/` | [Apple — Recognizing speech in live audio](https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio) | Canonical **live** SpeechAnalyzer pattern for the Phase-3 STT port: `DictationTranscriber(.progressiveLongDictation)` + `SpeechAnalyzer.analyzeSequence`, streaming volatile→final results with `audioTimeRange`, `AssetInventory` model download, and a **custom language model** via `contentHints: [.customizedLanguage(...)]`. |

_Add a row whenever you drop a new sample in, with its source URL._
