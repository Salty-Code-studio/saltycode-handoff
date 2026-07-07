# saltycode-handoff — design spec

_Design date: 2026-07-07_

## Problem

Claude Code re-sends the whole conversation to the model every turn. Cost per
turn scales with context size, so a long session quietly gets expensive. The fix
— write a handoff, `/clear`, resume — is well known but relies on the user
*remembering to do it at the right time* and then *manually re-establishing
context*. This tool removes both frictions.

## Goals

1. **Tell the user when** their context has grown enough that clearing pays off.
2. **Help them capture state** cleanly before clearing.
3. **Restore that state automatically** in the fresh session, so `/clear` is
   cheap to do.
4. Ship as a **portable, free, MIT** package anyone can install; keep personal
   integrations (Obsidian, claude-mem) optional and off by default.

## Non-goals

- Auto-generating handoffs from a hook (a shell script can only dump raw
  transcript; a good handoff needs the model to synthesize it). Handoff creation
  lives in the `/handoff` skill, not a hook.
- Running `/clear` automatically. That stays a human decision.

## Architecture

One skill + three hook wirings, all driven by Claude Code's hook system.

### 1. `context-watch.sh` — the "when"

- **Events:** `Stop` (after every assistant turn) and `PreCompact`/`auto`.
- **Measurement:** parse the transcript JSONL; for each real conversation entry
  (`isSidechain != true`) with a `message.usage`, sum
  `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`; take the
  **last non-zero** value. That equals the live context-window size.
  - Synthetic entries (`ai-title`, interrupted turns) carry an all-zero `usage`
    and are skipped via `select(. > 0)`.
  - Scan is bounded to the last 400 lines with a full-file fallback, so cost stays
    flat even on multi-MB transcripts.
- **Tiers (tokens):** gentle `HANDOFF_GENTLE` / recommend `HANDOFF_RECOMMEND` /
  urgent `HANDOFF_URGENT`.
- **De-dup:** per-session state file records the highest tier warned. Nudge only
  fires when the tier *increases*. When context drops below the gentle threshold
  (e.g. after a compaction) the state resets to 0, so a regrowth re-warns.
- **PreCompact/auto:** emits a distinct "last call" `systemMessage`, independent
  of tier state.
- **Output:** `{"systemMessage": "..."}`. Fails silent on any error.

### 2. `session-resume.sh` — the auto-resume

- **Event:** `SessionStart` (receives `source` ∈ `startup|resume|clear|compact`
  and `cwd`).
- **Auto-load:** only when `source == "clear"` **and** `./HANDOFF.md` mtime is
  within `HANDOFF_RESUME_MAXAGE` (default 1h). Injects the file as
  `additionalContext`, built with `jq` for correct escaping.
  - **Version dedupe:** a per-cwd marker records the last-loaded mtime; the same
    handoff never full-loads twice (a second `/clear` falls through to the note).
- **Cold-start note:** any other start (and a non-ancient file, within
  `HANDOFF_NOTE_MAXAGE`) injects a one-line "resume?" pointer instead of the full
  document — non-intrusive, user stays in control.
- **Kill switch:** `HANDOFF_AUTORESUME=0` disables the whole hook.

### 3. `/handoff` skill — the "how"

Instructs Claude to synthesize a lean, structured `HANDOFF.md` (goal, current
state with ✅/🔧 markers, ordered next steps, key files + line refs, decisions +
rationale, gotchas, paste-ready resume prompt). Then, if
`~/.claude/skills/handoff/handoff.config.json` enables them, archive a timestamped
copy to `<vault>/Claude Chats/Handoffs/` and/or a claude-mem observation. Never
runs `/clear`.

## Install & portability

`install.sh` resolves `$HOME`/`$CLAUDE_CONFIG_DIR` at install time and writes
absolute hook paths into `settings.json` via a `jq` merge that:

- backs up `settings.json` first,
- is **idempotent** (strips any prior entry pointing at our script before adding),
- is **non-clobbering** (preserves all other keys and hooks),
- validates the result is valid JSON before replacing the file.

`uninstall.sh` reverses the merge and removes only our entries, dropping now-empty
hook arrays.

## Verification

- Token extraction validated against two real multi-MB transcripts (167,682 and
  79,311 tokens; bounded and full scans agree).
- Confirmed all-zero synthetic `usage` rows are excluded.
- `settings.json` merge tested on a copy before live install; output validated
  with `jq -e`.
- Each hook exercised with representative stdin JSON for its event.

## Field reference (verified against Claude Code docs + live transcripts)

- Transcript usage fields: `input_tokens`, `output_tokens`,
  `cache_read_input_tokens`, `cache_creation_input_tokens`.
- `SessionStart.source` values: `startup`, `resume`, `clear`, `compact`.
- Context injection: `hookSpecificOutput.hookEventName` +
  `hookSpecificOutput.additionalContext` (case-sensitive).
- User-facing message: top-level `systemMessage`.
- `PreCompact` matcher: `manual` | `auto`.
