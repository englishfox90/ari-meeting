# Fixtures — `AriKitDiarizationFluidAudioTests`

`FluidAudioDiarizationProviderTests.twoVoiceFixtureYieldsAtLeastTwoClusters` (plan
`docs/plans/arikit-diarization.md` §5, D7) is a manual/opt-in integration test: it downloads the
real ~21 MB FluidAudio community-1 CoreML models and runs the actual offline diarization pipeline
against a bundled two-speaker recording.

That recording — `diarization-two-voices.wav` (16 kHz mono, ideally ≥30s with two genuinely
distinct speakers) — is **not present in this checkout**. Real, distinguishable human speech
cannot be synthesized as a stand-in; a fabricated tone pair would not exercise the real speaker
embedding model meaningfully and risks a flaky pass/fail unrelated to the pipeline under test.

Until this fixture is added by a human (e.g. two short clips from Paul's own recordings, mixed
into one file), the test is skipped — gated by both the fixture's presence on disk *and*
`ARIKIT_DIARIZATION_INTEGRATION=1` in the environment, so it never runs unintentionally and never
fails CI for the missing-fixture reason. Once the fixture is dropped in here, drop
`ARIKIT_DIARIZATION_INTEGRATION=1` when invoking `swift test` to exercise it.
