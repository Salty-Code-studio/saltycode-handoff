# saltycode-handoff

**Know exactly when to hand off and `/clear` your Claude Code session — and pick up right where you left off.**

A long Claude Code conversation re-sends its *entire* context to the model on
every turn. The bigger it gets, the more each message costs. `saltycode-handoff`
watches your live context size, nudges you at the right moment, helps you write a
clean `HANDOFF.md`, and then **auto-loads that handoff into the fresh session
after you `/clear`** — so resetting costs you nothing but saves you tokens.

```
context grows ──▶ hook nudges you ──▶ /clear
                                            │
              SessionEnd hook writes HANDOFF.md into your project
                                            │
                        new session points at it, say "resume"
                                            │
                        new session resumes, tiny context, full memory
```

One skill + four hooks. Needs [`jq`](https://jqlang.github.io/jq/) and `python3`.

You don't even have to run `/handoff`. Just type `/clear` and the handoff writes itself.

---

## What you get

| Piece | Fires on | What it does |
|---|---|---|
| **`context-watch.sh`** | `Stop` (every turn) | Nudges you at **150k / 250k / 400k** tokens. De-duped: once per tier per session, not every turn. |
| **`context-watch.sh`** | `PreCompact` / `auto` | Last-call alert right before auto-compaction kicks in. |
| **`session-resume.sh`** | `SessionStart` | After `/clear` with a fresh `HANDOFF.md` → auto-loads it. Cold start → one-line "resume?" note. |
| **`auto-handoff.py`** | `SessionEnd` on `/clear` | Finds the project you actually worked on (git root of the files you edited, not the folder you launched from), then a headless `claude -p` writes `HANDOFF.md` there in the background. `/clear` never waits. Keeps it out of git via `.git/info/exclude`. |
| **`/handoff` skill** | you invoke it | Claude synthesizes a structured `HANDOFF.md` (state, next steps, key files, decisions, resume prompt). Optional: archive to Obsidian + claude-mem. |

The nudge measures your true context size by summing `input + cache_read +
cache_creation` tokens from the latest real turn in the transcript — the same
number that fills your context window.

---

## Install

```bash
git clone https://github.com/Salty-Code-studio/saltycode-handoff.git
cd saltycode-handoff
./install.sh
```

The installer copies the skill to `~/.claude/skills/handoff/`, the hooks to
`~/.claude/hooks/saltycode-handoff/`, and merges the hook wiring into
`~/.claude/settings.json` (backed up first, never clobbered). Start a new session
or `/clear` for the hooks to load.

**Uninstall:** `./uninstall.sh` (reverses the settings merge, keeps backups).

---

## Configure

### Hook thresholds & behavior — environment variables

Set these in your shell profile (`~/.zshrc`, `~/.bashrc`) to override the
defaults; every one is optional.

| Variable | Default | Meaning |
|---|---|---|
| `HANDOFF_GENTLE` | `150000` | 💡 first, gentle nudge (tokens) |
| `HANDOFF_RECOMMEND` | `250000` | ⚠️ recommend running `/handoff` |
| `HANDOFF_URGENT` | `400000` | 🚨 urgent |
| `HANDOFF_AUTORESUME` | `1` | set `0` to disable auto-loading after `/clear` |
| `HANDOFF_RESUME_MAXAGE` | `3600` | how fresh (seconds) `HANDOFF.md` must be to auto-load |
| `HANDOFF_NOTE_MAXAGE` | `604800` | older than this (7d) → stay silent on cold start |
| `HANDOFF_AUTOGEN` | `1` | set `0` to turn off auto-handoff on `/clear` |
| `HANDOFF_AUTOGEN_MODEL` | `sonnet` | model that writes the auto-handoff (`haiku` is cheaper) |
| `HANDOFF_AUTOGEN_MIN_PROMPTS` | `2` | skip sessions shorter than this |
| `HANDOFF_AUTOGEN_REASONS` | `clear` | SessionEnd reasons that trigger it, e.g. `clear,prompt_input_exit` to also run on exit |

Auto-handoff skips a project if you wrote a `/handoff` there in the last 15
minutes, so a reviewed manual handoff always wins. It takes about a minute and
uses one headless Claude call. Log: `~/.claude/hooks/saltycode-handoff/auto-handoff.log`.

Want it eager for maximum savings? `export HANDOFF_GENTLE=60000
HANDOFF_RECOMMEND=120000 HANDOFF_URGENT=200000`.

### Archive sinks — `~/.claude/skills/handoff/handoff.config.json`

Off by default. Turn on either or both to keep a permanent record of every
handoff:

```json
{
  "obsidian_vault": "/path/to/your/Obsidian/vault",
  "claude_mem": true
}
```

- **`obsidian_vault`**: the `/handoff` skill and auto-handoff also write a timestamped note to
  `<vault>/Claude Chats/Handoffs/`, with frontmatter + wikilinks.
- **`claude_mem`** — records a searchable claude-mem observation for the handoff
  (requires the [claude-mem](https://github.com/thedotmack/claude-mem) plugin).

---

## How it works (the short version)

Claude Code fires shell **hooks** on lifecycle events and passes each one JSON on
stdin (including `transcript_path`, `session_id`, `cwd`, and — for
`SessionStart` — `source`). Our hooks:

- **read the transcript** to compute current context size and print a
  `{"systemMessage": "..."}` nudge you can see;
- **inject context** on `SessionStart` via
  `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "..."}}`,
  built with `jq` so your handoff's newlines and quotes survive intact.

They fail silent: any parsing hiccup skips the nudge rather than interrupting you.

See [`DESIGN.md`](./DESIGN.md) for the full spec and edge-case handling.

---

## License

MIT © Salty Code Studio. Use it, fork it, ship it.
