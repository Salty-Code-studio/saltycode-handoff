---
name: handoff
description: Use before running /clear, or when the context window is getting large, to capture the full working state into HANDOFF.md so a fresh session can resume with minimal tokens. Writes goal, current state, next steps, key files, decisions, gotchas, and a paste-ready resume prompt. Optionally archives to an Obsidian vault and to claude-mem.
---

# Handoff

Capture everything needed to continue this work in a fresh session, then let the
user `/clear` to save tokens. A companion `SessionStart` hook auto-loads the
resulting `HANDOFF.md` right after `/clear`, so the next session wakes up already
knowing where things stand.

## When to use
- The `context-watch` hook nudged the user (context is large), **or**
- The user asks for a handoff / says they're about to `/clear`, **or**
- You're wrapping a work session that will be continued later.

## Steps

0. **Auto mode exists.** A `SessionEnd` hook (`auto-handoff.py`) already writes
   a handoff automatically on every `/clear`, into the project the session
   worked on. Run this skill manually only when the user wants to review the
   handoff before clearing. A manual handoff written <15 min before `/clear`
   is kept; the auto one is skipped.

1. **Locate the target file.** Write `HANDOFF.md` into the **project root the
   session actually worked on** (git root of the files edited), not the shell
   cwd, which is often `~`. Fall back to the cwd only if no project was touched. The auto-resume hook reads exactly `HANDOFF.md`, so the canonical
   file must keep that name. If a `HANDOFF.md` already exists for *different*
   work, ask whether to overwrite it or save a timestamped copy
   (`HANDOFF-YYYY-MM-DD-HHMM.md`) alongside a refreshed `HANDOFF.md`.

2. **Synthesize the handoff from the actual conversation** — do NOT dump the
   transcript. Be concrete and skimmable. Fill this template:

   ```markdown
   # HANDOFF — <short task/project title>
   _<ISO datetime> · <cwd>_

   ## Goal
   <1–3 sentences: what we're ultimately trying to achieve.>

   ## Current state
   - <what's done — mark ✅ verified vs 🔧 done-but-unverified>
   - <what works / is deployed / is running right now>

   ## Next steps
   1. <concrete, ordered next action>
   2. <...>

   ## Key files
   - `path/to/file` — <what it is, relevant line refs like :42-60>

   ## Decisions & why
   - <decision> — <rationale, so the next session doesn't relitigate it>

   ## Gotchas / watch-outs
   - <traps, flaky things, things that look wrong but aren't>

   ## Resume prompt
   > <A paste-ready instruction the user can drop into the fresh session, e.g.
   > "Continue the saltycode-handoff build. HANDOFF.md has the state. Next: run
   > install.sh and test the hooks against a real transcript.">
   ```

3. **Keep it lean.** Signal over completeness — the whole point is to save
   tokens. Reference files and line numbers instead of pasting large code blocks.

4. **Archive to optional sinks — only if configured for this machine.**
   Read `~/.claude/skills/handoff/handoff.config.json`:
   - If `obsidian_vault` is a non-empty path, ALSO write a timestamped copy to
     `<obsidian_vault>/Claude Chats/Handoffs/YYYY-MM-DD-<slug>.md` with
     frontmatter (`title`, `date`, `tags: [handoff, claude-code]`, `project`,
     and `session_id` if known) plus a wikilink to any related note, so
     Obsidian's graph picks it up. Never overwrite an existing dated note —
     append `-2`, `-3`, … if the name collides.
   - If `claude_mem` is `true` and the claude-mem tools are available, record a
     concise high-signal observation (title = the task; body = goal + current
     state + next steps) so it's searchable across sessions. Note: claude-mem's
     manual-write tools (`observation_add`/`memory_add`) require its `server-beta`
     runtime. In `worker` mode they return an error and claude-mem already
     auto-captures the session, so skip the manual write and just tell the user
     it's covered by auto-capture.

5. **Close out.** Tell the user exactly what happened, e.g.:
   > "Handoff written to `./HANDOFF.md` (and archived to the vault + claude-mem).
   > Review it, then run `/clear` — the next session will auto-load it. Or paste
   > the resume prompt manually."

## Notes
- The `HANDOFF.md` filename is load-bearing. After `/clear`, the SessionStart
  hook points the new session at the project file the auto-handoff is writing.
- Auto-handoff tuning: `HANDOFF_AUTOGEN=0` disables it,
  `HANDOFF_AUTOGEN_REASONS=clear,prompt_input_exit` also runs it on exit,
  `HANDOFF_AUTOGEN_MODEL` (default sonnet), log at
  `~/.claude/hooks/saltycode-handoff/auto-handoff.log`.
- This skill only writes files and (optionally) calls archive tools. It never
  runs `/clear` — that stays the user's decision.
