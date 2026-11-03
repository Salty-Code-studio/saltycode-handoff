#!/usr/bin/env bash
# saltycode-handoff uninstaller
# Removes the hooks from settings.json (backup first) and deletes the installed
# skill + hook scripts. Your settings.json backups are kept.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILL_DIR="$CLAUDE_DIR/skills/handoff"
HOOK_DIR="$CLAUDE_DIR/hooks/saltycode-handoff"
SETTINGS="$CLAUDE_DIR/settings.json"
CW="$HOOK_DIR/context-watch.sh"
SR="$HOOK_DIR/session-resume.sh"
AH="python3 -I $HOOK_DIR/auto-handoff.py"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  tmp="$(mktemp)"
  jq --arg cw "$CW" --arg sr "$SR" --arg ah "$AH" '
    if .hooks then
        .hooks.Stop         = ((.hooks.Stop         // []) | map(select(any(.hooks[]?; .command == $cw) | not)))
      | .hooks.PreCompact   = ((.hooks.PreCompact   // []) | map(select(any(.hooks[]?; .command == $cw) | not)))
      | .hooks.SessionStart = ((.hooks.SessionStart // []) | map(select(any(.hooks[]?; .command == $sr) | not)))
      | .hooks.SessionEnd   = ((.hooks.SessionEnd   // []) | map(select(any(.hooks[]?; .command == $ah) | not)))
      | (if (.hooks.Stop         | length) == 0 then del(.hooks.Stop)         else . end)
      | (if (.hooks.PreCompact   | length) == 0 then del(.hooks.PreCompact)   else . end)
      | (if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end)
      | (if (.hooks.SessionEnd   | length) == 0 then del(.hooks.SessionEnd)   else . end)
      | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end
  ' "$SETTINGS" > "$tmp"
  if jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$SETTINGS"
    echo "  ✓ unwired hooks from settings.json (backup saved)"
  else
    rm -f "$tmp"
    echo "  ! merge error; settings.json left unchanged" >&2
  fi
fi

rm -rf "$HOOK_DIR"
rm -rf "$SKILL_DIR"
echo "  ✓ removed skill + hook scripts"
echo "Done. Restart your session to drop the hooks."
