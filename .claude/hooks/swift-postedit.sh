#!/usr/bin/env bash
#
# PostToolUse hook — format + lint a single edited Swift file.
#
# Wired in .claude/settings.json for Edit|Write|MultiEdit. Reads the hook JSON on stdin,
# pulls the edited file path, and if it's a *.swift file:
#   1. runs `swiftformat` on it in place (auto-fix; config = repo-root .swiftformat)
#   2. runs `swiftlint` on it as a NON-BLOCKING report (config = repo-root .swiftlint.yml)
#
# Degrades gracefully: if swiftformat/swiftlint aren't installed, it prints a one-line
# install hint and exits 0. NEVER blocks the edit (always exits 0) — this is a convenience
# pass, not a gate; the gate is /swift-test + the code reviewer.
#
# Install the tools with:  brew install swiftformat swiftlint

set -uo pipefail

# --- extract the edited file path from the hook payload on stdin -----------------
payload="$(cat)"
file="$(
  printf '%s' "$payload" | /usr/bin/python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
ti = d.get("tool_input", {}) or {}
# Edit/Write use file_path; MultiEdit does too (single file per call in this repo).
print(ti.get("file_path") or ti.get("path") or "")
' 2>/dev/null
)"

# Nothing to do unless it's a real .swift file.
[[ -n "$file" && "$file" == *.swift && -f "$file" ]] || exit 0

# Skip generated / build artifacts.
case "$file" in
  */.build/*|*.generated.swift) exit 0 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
have() { command -v "$1" >/dev/null 2>&1; }

if ! have swiftformat && ! have swiftlint; then
  echo "swift-postedit: swiftformat/swiftlint not installed — skipping (brew install swiftformat swiftlint)"
  exit 0
fi

# --- format in place -------------------------------------------------------------
if have swiftformat; then
  if out="$(swiftformat "$file" --config "$repo_root/.swiftformat" 2>&1)"; then
    :
  else
    echo "swift-postedit: swiftformat reported an issue on $file:"
    echo "$out"
  fi
fi

# --- lint (report only, never blocks) --------------------------------------------
if have swiftlint; then
  # --quiet suppresses the progress banner; we only want warnings/errors for this file.
  lint="$(cd "$repo_root" && swiftlint lint --quiet --config "$repo_root/.swiftlint.yml" -- "$file" 2>/dev/null)"
  if [[ -n "$lint" ]]; then
    echo "swift-postedit: swiftlint findings for $file:"
    echo "$lint"
  fi
fi

exit 0
