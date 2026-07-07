#!/usr/bin/env bash
# saltycode-handoff installer
# Copies the /handoff skill + hooks into ~/.claude and wires the hooks into
# settings.json (backed up first, merged with jq, never clobbering your config).
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILL_DIR="$CLAUDE_DIR/skills/handoff"
HOOK_DIR="$CLAUDE_DIR/hooks/saltycode-handoff"
SETTINGS="$CLAUDE_DIR/settings.json"
REPO="$(cd "$(dirname "$0")" && pwd)"

echo "saltycode-handoff installer"
echo "  Claude dir: $CLAUDE_DIR"

# 0. dependency
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install it first (macOS: brew install jq)." >&2
  exit 1
fi

# 1. skill
mkdir -p "$SKILL_DIR"
cp "$REPO/skills/handoff/SKILL.md" "$SKILL_DIR/SKILL.md"
if [ ! -f "$SKILL_DIR/handoff.config.json" ]; then
  cp "$REPO/skills/handoff/handoff.config.json" "$SKILL_DIR/handoff.config.json"
  echo "  ✓ skill      -> $SKILL_DIR (config seeded)"
else
  echo "  ✓ skill      -> $SKILL_DIR (kept your existing handoff.config.json)"
fi

# 2. hooks
mkdir -p "$HOOK_DIR"
cp "$REPO/hooks/context-watch.sh"  "$HOOK_DIR/context-watch.sh"
cp "$REPO/hooks/session-resume.sh" "$HOOK_DIR/session-resume.sh"
chmod +x "$HOOK_DIR"/*.sh
echo "  ✓ hooks      -> $HOOK_DIR"

# 3. settings.json (backup + jq merge, idempotent, non-clobbering)
CW="$HOOK_DIR/context-watch.sh"
SR="$HOOK_DIR/session-resume.sh"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

tmp="$(mktemp)"
jq --arg cw "$CW" --arg sr "$SR" '
  .hooks = (.hooks // {})
  | .hooks.Stop         = (((.hooks.Stop         // []) | map(select(any(.hooks[]?; .command == $cw) | not))) + [ {hooks:[{type:"command", command:$cw, timeout:10}]} ])
  | .hooks.PreCompact   = (((.hooks.PreCompact   // []) | map(select(any(.hooks[]?; .command == $cw) | not))) + [ {matcher:"auto", hooks:[{type:"command", command:$cw, timeout:10}]} ])
  | .hooks.SessionStart = (((.hooks.SessionStart // []) | map(select(any(.hooks[]?; .command == $sr) | not))) + [ {hooks:[{type:"command", command:$sr, timeout:10}]} ])
' "$SETTINGS" > "$tmp"

if jq -e . "$tmp" >/dev/null 2>&1; then
  mv "$tmp" "$SETTINGS"
  echo "  ✓ settings   -> hooks wired into $SETTINGS (backup saved)"
else
  rm -f "$tmp"
  echo "ERROR: merge produced invalid JSON; settings.json left unchanged." >&2
  exit 1
fi

echo ""
echo "Done. Start a new session (or /clear) for the hooks to load."
echo "Tune anytime with env vars (see README): HANDOFF_GENTLE, HANDOFF_AUTORESUME, ..."
