#!/usr/bin/env python3
"""Step 1 of the skill-coach evaluation: build one record per real prompt.

Authorized by the product owner (2026-11-11) to read work-project history.
Reads ~/.claude/history.jsonl and the matching session logs for the N projects
with the most recent prompts whose path starts with --include-prefix.
Output (outside the repo, owner-only, never commit it):
  ~/Library/Application Support/Gooby/eval/prompts.jsonl

Each record: id, project, session, ts (ms), prompt, prev_reply, title,
tools (tool-call strings Claude ran before the next prompt),
signature (normalized command set, for action-based ground truth),
has_log (False when only history.jsonl had it).

Run with:
  python3 -I eval/extract.py --include-prefix ~/Gitlab/ --projects 10
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import shlex

HOME = os.path.expanduser("~")
HISTORY = os.path.join(HOME, ".claude/history.jsonl")
PROJECTS = os.path.join(HOME, ".claude/projects")
OUT_DIR = os.path.join(HOME, "Library/Application Support/Gooby/eval")
MAX_REPLY = 1500  # same as Gooby's TranscriptContext.maxContextLength
MATCH_WINDOW_MS = 10_000


def load_history():
    rows = []
    with open(HISTORY, errors="ignore") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("project") and d.get("sessionId") and isinstance(d.get("display"), str):
                rows.append(d)
    return rows


def pick_projects(rows, n, prefix):
    last = {}
    for d in rows:
        if prefix and not (d["project"] + "/").startswith(prefix):
            continue
        last[d["project"]] = max(last.get(d["project"], 0), d.get("timestamp", 0))
    return sorted(last, key=last.get, reverse=True)[:n]


def index_logs():
    """sessionId -> main log path (any folder depth; subagent logs skipped)."""
    out = {}
    for path in glob.glob(os.path.join(PROJECTS, "**/*.jsonl"), recursive=True):
        if "/subagents/" in path:
            continue
        out.setdefault(os.path.splitext(os.path.basename(path))[0], path)
    return out


def parse_ts(s):
    try:
        return int(dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000)
    except (ValueError, AttributeError):
        return None


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")


def tool_string(block):
    name = block.get("name", "?")
    inp = block.get("input") or {}
    if name == "Bash":
        return "Bash: " + str(inp.get("command", ""))[:300]
    for key in ("file_path", "path", "pattern", "url", "skill", "query"):
        if key in inp:
            return f"{name}: {str(inp[key])[:200]}"
    return name


CMD_SPLIT = re.compile(r"&&|\|\||;|\||\n|\$\(|`|\)")
SUBCOMMAND_TOOLS = {"git", "npm", "npx", "yarn", "pnpm", "xcodebuild", "docker", "kubectl", "oc", "glab", "gh",
                    "python3", "python", "pip", "cargo", "go", "make", "swift", "brew", "uv", "pytest"}


SHELL_KEYWORDS = {"cd", "for", "do", "done", "if", "then", "else", "elif", "fi", "while", "until", "case", "esac",
                  "in", "{", "}", "(", ")", "[", "[[", "!", "function", "return", "export", "local", "set", "true"}
PROGRAM = re.compile(r"^[A-Za-z0-9_./~-]+$")


HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")


def strip_quotes(cmd):
    """Replaces quoted text with Q so code inside quotes (python -c, $(...)) isn't read as commands.
    An unclosed quote (command cut at 300 chars) drops the rest."""
    out, i, n = [], 0, len(cmd)
    while i < n:
        ch = cmd[i]
        if ch in "'\"":
            j = cmd.find(ch, i + 1)
            while ch == '"' and j != -1 and cmd[j - 1] == "\\":
                j = cmd.find(ch, j + 1)
            if j == -1:
                break
            out.append("Q")
            i = j + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def command_lines(cmd):
    """Shell text minus heredoc bodies and quoted text, with backslash-continued lines joined."""
    cmd = cmd.replace("\\\n", " ")
    out, end_marker = [], None
    for line in cmd.split("\n"):
        if end_marker is not None:
            if line.strip() == end_marker:
                end_marker = None
            continue
        m = HEREDOC.search(line)
        if m:
            end_marker = m.group(1)
            line = line[:m.start()]
        out.append(line)
    return strip_quotes("\n".join(out))


def signature(tools):
    """Normalized commands, e.g. ['git commit', 'git push']; other tools by name ('Edit', 'Write')."""
    sig = set()
    for t in tools:
        if not t.startswith("Bash: "):
            sig.add(t.split(":")[0])
            continue
        for part in CMD_SPLIT.split(command_lines(t[6:])):
            try:
                words = shlex.split(part)
            except ValueError:
                words = part.split()
            # Drop leading VAR=value assignments and wrappers.
            while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] in ("sudo", "env", "time")):
                words = words[1:]
            if not words or words[0] in SHELL_KEYWORDS or not PROGRAM.match(words[0]):
                continue
            prog = os.path.basename(words[0])
            rest = words[1:]
            if prog == "git" and rest[:1] == ["-C"]:
                rest = rest[2:]
            if prog.startswith("python") and "-c" in [w for w in rest if w.startswith("-")]:
                sig.add(prog + " -c")  # inline code: the code itself isn't a command
                continue
            sub = next((w for w in rest if not w.startswith("-")), "")
            if sub == "Q":  # a quoted argument, blanked by strip_quotes
                sub = ""
            if prog.startswith("python") or not PROGRAM.match(sub):
                base = os.path.basename(sub)
                sub = base if PROGRAM.match(base) else ""
            sig.add(f"{prog} {sub}".strip() if prog in SUBCOMMAND_TOOLS else prog)
    return sorted(sig)


def walk_log(path):
    """Yields one dict per real user prompt: ts, text, prev_reply, title, tools."""
    title, prev_reply, current = None, None, None
    with open(path, errors="ignore") as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            t = e.get("type")
            if t == "ai-title":
                title = e.get("aiTitle") or title
            elif t == "assistant" and not e.get("isSidechain"):
                msg = e.get("message") or {}
                txt = text_of(msg.get("content")).strip()
                if txt:
                    prev_reply = txt
                if current is not None:
                    for b in msg.get("content") or []:
                        if isinstance(b, dict) and b.get("type") == "tool_use":
                            current["tools"].append(tool_string(b))
            elif t == "user" and not e.get("isSidechain") and not e.get("isMeta") and not e.get("isCompactSummary"):
                content = (e.get("message") or {}).get("content")
                if not isinstance(content, str):  # tool results arrive as lists
                    continue
                if current is not None:
                    yield current
                reply = prev_reply
                if reply and len(reply) > MAX_REPLY:
                    reply = "…" + reply[-MAX_REPLY:]
                current = {"ts": parse_ts(e.get("timestamp")), "text": content, "prev_reply": reply,
                           "title": title, "tools": []}
    if current is not None:
        yield current


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--projects", type=int, default=10)
    ap.add_argument("--include-prefix", default="")
    ap.add_argument("--exclude-session", action="append", default=[])
    args = ap.parse_args()
    prefix = os.path.expanduser(args.include_prefix)
    if prefix and not prefix.endswith("/"):
        prefix += "/"

    rows = load_history()
    projects = pick_projects(rows, args.projects, prefix)
    logs = index_logs()
    excluded = set(args.exclude_session)

    walked = {}
    records, joined = [], 0
    for d in sorted((r for r in rows if r["project"] in projects), key=lambda r: r.get("timestamp", 0)):
        sid = d["sessionId"]
        if sid in excluded:
            continue
        rec = {"id": len(records), "project": d["project"], "session": sid, "ts": d.get("timestamp", 0),
               "prompt": d["display"], "prev_reply": None, "title": None, "tools": [], "has_log": False}
        if sid in logs:
            if sid not in walked:
                walked[sid] = list(walk_log(logs[sid]))
            best = None
            for p in walked[sid]:
                if p["ts"] is None:
                    continue
                gap = abs(p["ts"] - rec["ts"])
                if gap <= MATCH_WINDOW_MS and (best is None or gap < best[0]):
                    best = (gap, p)
            if best:
                p = best[1]
                walked[sid].remove(p)  # each log prompt joins at most one history row
                # The log has the full text; history.jsonl swaps pastes for placeholders.
                rec.update(prompt=p["text"], prev_reply=p["prev_reply"], title=p["title"], tools=p["tools"],
                           has_log=True)
                joined += 1
        rec["signature"] = signature(rec["tools"])
        records.append(rec)

    os.makedirs(OUT_DIR, mode=0o700, exist_ok=True)
    out = os.path.join(OUT_DIR, "prompts.jsonl")
    with open(out, "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")
    os.chmod(out, 0o600)

    print(f"projects: {len(projects)} (prefix {prefix or 'none'})")
    for p in projects:
        n = sum(r["project"] == p for r in records)
        j = sum(r["project"] == p and r["has_log"] for r in records)
        print(f"  {n:5} prompts  {j:5} with log  {p}")
    print(f"records: {len(records)}  joined to a log: {joined}  "
          f"with prev reply: {sum(bool(r['prev_reply']) for r in records)}  "
          f"with title: {sum(bool(r['title']) for r in records)}  "
          f"with tool calls: {sum(bool(r['tools']) for r in records)}")
    print(f"sessions: {len(set(r['session'] for r in records))}  excluded sessions: {sorted(excluded)}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
