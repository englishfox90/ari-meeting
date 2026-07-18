# Model fixtures

These JSON files are **hand-authored** representations of the **camelCase domain shape** the
Swift `Models` types decode. They exist so `ModelsCodableTests` can assert round-trip decoding.

⚠️ **These are NOT byte-for-byte the frozen Rust engine's IPC output for every type.** The
persons / calendar / series engine structs carry `#[serde(rename_all = "camelCase")]`, so their
wire JSON *is* camelCase and these fixtures do mirror it. But the four **database-origin** types
— `Meeting`, `Transcript`, `Speaker`, `SpeakerSegment` — have **no `rename_all`** in Rust
(`database/models.rs`), and the engine's actual IPC DTOs emit **snake_case** (`folder_path`,
`created_at`, `audio_start_time`, `speaker_id`, `total_speech_secs`, `cluster_key`, … — see
`api/api.rs:365-398`). The Swift domain types are camelCase-native by design (wire mapping is
deferred to the Store/Engine seam — plan §7.7), so **decoding real engine JSON for those four
types requires a snake→camel adapter at that seam** — `Models.jsonDecoder` will NOT decode raw
engine output for them.

These fixtures are placeholders **to be replaced with captured live engine JSON** once IPC
capture is wired up (plan §5 test 2, §8 risk (a)) — which will surface exactly that snake_case
mismatch and force the adapter. Notable shape details deliberately encoded here:

- `ProfileFact` / `ProfileFactSource` use the wire key `sourceKind` (the Swift property is
  `origin`, reconciling the Rust `source_kind → origin` rename — plan §7.2).
- Dates are RFC3339 with a `Z` zone. `centroid` / `embedding` are base64 (the default
  `Data` JSON encoding) — model vectors, not audio.
- Field values mirror `ModelSamples` so the suite can assert decoded value equality.
