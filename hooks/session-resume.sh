#!/usr/bin/env bash
# saltycode-handoff :: session-resume
# https://github.com/Salty-Code-studio/saltycode-handoff
#
# Runs on: SessionStart.
# If a HANDOFF.md exists in the working directory:
#   - right after /clear, with a fresh file  -> auto-load it into context
#   - on a cold startup (or an older file)    -> inject a one-line "resume?" note
#
# Tuning (env vars, all optional):
#   HANDOFF_AUTORESUME      set to 0 to disable auto-loading entirely   (default 1)
#   HANDOFF_RESUME_MAXAGE   "fresh" window in seconds for auto-load     (default 3600)
#   HANDOFF_NOTE_MAXAGE     stay silent if file older than this (sec)   (default 604800 = 7d)
#   HANDOFF_STATE_DIR       dedupe marker location                      (default $TMPDIR/saltycode-handoff)

[ "${HANDOFF_AUTORESUME:-1}" = "0" ] && exit 0

MAXAGE="${HANDOFF_RESUME_MAXAGE:-3600}"
NOTE_MAXAGE="${HANDOFF_NOTE_MAXAGE:-604800}"
STATE_DIR="${HANDOFF_STATE_DIR:-${TMPDIR:-/tmp}/saltycode-handoff}"

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
source="$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

file="$cwd/HANDOFF.md"
[ -f "$file" ] || exit 0

now="$(date +%s)"
mtime="$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo "$now")"
age=$(( now - mtime ))
[ "$age" -lt 0 ] && age=0

inject() { jq -n --arg c "$1" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'; }

rel() {
  if   [ "$1" -lt 3600 ];  then echo "$(( $1 / 60 ))m ago"
  elif [ "$1" -lt 86400 ]; then echo "$(( $1 / 3600 ))h ago"
  else echo "$(( $1 / 86400 ))d ago"; fi
}

# --- auto-load: only right after /clear, only if fresh, only once per file version ---
if [ "$source" = "clear" ] && [ "$age" -le "$MAXAGE" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null
  key="$(printf '%s' "$cwd" | tr -c 'A-Za-z0-9' '_')"
  marker="$STATE_DIR/resume_${key}.mtime"
  last="$(cat "$marker" 2>/dev/null || echo 0)"
  if [ "$mtime" != "$last" ]; then
    echo "$mtime" > "$marker" 2>/dev/null
    body="$(cat "$file")"
    inject "You are resuming work after a context reset (/clear). Below is HANDOFF.md, written moments ago in ${cwd}. Treat it as the source of truth for where things stand, confirm the next step with the user, then continue.

---
${body}"
    exit 0
  fi
fi

# --- otherwise: a lightweight note, unless the file is ancient ---
[ "$age" -le "$NOTE_MAXAGE" ] || exit 0
inject "📋 saltycode-handoff — a HANDOFF.md (updated $(rel "$age")) is present in ${cwd}. Say \"resume the handoff\" to pick up where you left off."
exit 0
