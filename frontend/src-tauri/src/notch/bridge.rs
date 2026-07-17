//! `NotchBridge` — owns the `ari-notch` sidecar child process and translates
//! between Tauri recording events and the notch IPC protocol (see
//! [`crate::notch::protocol`]).
//!
//! ## Design: pure logic + thin glue
//!
//! The decision logic is factored into small, side-effect-free units that are
//! unit-tested WITHOUT spawning a child process or a Tauri runtime:
//! - [`AudioLevelThrottle`] — rate-limits `audio-levels` to ≤10 Hz.
//! - [`action_to_intent`] — maps a wire [`NotchAction`] to a [`NotchIntent`].
//! - [`recording_state_msg`] — builds a [`NotchInbound::RecordingState`] from the
//!   `get_recording_state` JSON snapshot.
//! - [`audio_level_from_payload`] — extracts a single 0..1 level from the
//!   `audio-levels` event payload.
//! - [`NotchSink`] — abstracts "write one message"; the real impl writes NDJSON
//!   to the child's stdin, tests inject a capturing mock.
//!
//! The `NotchShared` runtime and the Tauri commands are the thin glue around
//! those units. They are not unit-tested (they need a live child + Tauri app).
//!
//! ## Best-effort
//!
//! If the `ari-notch` binary is absent, everything degrades to no-ops with a
//! debug log — `cargo check` and app launch succeed with no binary present.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use tauri::{AppHandle, Listener, Manager, Runtime};

use crate::notch::protocol::{NotchAction, NotchInbound, NotchOutbound};
use crate::notch::resolver::resolve_notch_binary;

// ============================================================================
// Pure unit 1: audio-level throttle (≤10 Hz)
// ============================================================================

/// Minimum spacing between forwarded `AudioLevel` messages → at most 10 per second.
pub const AUDIO_LEVEL_MIN_INTERVAL: Duration = Duration::from_millis(100);

/// Rate-limiter for high-frequency audio-level updates. Pure and cargo-testable.
pub struct AudioLevelThrottle {
    last_sent: Option<Instant>,
    min_interval: Duration,
}

impl AudioLevelThrottle {
    pub fn new(min_interval: Duration) -> Self {
        Self {
            last_sent: None,
            min_interval,
        }
    }

    /// Returns `true` (and records `now`) if a message may be sent at `now`;
    /// `false` if the last send was too recent.
    pub fn admit(&mut self, now: Instant) -> bool {
        match self.last_sent {
            Some(prev) if now.duration_since(prev) < self.min_interval => false,
            _ => {
                self.last_sent = Some(now);
                true
            }
        }
    }
}

impl Default for AudioLevelThrottle {
    fn default() -> Self {
        Self::new(AUDIO_LEVEL_MIN_INTERVAL)
    }
}

// ============================================================================
// Pure unit 2: sidecar action → internal intent
// ============================================================================

/// A resolved intent derived from a sidecar [`NotchAction`]. Turning an intent
/// into an actual command invocation is separate, untested glue
/// ([`dispatch_intent`]).
#[derive(Debug, Clone, PartialEq)]
pub enum NotchIntent {
    /// Start recording, remembering the calendar event to link to.
    StartRecordingForEvent { event_id: String },
    Pause,
    Resume,
    Stop,
    /// Bring the app forward, optionally deep-linking a route.
    OpenApp { route: Option<String> },
}

/// Pure mapping from a wire action to an internal intent.
pub fn action_to_intent(action: &NotchAction) -> NotchIntent {
    match action {
        NotchAction::RecordEvent { event_id } => NotchIntent::StartRecordingForEvent {
            event_id: event_id.clone(),
        },
        NotchAction::Pause => NotchIntent::Pause,
        NotchAction::Resume => NotchIntent::Resume,
        NotchAction::Stop => NotchIntent::Stop,
        NotchAction::OpenApp { route } => NotchIntent::OpenApp {
            route: route.clone(),
        },
    }
}

// ============================================================================
// Pure unit 3: recording-state snapshot → RecordingState message
// ============================================================================

/// Build a [`NotchInbound::RecordingState`] from the JSON returned by
/// `audio::recording_commands::get_recording_state`. `elapsed_seconds` uses the
/// *active* (pause-excluded) duration, falling back to total recording duration.
pub fn recording_state_msg(
    state_json: &serde_json::Value,
    meeting_name: Option<String>,
    linked_event_id: Option<String>,
) -> NotchInbound {
    let is_recording = state_json
        .get("is_recording")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let is_paused = state_json
        .get("is_paused")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    let elapsed = state_json
        .get("active_duration")
        .and_then(|v| v.as_f64())
        .or_else(|| state_json.get("recording_duration").and_then(|v| v.as_f64()))
        .unwrap_or(0.0);
    let elapsed_seconds = if elapsed.is_finite() && elapsed > 0.0 {
        elapsed as u64
    } else {
        0
    };

    NotchInbound::RecordingState {
        is_recording,
        is_paused,
        meeting_name,
        elapsed_seconds,
        linked_event_id,
    }
}

// ============================================================================
// Pure unit 4: audio-levels payload → single normalized level
// ============================================================================

/// Extract a single 0.0–1.0 level from an `audio-levels` event payload. Takes
/// the max RMS across all reported devices. Returns `None` if the payload can't
/// be parsed or carries no levels.
pub fn audio_level_from_payload(payload: &str) -> Option<f32> {
    let v: serde_json::Value = serde_json::from_str(payload).ok()?;
    let levels = v.get("levels")?.as_array()?;
    let mut max = 0.0f32;
    let mut any = false;
    for l in levels {
        if let Some(rms) = l.get("rms_level").and_then(|x| x.as_f64()) {
            any = true;
            max = max.max(rms as f32);
        }
    }
    if any {
        Some(max.clamp(0.0, 1.0))
    } else {
        None
    }
}

// ============================================================================
// NotchSink: the write-one-message abstraction (real + injectable for tests)
// ============================================================================

/// Sink for outbound [`NotchInbound`] messages. The real impl serializes NDJSON
/// to the child's stdin; tests inject a capturing mock.
pub trait NotchSink: Send {
    fn send(&mut self, msg: &NotchInbound) -> anyhow::Result<()>;
}

/// Real sink: one NDJSON line (`serde_json` + `\n`) flushed to the child stdin.
struct ChildStdinSink {
    stdin: ChildStdin,
}

impl NotchSink for ChildStdinSink {
    fn send(&mut self, msg: &NotchInbound) -> anyhow::Result<()> {
        let line = serde_json::to_string(msg)?;
        self.stdin.write_all(line.as_bytes())?;
        self.stdin.write_all(b"\n")?;
        self.stdin.flush()?;
        Ok(())
    }
}

/// Throttle a burst of audio levels and forward only the admitted ones to a
/// sink. Pure helper shared by the live listener and the throttle unit test.
/// Returns `true` if the level was admitted and sent.
pub fn forward_audio_level(
    throttle: &mut AudioLevelThrottle,
    sink: &mut dyn NotchSink,
    now: Instant,
    level: f32,
) -> anyhow::Result<bool> {
    if throttle.admit(now) {
        sink.send(&NotchInbound::AudioLevel { level })?;
        Ok(true)
    } else {
        Ok(false)
    }
}

// ============================================================================
// NotchShared: the live runtime (thin glue around the pure units)
// ============================================================================

/// Shared runtime state for one enabled notch session. Cloned (`Arc`) into the
/// event listeners, the stdout reader thread, and the 1 Hz supervisor task.
struct NotchShared {
    app: AppHandle,
    sink: Mutex<Option<ChildStdinSink>>,
    child: Mutex<Option<Child>>,
    throttle: Mutex<AudioLevelThrottle>,
    stop: AtomicBool,
    /// Bumped on every (re)spawn; a stale reader thread uses it to avoid nulling
    /// a freshly-created sink.
    generation: AtomicU64,
    /// The calendar event the current recording is associated with, if any.
    linked_event_id: Mutex<Option<String>>,
}

impl NotchShared {
    fn new(app: AppHandle) -> Arc<Self> {
        Arc::new(Self {
            app,
            sink: Mutex::new(None),
            child: Mutex::new(None),
            throttle: Mutex::new(AudioLevelThrottle::default()),
            stop: AtomicBool::new(false),
            generation: AtomicU64::new(0),
            linked_event_id: Mutex::new(None),
        })
    }

    fn is_connected(&self) -> bool {
        self.sink.lock().map(|g| g.is_some()).unwrap_or(false)
    }

    /// Send a message down to the sidecar. On a write error (broken pipe → child
    /// died) the sink is cleared so the supervisor respawns on its next tick.
    fn send(&self, msg: &NotchInbound) {
        let mut guard = match self.sink.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        if let Some(sink) = guard.as_mut() {
            if let Err(e) = sink.send(msg) {
                log::debug!("ari-notch: send failed ({e}); marking child disconnected");
                *guard = None;
            }
        }
    }

    /// Spawn (or respawn) the sidecar child. Best-effort: returns `Err` if the
    /// binary is missing or spawn fails — the caller logs at debug and retries
    /// later. Never panics.
    fn spawn_child(self: &Arc<Self>) -> anyhow::Result<()> {
        if self.stop.load(Ordering::SeqCst) {
            return Ok(());
        }

        let bin = resolve_notch_binary()?;

        // NOTE: NOT wrapped in `nice` — the notch is a latency-sensitive UI helper.
        let mut child = Command::new(&bin)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow::anyhow!("ari-notch: failed to capture child stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("ari-notch: failed to capture child stdout"))?;

        let my_gen = self.generation.fetch_add(1, Ordering::SeqCst) + 1;

        if let Ok(mut sink_guard) = self.sink.lock() {
            *sink_guard = Some(ChildStdinSink { stdin });
        }
        if let Ok(mut child_guard) = self.child.lock() {
            // Reap any previous corpse before replacing.
            if let Some(mut old) = child_guard.take() {
                let _ = old.kill();
                let _ = old.wait();
            }
            *child_guard = Some(child);
        }

        // Reader thread: parse NotchOutbound lines until EOF/child death.
        let shared = Arc::clone(self);
        std::thread::spawn(move || {
            run_reader(shared, stdout, my_gen);
        });

        log::info!("ari-notch: sidecar spawned ({})", bin.display());
        Ok(())
    }

    /// Tear down: stop background loops, ask the sidecar to shut down, kill it.
    fn shutdown(&self) {
        self.stop.store(true, Ordering::SeqCst);
        // Best-effort graceful shutdown request.
        self.send(&NotchInbound::Shutdown);
        if let Ok(mut sink_guard) = self.sink.lock() {
            *sink_guard = None;
        }
        if let Ok(mut child_guard) = self.child.lock() {
            if let Some(mut child) = child_guard.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}

/// Read NDJSON lines from the sidecar's stdout and act on them. Runs on a
/// dedicated std thread; exits on EOF, read error, stop, or generation change.
fn run_reader<R: std::io::Read>(shared: Arc<NotchShared>, stdout: R, my_gen: u64) {
    let reader = BufReader::new(stdout);
    for line in reader.lines() {
        if shared.stop.load(Ordering::SeqCst) {
            break;
        }
        if shared.generation.load(Ordering::SeqCst) != my_gen {
            // A newer child superseded us; stop quietly.
            return;
        }
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<NotchOutbound>(trimmed) {
            Ok(NotchOutbound::Action { action }) => {
                let intent = action_to_intent(&action);
                dispatch_intent(&shared, intent);
            }
            Ok(NotchOutbound::Ready { has_notch }) => {
                log::info!("ari-notch: sidecar ready (has_notch={has_notch})");
            }
            Ok(NotchOutbound::Log { level, message }) => {
                log::info!("ari-notch[{level}]: {message}");
            }
            Ok(NotchOutbound::Unknown) => { /* forward-compat: ignore */ }
            Err(e) => log::debug!("ari-notch: unparseable line ({e}): {trimmed}"),
        }
    }

    // EOF / error: mark disconnected so the supervisor respawns — but only if we
    // are still the current generation (don't clobber a newer sink).
    if shared.generation.load(Ordering::SeqCst) == my_gen {
        if let Ok(mut guard) = shared.sink.lock() {
            *guard = None;
        }
        log::debug!("ari-notch: sidecar stdout closed (gen {my_gen})");
    }
}

/// Turn a resolved intent into actual backend command invocations. This is the
/// thin, untested glue layer. All calls are best-effort and logged.
fn dispatch_intent(shared: &Arc<NotchShared>, intent: NotchIntent) {
    let app = shared.app.clone();
    match intent {
        NotchIntent::StartRecordingForEvent { event_id } => {
            // R5: the notch has no device picker → pass None (last-used/default).
            // The DB link (event ↔ meeting_id) is completed by the normal save
            // flow once the meeting row exists; here we only remember the event so
            // subsequent RecordingState snapshots carry `linked_event_id`.
            if let Ok(mut g) = shared.linked_event_id.lock() {
                *g = Some(event_id.clone());
            }
            // Name the recording after the event (from the WS-D scheduler's title
            // cache) so the calendar time-window auto-matcher links it — the app
            // has no meeting_id at start, it's created only at save time.
            let meeting_name = cached_event_title(&event_id);
            tauri::async_runtime::spawn(async move {
                if let Err(e) =
                    crate::audio::recording_commands::start_recording_with_devices_and_meeting(
                        app, None, None, meeting_name,
                    )
                    .await
                {
                    // Surfaced through the existing error path: the recording
                    // pipeline also emits `recording-error`. The notch protocol has
                    // no inbound error message, so we log here and the next state
                    // snapshot reflects is_recording=false.
                    log::warn!("ari-notch: start recording for event {event_id} failed: {e}");
                }
            });
        }
        NotchIntent::Pause => {
            tauri::async_runtime::spawn(async move {
                if let Err(e) = crate::audio::recording_commands::pause_recording(app).await {
                    log::warn!("ari-notch: pause failed: {e}");
                }
            });
        }
        NotchIntent::Resume => {
            tauri::async_runtime::spawn(async move {
                if let Err(e) = crate::audio::recording_commands::resume_recording(app).await {
                    log::warn!("ari-notch: resume failed: {e}");
                }
            });
        }
        NotchIntent::Stop => {
            if let Ok(mut g) = shared.linked_event_id.lock() {
                *g = None;
            }
            tauri::async_runtime::spawn(async move {
                // The core `stop_recording` ignores its `RecordingArgs` (`_args`);
                // save_path is unused here, so an empty one is fine.
                match crate::audio::recording_commands::stop_recording(
                    app.clone(),
                    crate::audio::recording_commands::RecordingArgs {
                        save_path: String::new(),
                    },
                )
                .await
                {
                    Ok(_) => {
                        // Stopping the native pipeline is only half the job: the
                        // meeting still has to be persisted to SQLite and the UI
                        // advanced past the "Finishing the transcript" overlay.
                        // That post-processing lives in the frontend
                        // (`RecordingPostProcessingProvider` → `handleRecordingStop`)
                        // and fires on this event — the same signal the tray stop
                        // emits (`tray.rs`). Without it a notch-initiated stop
                        // finishes natively but orphans the frontend at 70% and
                        // never saves the meeting.
                        use tauri::Emitter;
                        if let Err(e) = app.emit("recording-stop-complete", true) {
                            log::error!(
                                "ari-notch: failed to emit recording-stop-complete: {e}"
                            );
                        }
                    }
                    Err(e) => log::warn!("ari-notch: stop failed: {e}"),
                }
            });
        }
        NotchIntent::OpenApp { route } => {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
            if let Some(route) = route {
                use tauri::Emitter;
                let _ = app.emit("notch-navigate", route);
            }
        }
    }
}

/// Build a fresh recording-state snapshot from live backend state. Async; holds
/// no lock across `.await`.
async fn build_snapshot(shared: &Arc<NotchShared>) -> NotchInbound {
    let state = crate::audio::recording_commands::get_recording_state().await;
    let meeting_name = crate::audio::recording_commands::get_recording_meeting_name()
        .await
        .ok()
        .flatten();
    let linked = shared
        .linked_event_id
        .lock()
        .ok()
        .and_then(|g| g.clone());
    recording_state_msg(&state, meeting_name, linked)
}

/// The 1 Hz supervisor: respawn on child death and re-push the current recording
/// state (elapsed time is NOT event-pushed, so it must be polled).
fn spawn_supervisor(shared: Arc<NotchShared>) {
    tauri::async_runtime::spawn(async move {
        loop {
            if shared.stop.load(Ordering::SeqCst) {
                break;
            }

            if !shared.is_connected() {
                if let Err(e) = shared.spawn_child() {
                    log::debug!("ari-notch: sidecar unavailable ({e}); will retry");
                }
                // Give the freshly-spawned child a tick before pushing state.
            } else {
                let snapshot = build_snapshot(&shared).await;
                shared.send(&snapshot);
            }

            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        log::debug!("ari-notch: supervisor stopped");
    });
}

/// The ~10 Hz live-meter loop: while a recording is active, sample the lock-free
/// level the audio pipeline publishes (`crate::audio::live_level`) and push it to
/// the sidecar as `AudioLevel`. This is the ONLY live level source during
/// recording — the `audio-levels` Tauri event (see `register_listeners`) is
/// driven by `simple_level_monitor`, which is stopped while recording.
///
/// Gated so we never spam the sidecar when idle: nothing is sent unless the child
/// is connected AND a recording is in progress. While paused we send `0.0` so the
/// meter honestly drops to its floor rather than freezing at the last value.
fn spawn_level_meter(shared: Arc<NotchShared>) {
    tauri::async_runtime::spawn(async move {
        loop {
            if shared.stop.load(Ordering::SeqCst) {
                break;
            }
            if shared.is_connected() && crate::audio::recording_commands::is_recording().await {
                // While paused, send 0.0 so the meter honestly drops to its floor
                // rather than freezing at the last captured value.
                let level = if crate::audio::recording_commands::is_recording_paused().await {
                    0.0
                } else {
                    crate::audio::live_level::current()
                };
                shared.send(&NotchInbound::AudioLevel { level });
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        log::debug!("ari-notch: level meter stopped");
    });
}

// ============================================================================
// Recording-lifecycle event listeners
// ============================================================================

/// Subscribe to the recording lifecycle + audio/transcript streams and translate
/// them into notch messages. Returns the Tauri listener ids for later teardown.
fn register_listeners(shared: &Arc<NotchShared>) -> Vec<u32> {
    let app = shared.app.clone();
    let mut ids = Vec::new();

    // Recording lifecycle → push a fresh state snapshot.
    for event in [
        "recording-started",
        "recording-stopped",
        "recording-paused",
        "recording-resumed",
    ] {
        let shared = Arc::clone(shared);
        let id = app.listen(event, move |_e| {
            let shared = Arc::clone(&shared);
            tauri::async_runtime::spawn(async move {
                let snapshot = build_snapshot(&shared).await;
                shared.send(&snapshot);
            });
        });
        ids.push(id);
    }

    // recording-error: no inbound error message exists in the protocol → log and
    // push a state snapshot (which will reflect is_recording=false).
    {
        let shared = Arc::clone(shared);
        let id = app.listen("recording-error", move |e| {
            log::warn!("ari-notch: recording-error: {}", e.payload());
            let shared = Arc::clone(&shared);
            tauri::async_runtime::spawn(async move {
                let snapshot = build_snapshot(&shared).await;
                shared.send(&snapshot);
            });
        });
        ids.push(id);
    }

    // audio-levels → throttled AudioLevel (≤10 Hz).
    {
        let shared = Arc::clone(shared);
        let id = app.listen("audio-levels", move |e| {
            let level = match audio_level_from_payload(e.payload()) {
                Some(l) => l,
                None => return,
            };
            let (mut throttle_guard, mut sink_guard) =
                match (shared.throttle.lock(), shared.sink.lock()) {
                    (Ok(t), Ok(s)) => (t, s),
                    _ => return,
                };
            if let Some(sink) = sink_guard.as_mut() {
                let _ = forward_audio_level(&mut throttle_guard, sink, Instant::now(), level);
            }
        });
        ids.push(id);
    }

    // transcript-update → TranscriptLine (finals only; speaker unknown until F1).
    {
        let shared = Arc::clone(shared);
        let id = app.listen("transcript-update", move |e| {
            let v: serde_json::Value = match serde_json::from_str(e.payload()) {
                Ok(v) => v,
                Err(_) => return,
            };
            if v.get("is_partial").and_then(|b| b.as_bool()).unwrap_or(false) {
                return; // skip partials to reduce notch churn
            }
            let text = match v.get("text").and_then(|t| t.as_str()) {
                Some(t) if !t.trim().is_empty() => t.to_string(),
                _ => return,
            };
            shared.send(&NotchInbound::TranscriptLine {
                text,
                speaker: None,
            });
        });
        ids.push(id);
    }

    ids
}

// ============================================================================
// Controller: process-global lifecycle behind the commands
// ============================================================================

#[derive(Default)]
struct Controller {
    enabled: bool,
    shared: Option<Arc<NotchShared>>,
    listener_ids: Vec<u32>,
}

static CONTROLLER: LazyLock<Mutex<Controller>> = LazyLock::new(|| Mutex::new(Controller::default()));

// ============================================================================
// WS-D hook: inbound push from the reminder scheduler + upcoming-title cache
// ============================================================================

/// Cache of `event_id -> title` for events the scheduler has surfaced as an
/// upcoming-meeting prompt. Used to NAME a notch-started recording after its
/// event: `dispatch_intent`'s `StartRecordingForEvent` path passes this title as
/// the `meeting_name`, so the saved meeting falls into the calendar auto-matcher's
/// window and links with no extra plumbing (see `calendar/sync.rs`). Small and
/// mutex-guarded; entries are removed on dismissal.
static UPCOMING_TITLES: LazyLock<Mutex<HashMap<String, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Send an inbound message to the live sidecar (no-op if the bridge is disabled
/// or no child is connected). Called by the WS-D scheduler to push
/// `UpcomingMeeting` / `DismissUpcoming`. Also maintains the title cache so a
/// subsequent `StartRecordingForEvent` can name the recording after the event.
pub fn push_inbound(msg: NotchInbound) {
    match &msg {
        NotchInbound::UpcomingMeeting { event_id, title, .. } => {
            if let Ok(mut map) = UPCOMING_TITLES.lock() {
                map.insert(event_id.clone(), title.clone());
            }
        }
        NotchInbound::DismissUpcoming { event_id } => {
            if let Ok(mut map) = UPCOMING_TITLES.lock() {
                map.remove(event_id);
            }
        }
        _ => {}
    }

    if let Ok(ctrl) = CONTROLLER.lock() {
        if let Some(shared) = ctrl.shared.as_ref() {
            shared.send(&msg);
        }
    }
}

/// The cached upcoming-meeting title for `event_id`, if the scheduler surfaced it.
fn cached_event_title(event_id: &str) -> Option<String> {
    UPCOMING_TITLES
        .lock()
        .ok()
        .and_then(|map| map.get(event_id).cloned())
}

/// Enable the notch bridge: spin up the supervisor + listeners. Idempotent.
fn enable(app: AppHandle) {
    let mut ctrl = match CONTROLLER.lock() {
        Ok(c) => c,
        Err(_) => return,
    };
    if ctrl.enabled {
        return;
    }
    let shared = NotchShared::new(app);
    let ids = register_listeners(&shared);
    spawn_supervisor(Arc::clone(&shared));
    spawn_level_meter(Arc::clone(&shared));
    ctrl.listener_ids = ids;
    ctrl.shared = Some(shared);
    ctrl.enabled = true;
    log::info!("ari-notch: bridge enabled");
}

/// Disable the notch bridge: tear down listeners, stop loops, kill the child.
fn disable(app: &AppHandle) {
    let mut ctrl = match CONTROLLER.lock() {
        Ok(c) => c,
        Err(_) => return,
    };
    if !ctrl.enabled {
        return;
    }
    for id in ctrl.listener_ids.drain(..) {
        app.unlisten(id);
    }
    if let Some(shared) = ctrl.shared.take() {
        shared.shutdown();
    }
    ctrl.enabled = false;
    log::info!("ari-notch: bridge disabled");
}

/// Snapshot of the bridge's current status, for `notch_status`.
fn status_value() -> serde_json::Value {
    let (enabled, connected) = match CONTROLLER.lock() {
        Ok(ctrl) => (
            ctrl.enabled,
            ctrl.shared.as_ref().map(|s| s.is_connected()).unwrap_or(false),
        ),
        Err(_) => (false, false),
    };
    serde_json::json!({
        "enabled": enabled,
        "connected": connected,
        "hasBinary": resolve_notch_binary().is_ok(),
    })
}

/// Called once from `lib.rs` `.setup(...)`. Best-effort: reads the persisted
/// `showNotch` preference and enables the bridge if it is truthy. If the setting
/// (or its store) is absent, the bridge stays dormant until `notch_enable`.
///
/// ASSUMPTION (flag for WS-D frontend): the pref is read from the
/// `tauri-plugin-store` file `"settings.json"`, key `"showNotch"`. If WS-D lands
/// a different store name/key, update this reader in lockstep.
pub fn init_at_startup(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let want = read_show_notch_pref(&app);
        if want {
            enable(app);
        } else {
            log::debug!("ari-notch: showNotch not set; bridge dormant until enabled");
        }
    });
}

/// Best-effort read of the persisted `showNotch` flag. Never errors.
fn read_show_notch_pref<R: Runtime>(app: &AppHandle<R>) -> bool {
    use tauri_plugin_store::StoreExt;
    match app.store("settings.json") {
        Ok(store) => store
            .get("showNotch")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        Err(_) => false,
    }
}

// ============================================================================
// Tauri commands
// ============================================================================

/// Enable the notch bridge (idempotent). Gated by the frontend on `showNotch`.
#[tauri::command]
pub async fn notch_enable(app: AppHandle) -> Result<(), String> {
    enable(app);
    Ok(())
}

/// Disable the notch bridge (idempotent).
#[tauri::command]
pub async fn notch_disable(app: AppHandle) -> Result<(), String> {
    disable(&app);
    Ok(())
}

/// Report `{ enabled, connected, hasBinary }`.
#[tauri::command]
pub async fn notch_status() -> Result<serde_json::Value, String> {
    Ok(status_value())
}

// ============================================================================
// Unit tests — pure logic only, no child process / no Tauri runtime
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// Capturing mock sink for tests.
    struct MockSink {
        sent: Vec<NotchInbound>,
    }
    impl NotchSink for MockSink {
        fn send(&mut self, msg: &NotchInbound) -> anyhow::Result<()> {
            self.sent.push(msg.clone());
            Ok(())
        }
    }

    // ---- AudioLevelThrottle ----

    #[test]
    fn throttle_admits_first_then_blocks_within_interval() {
        let mut t = AudioLevelThrottle::new(Duration::from_millis(100));
        let base = Instant::now();
        assert!(t.admit(base), "first admit always passes");
        assert!(!t.admit(base + Duration::from_millis(50)), "too soon");
        assert!(t.admit(base + Duration::from_millis(100)), "at interval passes");
    }

    #[test]
    fn burst_of_100_yields_at_most_10_per_second() {
        // Simulate 100 audio levels evenly spread across exactly 1 second
        // (10 ms apart) and forward them through the throttle into a mock sink.
        let mut throttle = AudioLevelThrottle::new(AUDIO_LEVEL_MIN_INTERVAL);
        let mut sink = MockSink { sent: Vec::new() };
        let base = Instant::now();
        for i in 0..100 {
            let now = base + Duration::from_millis(i * 10);
            forward_audio_level(&mut throttle, &mut sink, now, 0.5).unwrap();
        }
        // First at t=0, then every 100ms up to t=990ms → t=0,100,...,900 = 10.
        assert_eq!(
            sink.sent.len(),
            10,
            "≤10 Hz: expected 10 admitted, got {}",
            sink.sent.len()
        );
        assert!(matches!(sink.sent[0], NotchInbound::AudioLevel { .. }));
    }

    // ---- action_to_intent ----

    #[test]
    fn action_to_intent_maps_every_arm() {
        assert_eq!(
            action_to_intent(&NotchAction::RecordEvent {
                event_id: "EVT-1".into()
            }),
            NotchIntent::StartRecordingForEvent {
                event_id: "EVT-1".into()
            }
        );
        assert_eq!(action_to_intent(&NotchAction::Pause), NotchIntent::Pause);
        assert_eq!(action_to_intent(&NotchAction::Resume), NotchIntent::Resume);
        assert_eq!(action_to_intent(&NotchAction::Stop), NotchIntent::Stop);
        assert_eq!(
            action_to_intent(&NotchAction::OpenApp { route: None }),
            NotchIntent::OpenApp { route: None }
        );
        assert_eq!(
            action_to_intent(&NotchAction::OpenApp {
                route: Some("/settings".into())
            }),
            NotchIntent::OpenApp {
                route: Some("/settings".into())
            }
        );
    }

    // ---- recording_state_msg ----

    #[test]
    fn recording_state_msg_maps_fields() {
        let json = serde_json::json!({
            "is_recording": true,
            "is_paused": false,
            "recording_duration": 130.9,
            "active_duration": 125.4,
            "total_pause_duration": 5.5,
            "current_pause_duration": null
        });
        let msg = recording_state_msg(&json, Some("Weekly Sync".into()), Some("EVT-9".into()));
        match msg {
            NotchInbound::RecordingState {
                is_recording,
                is_paused,
                meeting_name,
                elapsed_seconds,
                linked_event_id,
            } => {
                assert!(is_recording);
                assert!(!is_paused);
                assert_eq!(meeting_name.as_deref(), Some("Weekly Sync"));
                assert_eq!(elapsed_seconds, 125, "uses active_duration, truncated");
                assert_eq!(linked_event_id.as_deref(), Some("EVT-9"));
            }
            other => panic!("expected RecordingState, got {other:?}"),
        }
    }

    #[test]
    fn recording_state_msg_defaults_when_fields_missing() {
        let json = serde_json::json!({ "is_recording": false });
        let msg = recording_state_msg(&json, None, None);
        match msg {
            NotchInbound::RecordingState {
                is_recording,
                is_paused,
                meeting_name,
                elapsed_seconds,
                linked_event_id,
            } => {
                assert!(!is_recording);
                assert!(!is_paused);
                assert_eq!(meeting_name, None);
                assert_eq!(elapsed_seconds, 0);
                assert_eq!(linked_event_id, None);
            }
            other => panic!("expected RecordingState, got {other:?}"),
        }
    }

    #[test]
    fn recording_state_msg_falls_back_to_recording_duration() {
        let json = serde_json::json!({
            "is_recording": true,
            "is_paused": true,
            "recording_duration": 42.7
        });
        let msg = recording_state_msg(&json, None, None);
        if let NotchInbound::RecordingState {
            elapsed_seconds,
            is_paused,
            ..
        } = msg
        {
            assert_eq!(elapsed_seconds, 42);
            assert!(is_paused);
        } else {
            panic!("expected RecordingState");
        }
    }

    // ---- audio_level_from_payload ----

    #[test]
    fn audio_level_takes_max_rms() {
        let payload = r#"{"timestamp":1,"levels":[
            {"device_name":"Mic","device_type":"input","rms_level":0.3,"peak_level":0.5,"is_active":true},
            {"device_name":"Sys","device_type":"output","rms_level":0.72,"peak_level":0.9,"is_active":true}
        ]}"#;
        assert_eq!(audio_level_from_payload(payload), Some(0.72));
    }

    #[test]
    fn audio_level_none_when_empty_or_bad() {
        assert_eq!(audio_level_from_payload("not json"), None);
        assert_eq!(audio_level_from_payload(r#"{"levels":[]}"#), None);
        assert_eq!(audio_level_from_payload(r#"{"foo":1}"#), None);
    }
}
