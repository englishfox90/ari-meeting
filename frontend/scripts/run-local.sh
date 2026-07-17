#!/usr/bin/env bash
#
# run-local.sh — ONE command to build + launch the signed desktop app for local testing.
#
# Why a signed bundle (not `tauri dev`): macOS TCC ties privacy grants (Calendar,
# Microphone, Screen Recording) to the app's code identity. A bare `tauri dev` binary
# has no LaunchServices identity, so it can NEVER get a Calendar grant, and its ad-hoc
# signature changes every rebuild so mic/screen grants keep resetting. Building a real
# `.app` signed with the stable "Ari Dev Signing" identity fixes all of that: grant each
# permission ONCE and it sticks across rebuilds.
#
# Usage (from frontend/):  pnpm run app:local
# Override the identity:   APPLE_SIGNING_IDENTITY="My Cert" pnpm run app:local
#
set -euo pipefail

FRONTEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$FRONTEND_DIR/.." && pwd)"
SIGN_ID="${APPLE_SIGNING_IDENTITY:-Ari Dev Signing}"
APP="$ROOT_DIR/target/debug/bundle/macos/Ari Meeting.app"
SIDECAR="$FRONTEND_DIR/src-tauri/binaries/llama-helper-aarch64-apple-darwin"
NOTCH_SIDECAR="$FRONTEND_DIR/src-tauri/binaries/ari-notch-aarch64-apple-darwin"
NOTCH_PKG="$ROOT_DIR/ari-notch"
APPLE_SIDECAR="$FRONTEND_DIR/src-tauri/binaries/apple-helper-aarch64-apple-darwin"
APPLE_PKG="$ROOT_DIR/apple-helper"
DIARIZE_SIDECAR="$FRONTEND_DIR/src-tauri/binaries/diarize-helper-aarch64-apple-darwin"
DIARIZE_PKG="$ROOT_DIR/diarize-helper"

echo "▶  Ari local test build — signing identity: \"$SIGN_ID\""

# 0. The self-signed code-signing cert must exist (create once in Keychain Access).
if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "⚠️  Code-signing identity \"$SIGN_ID\" is not in your keychain."
  echo "    Create it once: Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…"
  echo "    Name = \"$SIGN_ID\",  Identity Type = Self Signed Root,  Certificate Type = Code Signing."
  exit 1
fi

# Rebuild + stage a SwiftPM sidecar when the staged binary is MISSING or any of
# its sources (Sources/ or Package.swift) is NEWER than the staged copy. Without
# the freshness check the sidecar was staged only once (first run), so edits to
# the Swift source silently never reached the app until you `rm` the binary.
# Args: <pkg_dir> <product_name> <staged_path>
stage_swift_sidecar() {
  local pkg="$1" product="$2" staged="$3"
  if [ ! -f "$staged" ] || \
     [ -n "$(find "$pkg/Sources" "$pkg/Package.swift" -type f -newer "$staged" -print -quit 2>/dev/null)" ]; then
    echo "🔧 Building $product sidecar (source changed or first run)…"
    ( cd "$pkg" && swift build -c release --arch arm64 )
    local bin
    bin="$(cd "$pkg" && swift build -c release --arch arm64 --show-bin-path)/$product"
    mkdir -p "$FRONTEND_DIR/src-tauri/binaries"
    cp "$bin" "$staged"
  fi
}

# 1. Stage the llama-helper sidecar — `tauri build` fails if externalBin is missing.
#    (ffmpeg is auto-downloaded by build.rs; only llama-helper is built by hand.)
if [ ! -f "$SIDECAR" ]; then
  echo "🔧 Building llama-helper sidecar (first run only)…"
  ( cd "$ROOT_DIR" && cargo build --release -p llama-helper --features metal )
  mkdir -p "$FRONTEND_DIR/src-tauri/binaries"
  cp "$ROOT_DIR/target/release/llama-helper" "$SIDECAR"
fi

# 1b. Stage the ari-notch sidecar (the Swift/SwiftUI notch panel). Built with
#     SwiftPM, forced to arm64 to match the aarch64-apple-darwin triple suffix.
#     Re-staged whenever its Swift source changes (see stage_swift_sidecar).
stage_swift_sidecar "$NOTCH_PKG" "ari-notch" "$NOTCH_SIDECAR"

# 1c. Stage the apple-helper sidecar (the Swift on-device Speech/FoundationModels
#     helper). Same rule; re-staged whenever its Swift source changes.
stage_swift_sidecar "$APPLE_PKG" "apple-helper" "$APPLE_SIDECAR"

# 1d. Stage the diarize-helper sidecar (speaker re-ID / diarization). Same rule:
#     `tauri build` fails if this externalBin is missing. Unlike llama-helper,
#     diarize-helper is its OWN cargo workspace at the repo root (sibling of
#     frontend, NOT a workspace member), so it's built from its own dir with a
#     plain `cargo build --release` — no `-p`, and its target/ is local to it.
if [ ! -f "$DIARIZE_SIDECAR" ]; then
  echo "🔧 Building diarize-helper sidecar (first run only)…"
  ( cd "$DIARIZE_PKG" && cargo build --release )
  mkdir -p "$FRONTEND_DIR/src-tauri/binaries"
  cp "$DIARIZE_PKG/target/release/diarize-helper" "$DIARIZE_SIDECAR"
fi

# 2. Build the signed debug .app. `--bundles app` skips the flaky DMG step.
echo "🏗  Building signed .app (this recompiles changed Rust + the frontend)…"
( cd "$FRONTEND_DIR" && APPLE_SIGNING_IDENTITY="$SIGN_ID" pnpm tauri build --debug --bundles app )

# 3. Replace any running copy and launch via LaunchServices (needed for TCC identity).
echo "🚀 Launching Ari Meeting…"
pkill -f "Ari Meeting.app" >/dev/null 2>&1 || true
sleep 1
open "$APP"

cat <<'EOF'
✅ App launched.

First launch only — grant these in the prompts (or System Settings ▸ Privacy & Security):
  • Calendar
  • Microphone
  • Screen Recording / Audio Capture   (macOS may ask you to reopen the app after this one)

Because the build is signed with a stable identity, you WON'T be re-prompted on future
runs. Re-run `pnpm run app:local` after any change to rebuild + relaunch.
EOF
