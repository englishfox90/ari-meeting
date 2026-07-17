# Rule: Tauri IPC (Frontend ↔ Rust)

The frontend talks to the Rust core exclusively through Tauri commands (`invoke`) and events (`listen`). ~150 commands are registered.

## Adding a new command — the TWO-edit workflow

Forgetting the second edit is the classic silent failure (the command compiles but isn't callable).

1. **Define** the command in the appropriate module (not a dumping ground — put it with its domain):
   ```rust
   #[tauri::command]
   async fn my_command(
       arg_name: String,
       state: tauri::State<'_, AppState>,
   ) -> Result<MyResult, String> {
       // DB access via state.db_manager.pool() → a repository
   }
   ```
2. **Register** it in the `invoke_handler!` `generate_handler![…]` list in `frontend/src-tauri/src/lib.rs`. (macOS-only commands are `#[cfg(target_os = "macos")]`-gated inline.)
3. **Call** it from the frontend — prefer wrapping in the matching `src/services/*Service.ts`; call via `invoke` from `@tauri-apps/api/core`.

## Argument casing — two layers, don't conflate them

There are **two distinct casing rules** depending on where the key sits. Getting this wrong is the classic silent IPC failure, so be precise about which layer you're in.

### Layer 1 — top-level `invoke` keys (the command's own parameters) → **camelCase**

Every top-level key in `invoke(cmd, { … })` maps to a command **parameter**. Tauri v2 converts
JS **camelCase → snake_case** Rust param names (`meetingId` → `meeting_id`). No command in this
codebase overrides this (there are **zero** `#[tauri::command(rename_all = …)]` attributes), so
the rule is universal. Verified: `api_delete_meeting({ meetingId })` hits `meeting_id: String`.

```typescript
// Rust params are snake_case; the JS keys are camelCase.
await invoke('api_delete_meeting', { meetingId });
await invoke('start_recording_with_devices_and_meeting', {
  micDeviceName: mic,          // → Rust mic_device_name: Option<String>  (lib.rs:344)
  systemDeviceName: sys,       // → system_device_name
  meetingName: name,           // → meeting_name
});
```

⚠️ **A snake_case top-level key is a silent trap.** It doesn't match the expected camelCase, so
Tauri treats the arg as absent:
- **Required param** (`String`, `Vec<T>`, …) → hard error `missing required key <camelName>`
  (this is exactly what broke the calendar `calendar_set_selected` call).
- **`Option<T>` param** → silently becomes `None`, no error.

So for a command's own params, **always use camelCase**. (There are no top-level snake_case
calls left in the tree; if you see snake_case in an `invoke`, it's Layer 2 below.)

### Layer 2 — keys *nested inside* a struct-typed param → **whatever serde says**

When a parameter's type is a **struct**, that whole nested object is deserialized by **serde**,
not by Tauri's arg conversion — so the nested keys must match the struct's serde field names:

- Struct with **no** `#[serde(rename_all)]` → fields stay **snake_case** → use snake_case keys.
- Struct with `#[serde(rename_all = "camelCase")]` (most models — calendar, persons,
  meeting_series, recall) → use **camelCase** keys.

This is the *only* reason snake_case appears in `invoke` calls today, and it's correct:

```typescript
// `stop_recording(args: RecordingArgs)`, and RecordingArgs { save_path: String } is NOT renamed.
// Top-level key `args` = the param name; nested `save_path` = the unrenamed serde field.
await invoke('stop_recording', { args: { save_path: savePath } });

// `save_onboarding_status_cmd(status: OnboardingStatus)` — OnboardingStatus/ModelStatus unrenamed,
// so nested keys are snake_case:
await invoke('save_onboarding_status_cmd', {
  status: { version: '1.0', completed, current_step: step, model_status: { … } },
});
```

Rule of thumb: **the command's parameters are camelCase; the fields of a struct you pass follow
that struct's `#[serde(rename_all)]`** (snake_case when there's no rename). When in doubt, open
the struct definition.

## Command conventions

- Async commands return `Result<T, String>`.
- Most take `state: tauri::State<'_, AppState>` for DB access.
- Some carry an unused `_auth_token: Option<String>` / `_app` param — a legacy shape from the old HTTP era. Keep it on sibling commands so the frontend call shape stays consistent; it does nothing.

## Events (Rust → Frontend)

```rust
app.emit("transcript-update", payload)?;
```
```typescript
await listen<T>('transcript-update', (e) => { /* update React state */ });
```

Guard frontend code that assumes Tauri exists — plain-browser (`pnpm run dev`) has no Tauri runtime.

## Never reintroduce the HTTP backend

The app is fully native (SQLite + repositories). Do not add a `localhost:5167` HTTP dependency or resurrect the archived Python backend. New backend behavior goes through Tauri commands + Rust services.
