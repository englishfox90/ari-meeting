# Audio Import (Swift) — import an existing recording as a meeting

Ports the frozen Rust/Tauri "import audio" feature (`frontend/src-tauri/src/audio/import.rs`
+ `ImportAudioDialog.tsx`) into the Swift-native app, with **one deliberate addition**: the
user chooses the **date & time the meeting actually happened**, so an imported old recording no
longer shows *today* as its date.

## Why the date/time matters

The Rust importer stamps the new meeting with `created_at = Utc::now()` (`import.rs:721`), i.e.
the *import* moment, not the *meeting* moment. `Meeting.createdAt` is the canonical instant the
whole app sorts, groups, and calendar-matches on (`MeetingRepository.all` orders by
`createdAt desc`; `closestMeetingID` matches on it). So importing last week's recording buried it
at "today" and mis-ordered the library. The fix: let the user set `createdAt` to the real
meeting time at import.

## Scope decision — reuse the engine, don't re-port the pipeline

The Rust importer hand-rolls decode → resample → VAD → per-segment transcription. In Swift that
whole chain is subsumed by `SpeechTranscriberProvider.transcribe(fileURL:language:)`
(`AriKit/.../Engine/STT/SpeechTranscriberProvider.swift`): SpeechAnalyzer opens the file, does its
own segmentation, and returns `[TranscriptionSegment]`. So the Swift import is thin:

1. Copy the picked file into a per-meeting folder.
2. `transcribe(fileURL:)` → segments.
3. `TranscriptMapping.transcripts(from:meetingId:)` → `[Transcript]` (the exact mapping the live
   recording path already uses).
4. Persist a `Meeting` (`createdAt = user-chosen date`) + the transcripts.
5. Kick the existing post-recording pipeline (`MeetingProcessingCoordinator.begin`).

No VAD/decode/resample port; no new STT code.

## Audio reference shape

`AudioAvailabilityResolver` already resolves **two** `audioReference` shapes: a recording *folder*
(looks for `audio.m4a`/`audio.mp4`) and a *direct file path with an extension* (the legacy-import
shape). Import stores the copied file's **full path** `…/<meetingID>/audio.<ext>`, so any container
(`.mp3`/`.m4a`/`.wav`/…) resolves with **no change to the resolver or `audioFileNames`** and **no
transcode**. AVFoundation decodes the same file for playback and (non-blocking) diarization.

## Components

- **`AriViewModels/MeetingImportSession.swift`** — `@MainActor @Observable` operation coordinator,
  mirroring `RecordingSession`'s shape. Holds `database`, `recordingsRoot`, a
  `TranscriptionProvider`, and a `clock`. `Phase`: `.idle → .importing(Stage) → .saved(MeetingID)
  | .failed(String)`, `Stage`: `.preparing/.transcribing/.saving` (honest stages, **no fabricated
  percentage** — SpeechAnalyzer's whole-file driver exposes no incremental progress). Reentrancy-
  guarded like `RecordingSession` (proceeds only from `.idle`/terminal). The heavy file copy runs
  in a detached task so the main actor stays responsive.
- **`Ari/UI/NewMeeting/ImportMeetingSheet.swift`** — the import sheet (Marginalia-styled): file
  picker (`.fileImporter`), title field, **`DatePicker` [.date, .hourAndMinute]** defaulting to
  now, honest progress + error states. Owns form state; delegates the operation to the session.
  `AudioFileInfo` + the AVFoundation probe (duration/format/size, display-only) live here in the
  app target so `AriViewModels` stays AVFoundation-free.
- **Wiring**: `AppEnvironment` constructs `importSession` at the composition root
  (`SpeechTranscriberProvider()` as the provider). `SidebarView`'s existing (dead) "Import audio"
  button is wired to present the sheet. `RootSplitView` presents the sheet and, on
  `.saved(meetingID)`, dismisses, calls `processingCoordinator.begin`, navigates to the meeting,
  and resets the session — exactly mirroring the recording `.saved` handler.

## Invariants preserved

- **No-Fake-State**: every failure (unsupported format, unreadable file, engine unavailable/assets
  missing, copy/DB failure) surfaces the real reason; progress stages are real, never a fake %; an
  all-silence file still creates the meeting honestly with zero transcripts (matching the Rust
  importer). `createdAt` is user-supplied truth, `updatedAt` is the real import instant.
- **Repositories-only** persistence (`db.meetings`/`db.transcripts`), single-DB-owner unchanged.
- **Swift 6 strict concurrency**: session is `@MainActor`; injected provider is `Sendable`; the
  copy hop captures only `Sendable` URLs.

## Tests

`AriKit/Tests/AriViewModelsTests/MeetingImportSessionTests.swift` (Swift Testing, headless via
`AppDatabase.makeInMemory()` + `StubTranscriptionProvider`): the meeting's `createdAt` equals the
chosen date (the feature); transcripts are persisted and mapped from segments; `audioReference`
points at the copied file; a silent (empty-segments) import still saves; a transcription error
fails honestly and leaves no meeting; reentrancy is a no-op mid-import.
