#!/usr/bin/env python3
"""saltycode-handoff :: auto-handoff

Runs on: SessionEnd (reason == "clear").
Reads the session transcript, works out which project the session was about
(git root of the files it edited), then in the background asks a headless
Claude to write HANDOFF.md into that project's folder.

Also archives a dated copy to the vault from handoff.config.json and leaves a
pointer so the next session (session-resume.sh) knows where the handoff went.

Env:
  HANDOFF_AUTOGEN=0            disable
  HANDOFF_AUTOGEN_REASONS      comma list of SessionEnd reasons (default "clear")
  HANDOFF_AUTOGEN_MODEL        model alias (default "sonnet")
  HANDOFF_AUTOGEN_MIN_PROMPTS  skip sessions with fewer user prompts (default 2)
"""
import json, os, re, subprocess, sys, time
from collections import Counter
from datetime import datetime
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).resolve().parent
LOG = HERE / "auto-handoff.log"
STATE = Path(os.environ.get("HANDOFF_STATE_DIR", os.path.join(os.environ.get("TMPDIR", "/tmp"), "saltycode-handoff")))
CONFIG = HOME / ".claude/skills/handoff/handoff.config.json"
MODEL = os.environ.get("HANDOFF_AUTOGEN_MODEL", "sonnet")
MIN_PROMPTS = int(os.environ.get("HANDOFF_AUTOGEN_MIN_PROMPTS", "2"))
DIGEST_CAP = 140_000
MARKERS = ("package.json", "CLAUDE.md", "HANDOFF.md", "pyproject.toml", "Cargo.toml", "go.mod", "astro.config.mjs")


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}\n")
    except Exception:
        pass


def key(p):
    return re.sub(r"[^A-Za-z0-9]", "_", str(p))


def strip_reminders(s):
    s = re.sub(r"<system-reminder>.*?</system-reminder>", "", s, flags=re.S)
    s = re.sub(r"<local-command-(stdout|caveat)>.*?</local-command-\1>", "", s, flags=re.S)
    return s.strip()


def clip(s, n):
    s = s.strip()
    return s if len(s) <= n else s[:n] + " …[cut]"


def tool_summary(name, inp):
    if not isinstance(inp, dict):
        return name
    for k in ("file_path", "notebook_path", "command", "pattern", "url", "description", "prompt", "skill", "query"):
        if inp.get(k):
            return f"{name}({clip(str(inp[k]).replace(chr(10), ' '), 220)})"
    return name


SKIP = ("/tmp", "/private", "/var", str(HOME / ".claude/projects"), str(HOME / ".claude/plugins"))


def project_root(path):
    if str(path).startswith(SKIP):
        return None
    p = Path(path)
    p = p if p.is_dir() else p.parent
    if not p.exists():
        return None
    start = p
    while p != p.parent and p != HOME:
        if (p / ".git").exists():
            return p
        p = p.parent
    p = start
    while p != p.parent and p != HOME:
        if any((p / m).exists() for m in MARKERS):
            return p
        p = p.parent
    return start if start != HOME else None


def parse(transcript):
    lines, prompts, title = [], 0, None
    scores = Counter()
    for raw in open(transcript, errors="replace"):
        try:
            d = json.loads(raw)
        except Exception:
            continue
        t = d.get("type")
        if t == "ai-title":
            title = d.get("aiTitle") or d.get("title") or title
            continue
        if t not in ("user", "assistant") or d.get("isSidechain"):
            continue
        content = (d.get("message") or {}).get("content")
        if t == "user":
            if d.get("isMeta"):
                continue
            texts = [content] if isinstance(content, str) else [b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text"]
            txt = strip_reminders("\n".join(texts))
            if not txt:
                continue
            if d.get("isCompactSummary"):
                lines.append(f"[EARLIER CONTEXT SUMMARY]\n{clip(txt, 12000)}")
            else:
                prompts += 1
                lines.append(f"USER: {clip(txt, 2500)}")
        else:
            for b in content if isinstance(content, list) else []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    lines.append(f"CLAUDE: {clip(b['text'], 2500)}")
                elif b.get("type") == "tool_use":
                    name, inp = b.get("name", "?"), b.get("input") or {}
                    lines.append(f"  → {tool_summary(name, inp)}")
                    fp = inp.get("file_path") or inp.get("notebook_path")
                    weight = 3 if name in ("Edit", "Write", "NotebookEdit", "MultiEdit") else 1
                    if fp:
                        root = project_root(fp)
                        if root:
                            scores[root] += weight
                    if name == "Bash":
                        for m in re.findall(r"cd\s+([~/][^\s;&|]+)", inp.get("command", "")):
                            root = project_root(os.path.expanduser(m.strip("'\"")))
                            if root:
                                scores[root] += 1
    return lines, prompts, title, scores


def digest(lines):
    text = "\n".join(lines)
    if len(text) <= DIGEST_CAP:
        return text
    head = text[:20_000]
    tail = text[-(DIGEST_CAP - 20_000):]
    return head + "\n\n[… middle of session omitted …]\n\n" + tail


PROMPT = """You are writing a HANDOFF.md for a Claude Code session that just ended with /clear.
Below is a condensed transcript (user prompts, Claude's replies, tool calls). Write the handoff so a fresh session can resume with minimal tokens.

Rules:
- Output ONLY the markdown file content, no preamble, no code fences around it.
- Synthesize, never dump the transcript. Concrete and skimmable. Reference files with paths and line numbers instead of pasting code.
- Mark done items ✅ verified or 🔧 done-but-unverified, based only on evidence in the transcript.
- No em-dashes in prose.
- If the session touched other projects too, list them under "Also touched".

Template:
# HANDOFF: <short task/project title>
_{when} · {root} · auto-written on /clear_

## Goal
## Current state
## Next steps
## Key files
## Decisions & why
## Gotchas / watch-outs
## Also touched   (omit if none)
## Resume prompt
> <paste-ready instruction for the fresh session>

Session working directory: {cwd}
Project folder for this handoff: {root}

=== TRANSCRIPT ===
{digest}
"""


def main():
    if os.environ.get("HANDOFF_AUTOGEN", "1") == "0" or os.environ.get("SALTY_HANDOFF_CHILD"):
        return
    try:
        inp = json.load(sys.stdin)
    except Exception:
        return
    reasons = os.environ.get("HANDOFF_AUTOGEN_REASONS", "clear").split(",")
    if inp.get("reason") not in reasons:
        return
    transcript, cwd = inp.get("transcript_path"), inp.get("cwd") or os.getcwd()
    if not transcript or not os.path.exists(transcript):
        return

    lines, prompts, title, scores = parse(transcript)
    if prompts < MIN_PROMPTS:
        log(f"skip {transcript}: only {prompts} prompts")
        return

    root = scores.most_common(1)[0][0] if scores else Path(cwd)
    target = Path(os.environ["HANDOFF_TEST_TARGET"]) if os.environ.get("HANDOFF_TEST_TARGET") else root / "HANDOFF.md"
    others = [str(r) for r, _ in scores.most_common(4)[1:]]

    # a manual /handoff in the last 15 min wins
    if target.exists() and time.time() - target.stat().st_mtime < 900:
        log(f"skip: {target} written manually <15m ago")
        return

    STATE.mkdir(parents=True, exist_ok=True)
    pointer = STATE / f"pending_{key(cwd)}.json"
    pointer.write_text(json.dumps({"target": str(target), "title": title, "started": time.time(), "others": others}))

    # detach; the rest runs after /clear returns
    if os.fork():
        return
    os.setsid()
    if os.fork():
        os._exit(0)
    nul = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(nul, fd)

    try:
        when = datetime.now().astimezone().isoformat(timespec="minutes")
        prompt = PROMPT.format(when=when, root=root, cwd=cwd, digest=digest(lines))
        env = dict(os.environ, SALTY_HANDOFF_CHILD="1")
        r = subprocess.run(
            ["claude", "-p", "--model", MODEL, "--tools", "", "--no-session-persistence",
             "--settings", json.dumps({"disableAllHooks": True})],
            input=prompt, capture_output=True, text=True, timeout=300, env=env, cwd=str(root),
        )
        md = r.stdout.strip()
        md = re.sub(r"^```(?:markdown|md)?\n(.*)\n```$", r"\1", md, flags=re.S)
        if r.returncode != 0 or not md.startswith("#"):
            log(f"FAIL {target}: rc={r.returncode} out={md[:200]!r} err={r.stderr[:300]!r}")
            return
        target.write_text(md + "\n")

        # keep HANDOFF.md out of git without touching .gitignore
        git = root / ".git"
        if git.is_dir():
            excl = git / "info/exclude"
            excl.parent.mkdir(exist_ok=True)
            cur = excl.read_text() if excl.exists() else ""
            if "HANDOFF.md" not in cur:
                excl.write_text(cur.rstrip("\n") + ("\n" if cur else "") + "HANDOFF.md\n")

        # archive a dated copy to the vault
        try:
            vault = json.loads(CONFIG.read_text()).get("obsidian_vault")
        except Exception:
            vault = None
        if vault:
            d = Path(vault) / "Claude Chats/Handoffs"
            d.mkdir(parents=True, exist_ok=True)
            slug = re.sub(r"[^a-z0-9]+", "-", root.name.lower()).strip("-") or "session"
            base = f"{datetime.now():%Y-%m-%d-%H%M}-{slug}"
            out, n = d / f"{base}.md", 2
            while out.exists():
                out, n = d / f"{base}-{n}.md", n + 1
            fm = (f"---\ntitle: \"{(title or root.name).replace(chr(34), '')}\"\ndate: {when}\n"
                  f"tags: [handoff, claude-code, auto]\nproject: \"{root}\"\n"
                  f"session_id: {inp.get('session_id', '')}\n---\n\n")
            out.write_text(fm + md + "\n")
        pointer.write_text(json.dumps({"target": str(target), "title": title, "done": time.time(), "others": others}))
        log(f"OK {target}")
    except Exception as e:
        log(f"ERROR {target}: {e!r}")
    os._exit(0)


if __name__ == "__main__":
    main()
