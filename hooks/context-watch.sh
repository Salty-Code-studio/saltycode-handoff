#!/usr/bin/env bash
# saltycode-handoff :: context-watch
# https://github.com/Salty-Code-studio/saltycode-handoff
#
# Runs on:  Stop (after every turn)  and  PreCompact/auto (last call).
# Reads the hook JSON on stdin, computes the CURRENT context-window size from
# the session transcript, and shows a tiered nudge to run /handoff + /clear.
#
# Tuning (env vars, all optional):
#   HANDOFF_GENTLE      first nudge threshold in tokens    (default 150000)
#   HANDOFF_RECOMMEND   recommend-handoff threshold        (default 250000)
#   HANDOFF_URGENT      urgent threshold                   (default 400000)
#   HANDOFF_STATE_DIR   per-session tier state dir         (default $TMPDIR/saltycode-handoff)
#
# Fails silent by design: any error just skips the nudge, never blocks you.

GENTLE="${HANDOFF_GENTLE:-150000}"
RECOMMEND="${HANDOFF_RECOMMEND:-250000}"
URGENT="${HANDOFF_URGENT:-400000}"
STATE_DIR="${HANDOFF_STATE_DIR:-${TMPDIR:-/tmp}/saltycode-handoff}"

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

get() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }
event="$(get '.hook_event_name // empty')"
trigger="$(get '.trigger // empty')"
session="$(get '.session_id // "nosession"')"
transcript="$(get '.transcript_path // empty')"

emit() { jq -n --arg m "$1" '{systemMessage:$m}'; }

# --- PreCompact: fire the last-call once, independent of tiers ---
# Our settings matcher already scopes this to "auto"; guard against manual just
# in case the hook is wired without a matcher, and still fire if trigger is absent.
if [ "$event" = "PreCompact" ]; then
  [ "$trigger" != "manual" ] && emit "🚨 saltycode-handoff — auto-compaction is starting: your context hit the limit and Claude is about to summarize (and drop detail). Next time, run /handoff + /clear a bit earlier to stay in control."
  exit 0
fi

# --- Stop: measure current context from the transcript ---
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Sum input + cache_read + cache_creation on real conversation turns only.
# Skip sidechain/subagent entries and synthetic all-zero-usage rows (ai-title, etc.);
# take the LAST non-zero value = the current live context size.
extract() {
  jq -rR 'fromjson?
    | select(.isSidechain != true)
    | (.message.usage? // empty)
    | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
    | select(. > 0)'
}
tokens="$(tail -n 400 "$transcript" 2>/dev/null | extract | tail -n 1)"   # bounded, fast
[ -n "$tokens" ] || tokens="$(extract < "$transcript" 2>/dev/null | tail -n 1)"  # full fallback

case "$tokens" in ''|*[!0-9]*) exit 0 ;; esac   # not a clean integer -> bail quietly

tier=0
if   [ "$tokens" -ge "$URGENT" ];    then tier=3
elif [ "$tokens" -ge "$RECOMMEND" ]; then tier=2
elif [ "$tokens" -ge "$GENTLE" ];    then tier=1
fi

mkdir -p "$STATE_DIR" 2>/dev/null
state="$STATE_DIR/${session}.tier"

# below first threshold: reset state (so a post-compaction regrowth re-warns) and leave
if [ "$tier" -eq 0 ]; then
  echo 0 > "$state" 2>/dev/null
  exit 0
fi

prev="$(cat "$state" 2>/dev/null || echo 0)"
case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
echo "$tier" > "$state" 2>/dev/null

# only nudge when escalating into a higher tier (once per tier per session)
[ "$tier" -gt "$prev" ] || exit 0

k=$((tokens / 1000))
case "$tier" in
  1) emit "💡 saltycode-handoff — context is ~${k}k tokens and growing. At a natural stopping point, run /handoff then /clear to reset and save tokens." ;;
  2) emit "⚠️ saltycode-handoff — context ~${k}k tokens. Recommended: run /handoff now to capture state, then /clear. Every turn re-sends this whole conversation." ;;
  3) emit "🚨 saltycode-handoff — context ~${k}k tokens (large). Run /handoff + /clear soon — you're paying to re-send the entire conversation each turn." ;;
esac
exit 0
