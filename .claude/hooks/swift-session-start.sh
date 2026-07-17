#!/usr/bin/env bash
#
# SessionStart hook — report Swift toolchain + tooling + simulator state.
#
# Wired in .claude/settings.json. Prints a short status block to stdout, which Claude Code
# folds into session context. Purely informational — always exits 0, never blocks.
#
# Answers, at a glance: what Swift do we have, are the lint/format tools installed, is
# XcodeBuildMCP's npx runner reachable, and is any simulator booted (for the iOS Ari Lite
# target). Keep it terse — this runs every session.

set -uo pipefail
have() { command -v "$1" >/dev/null 2>&1; }

echo "── Swift tooling ─────────────────────────────"

# Toolchain
if have swift; then
  echo "swift:       $(swift --version 2>/dev/null | head -1)"
else
  echo "swift:       NOT FOUND"
fi
if have xcodebuild; then
  echo "xcode:       $(xcodebuild -version 2>/dev/null | tr '\n' ' ')  (active: $(xcode-select -p 2>/dev/null))"
else
  echo "xcode:       NOT FOUND (full Xcode required — see build-and-run.md)"
fi

# Lint / format (drive the PostToolUse hook)
fmt="missing"; lnt="missing"
have swiftformat && fmt="$(swiftformat --version 2>/dev/null)"
have swiftlint  && lnt="$(swiftlint version 2>/dev/null)"
echo "swiftformat: $fmt"
echo "swiftlint:   $lnt"
if [[ "$fmt" == "missing" || "$lnt" == "missing" ]]; then
  echo "             → brew install swiftformat swiftlint  (PostToolUse hook no-ops until then)"
fi

# XcodeBuildMCP is launched via npx; just confirm the runner exists.
if have npx; then
  echo "XcodeBuildMCP: npx present (server auto-installs on first MCP call)"
else
  echo "XcodeBuildMCP: npx NOT FOUND — install Node to enable the MCP server"
fi

# Booted simulators (iOS Ari Lite target). Cheap query; tolerate absence.
if have xcrun; then
  booted="$(xcrun simctl list devices booted 2>/dev/null | grep -E 'Booted' | sed 's/^[[:space:]]*//' || true)"
  if [[ -n "$booted" ]]; then
    echo "simulators booted:"
    echo "$booted" | sed 's/^/  /'
  else
    echo "simulators:  none booted"
  fi
fi

echo "──────────────────────────────────────────────"
exit 0
