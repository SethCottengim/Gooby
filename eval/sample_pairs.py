#!/usr/bin/env python3
"""Step 2: sample prompt pairs for a blind "same task?" gold set.

Reads prompts.jsonl (from extract.py). Writes, outside the repo (owner-only):
  labeling_sheet.csv  - what the human labels (no scores, no strata, shuffled)
  pairs_key.jsonl     - hidden: stratum, TF-IDF cosine, action-based label

Strata (cross-session pairs only):
  lookalike   highest TF-IDF cosine
  mid         cosine 0.20-0.45
  random      uniform
  context     short reply after a Claude message ("yes", "go ahead") paired with
              another logged prompt; half chosen to share Claude's tool actions

Action label (ground truth neither of us picks), from what Claude ran in reply:
  same      both did shell/skill actions and their command sets overlap >= 50% (Jaccard)
  different both did shell/skill actions with no overlap
  unknown   otherwise (no log, or only read/edit tools)

Run with:  python3 -I eval/sample_pairs.py [--seed 7]
"""
import argparse
import collections
import csv
import json
import math
import os
import random
import re

EVAL_DIR = os.path.expanduser("~/Library/Application Support/Gooby/eval")
GENERIC_TOOLS = {"Read", "Grep", "Glob", "Edit", "Write", "MultiEdit", "TodoWrite", "NotebookEdit", "LS",
                 "AskUserQuestion", "ToolSearch", "WebSearch", "WebFetch", "Agent", "Task", "ExitPlanMode",
                 "EnterPlanMode", "ls", "cat", "head", "tail", "grep", "find", "echo", "sed", "wc", "rg",
                 # read-only or plumbing commands: they say little about what the task was
                 "awk", "sort", "uniq", "jq", "pwd", "which", "date", "sleep", "printf", "test", "stat", "file",
                 "tr", "cut", "xargs", "python3 -c", "python -c", "rm", "mkdir", "cp", "mv", "touch", "chmod",
                 "open", "curl", "git status", "git log", "git diff", "git show", "git fetch", "git branch",
                 "git rev-parse", "git remote", "git config", "git ls-files", "git worktree", "git stash"}
SHORT = 6
STRATA = {"lookalike": 80, "mid": 40, "random": 40, "context": 40}


def worth(r):
    """Same local filter as Gooby (PromptInbox.isWorthClassifying)."""
    t = r["prompt"].strip()
    if not t or t[0] in "/!":
        return False
    return len(t) >= SHORT or bool(r.get("prev_reply"))


TOKEN = re.compile(r"[a-z0-9]+")


def tfidf(records):
    docs = [collections.Counter(TOKEN.findall(r["prompt"].lower())) for r in records]
    df = collections.Counter(w for d in docs for w in d)
    n = len(docs)
    vecs = []
    for d in docs:
        v = {w: (1 + math.log(c)) * math.log((n + 1) / (df[w] + 1)) for w, c in d.items()}
        norm = math.sqrt(sum(x * x for x in v.values())) or 1.0
        vecs.append({w: x / norm for w, x in v.items()})
    return vecs


def cosine(a, b):
    if len(a) > len(b):
        a, b = b, a
    return sum(x * b.get(w, 0.0) for w, x in a.items())


def action_set(r):
    return {s for s in r.get("signature", []) if s not in GENERIC_TOOLS}


def action_label(a, b):
    sa, sb = action_set(a), action_set(b)
    if not sa or not sb:
        return "unknown"
    j = len(sa & sb) / len(sa | sb)
    return "same" if j >= 0.5 else ("different" if j == 0 else "unknown")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--relabel", action="store_true",
                    help="only recompute action labels in pairs_key.jsonl; keep the sheet's pairs unchanged")
    args = ap.parse_args()
    rng = random.Random(args.seed)

    records = [json.loads(l) for l in open(os.path.join(EVAL_DIR, "prompts.jsonl"))]
    if args.relabel:
        by_id = {r["id"]: r for r in records}
        key = os.path.join(EVAL_DIR, "pairs_key.jsonl")
        pairs = [json.loads(l) for l in open(key)]
        for p in pairs:
            p["action_label"] = action_label(by_id[p["a"]], by_id[p["b"]])
        with open(key, "w") as f:
            for p in pairs:
                f.write(json.dumps(p) + "\n")
        print("relabeled", len(pairs), "pairs; action labels:",
              dict(collections.Counter(p["action_label"] for p in pairs)))
        return
    pool = [r for r in records if worth(r) and len(r["prompt"].strip()) >= SHORT]
    vecs = dict(zip((r["id"] for r in pool), tfidf(pool)))

    # All cross-session pairs with cosine (pool is ~2k, so ~2M pairs; keep a bounded sample per band).
    scored = []
    for i, a in enumerate(pool):
        va = vecs[a["id"]]
        for b in pool[i + 1:]:
            if a["session"] == b["session"] or a["prompt"].strip().lower() == b["prompt"].strip().lower():
                continue
            c = cosine(va, vecs[b["id"]])
            if c >= 0.20:
                scored.append((c, a["id"], b["id"]))
    scored.sort(reverse=True)
    by_id = {r["id"]: r for r in records}

    chosen, used = [], set()

    def take(stratum, a_id, b_id, cos):
        key = tuple(sorted((a_id, b_id)))
        if key in used:
            return False
        used.add(key)
        chosen.append({"stratum": stratum, "a": a_id, "b": b_id, "cosine": round(cos, 4)})
        return True

    # Lookalikes: highest cosine, but cap each prompt's appearances so one prompt can't dominate.
    per_prompt = collections.Counter()
    for c, a, b in scored:
        if sum(p["stratum"] == "lookalike" for p in chosen) >= STRATA["lookalike"]:
            break
        if c >= 0.45 and per_prompt[a] < 2 and per_prompt[b] < 2 and take("lookalike", a, b, c):
            per_prompt[a] += 1
            per_prompt[b] += 1
    mid = [s for s in scored if 0.20 <= s[0] < 0.45]
    rng.shuffle(mid)
    for c, a, b in mid:
        if sum(p["stratum"] == "mid" for p in chosen) >= STRATA["mid"]:
            break
        take("mid", a, b, c)
    while sum(p["stratum"] == "random" for p in chosen) < STRATA["random"]:
        a, b = rng.sample(pool, 2)
        if a["session"] != b["session"]:
            take("random", a["id"], b["id"], cosine(vecs[a["id"]], vecs[b["id"]]))

    # Context pairs: short replies that only make sense with Claude's previous message.
    shorts = [r for r in records if worth(r) and len(r["prompt"].strip()) < 40 and r.get("prev_reply")]
    logged = [r for r in pool if r["has_log"]]
    rng.shuffle(shorts)
    for s in shorts:
        if sum(p["stratum"] == "context" for p in chosen) >= STRATA["context"]:
            break
        partners = [r for r in logged if r["session"] != s["session"] and action_label(s, r) == "same"]
        want_same = sum(p["stratum"] == "context" for p in chosen) % 2 == 0
        if want_same and partners:
            b = rng.choice(partners)
        else:
            b = rng.choice([r for r in logged if r["session"] != s["session"]])
        take("context", s["id"], b["id"], 0.0)

    rng.shuffle(chosen)
    for n, p in enumerate(chosen, 1):
        p["pair_id"] = f"P{n:03d}"
        p["action_label"] = action_label(by_id[p["a"]], by_id[p["b"]])

    def show(r, field):
        v = r.get(field) or ""
        return v if len(v) <= 600 else "…" + v[-600:]

    sheet = os.path.join(EVAL_DIR, "labeling_sheet.csv")
    with open(sheet, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["pair_id", "A_claude_said_before", "A_prompt", "B_claude_said_before", "B_prompt",
                    "same_task (y/n/?)", "notes"])
        for p in chosen:
            a, b = by_id[p["a"]], by_id[p["b"]]
            w.writerow([p["pair_id"], show(a, "prev_reply"), a["prompt"][:1500], show(b, "prev_reply"),
                        b["prompt"][:1500], "", ""])
    key = os.path.join(EVAL_DIR, "pairs_key.jsonl")
    with open(key, "w") as f:
        for p in chosen:
            f.write(json.dumps(p) + "\n")
    for path in (sheet, key):
        os.chmod(path, 0o600)

    print(f"pool (worth classifying, >= {SHORT} chars): {len(pool)}  short-with-context: {len(shorts)}")
    print(f"cross-session pairs with cosine >= 0.20: {len(scored)}")
    print("pairs per stratum:", dict(collections.Counter(p["stratum"] for p in chosen)))
    print("action labels:", dict(collections.Counter(p["action_label"] for p in chosen)))
    print(f"wrote {sheet}\nwrote {key} (hidden key; don't open before labeling)")


if __name__ == "__main__":
    main()
