#!/usr/bin/env bash
#
# dev-signed.sh — run the app in dev with a STABLE, entitled code identity so
# macOS TCC will present (and remember) calendar / other privacy prompts.
#
# Why this exists:
#   `pnpm run tauri:dev` launches a bare, ad-hoc/linker-signed binary that has
#   NO CFBundleIdentifier and no entitlements. macOS TCC attributes calendar
#   access to an app by bundle identifier, so EventKit's full-access request
#   silently refuses to show its dialog (returns granted=false, status stays
#   "notDetermined"). A built .app works, but rebuilding a bundle every edit is
#   slow. This script instead builds the normal dev binary, then re-signs it
#   with `--identifier com.meetily.ai` + the project entitlements so TCC has an
#   identity to prompt against — while still loading the live Next dev server
#   (HMR intact for frontend edits).
#
# Usage:
#   Stop `pnpm run tauri:dev` first (this replaces it — the single-instance
#   plugin won't allow two copies). Then from `frontend/`:
#       pnpm run tauri:dev:signed
#   Re-run it after any RUST change (a rebuild re-signs ad-hoc and wipes ours).
#   Frontend edits hot-reload and do NOT require a re-run.
#
set -euo pipefail

FRONTEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$FRONTEND_DIR/.." && pwd)"
BIN="$ROOT_DIR/target/debug/ari-meeting"
ENTITLEMENTS="$FRONTEND_DIR/src-tauri/entitlements.plist"
IDENTIFIER="com.meetily.ai"   # must match tauri.conf.json > identifier
DEV_PORT=3118

echo "📅 dev-signed: building + re-signing the dev binary with a stable identity"

# 1. Ensure the Next dev server is serving the frontend on :3118.
if ! lsof -iTCP:"$DEV_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "🌐 starting Next dev server on :$DEV_PORT ..."
  ( cd "$FRONTEND_DIR" && pnpm dev >/tmp/ari-next-dev.log 2>&1 & )
  for _ in $(seq 1 60); do
    lsof -iTCP:"$DEV_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 1
  done
  echo "🌐 Next dev server is up (logs: /tmp/ari-next-dev.log)"
else
  echo "🌐 Next dev server already running on :$DEV_PORT"
fi

# 2. Build the dev binary (Apple Silicon uses coreml, same as tauri-auto).
#    No `custom-protocol` feature => the binary loads the dev URL, not bundled assets.
echo "🦀 cargo build (this reuses the tauri:dev build cache)"
( cd "$FRONTEND_DIR/src-tauri" && cargo build --features coreml )

# 3. Re-sign with a stable bundle identifier + entitlements so TCC can attribute
#    calendar access. Ad-hoc ("-") is fine for a non-sandboxed local app.
echo "🔏 codesign --identifier $IDENTIFIER"
codesign --force --sign - --identifier "$IDENTIFIER" --entitlements "$ENTITLEMENTS" "$BIN"

# 4. Launch. This is the sole instance (stop `pnpm run tauri:dev` beforehand).
echo "🚀 launching $BIN"
exec "$BIN"
