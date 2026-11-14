#!/usr/bin/env python3
"""Step 5: read the mistakes. For gold pairs with a decisive label, show both prompts,
the action overlap, and which intent each replay setup put each prompt in.

Run with:  python3 -I eval/error_analysis.py [--label same|different] [--run 1] [--width 90]
Prints work prompts to the terminal; nothing is written.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sample_pairs as sp  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--label", default="same")
ap.add_argument("--run", type=int, default=1)
ap.add_argument("--width", type=int, default=90)
args = ap.parse_args()

records = {r["id"]: r for r in (json.loads(l) for l in open(os.path.join(sp.EVAL_DIR, "prompts.jsonl")))}
key = [json.loads(l) for l in open(os.path.join(sp.EVAL_DIR, "pairs_key.jsonl"))]
setups = ["prompt", "reply", "title", "reply+title"]
lines = {}
for s in setups:
    path = os.path.join(sp.EVAL_DIR, "replay", f"{s}-run{args.run}.jsonl")
    lines[s] = {l["id"]: l for l in (json.loads(x) for x in open(path))}


def verdict(l):
    if l is None:
        return "-"
    if l.get("skipped"):
        return "skipped"
    k = l.get("kind")
    if k in ("new", "match"):
        return f"{k}:{l.get('slug')}" + (f"@{l['confidence']:.2f}" if l.get("confidence") else "")
    return k or "?"


def clip(t):
    t = " ".join((t or "").split())
    return t if len(t) <= args.width else t[: args.width - 1] + "…"


for p in key:
    if p["action_label"] != args.label:
        continue
    a, b = records[p["a"]], records[p["b"]]
    shared = sorted(sp.action_set(a) & sp.action_set(b))
    same_by = [s for s in setups
               if lines[s].get(a["id"], {}).get("intentID")
               and lines[s].get(a["id"], {}).get("intentID") == lines[s].get(b["id"], {}).get("intentID")]
    print(f"{p['pair_id']} [{p['stratum']}] shared actions: {', '.join(shared) or '-'}")
    print(f"  A #{a['id']}: {clip(a['prompt'])}")
    if a.get("prev_reply") and len(a["prompt"]) < 40:
        print(f"     (Claude before: {clip(a['prev_reply'][-200:])})")
    print(f"  B #{b['id']}: {clip(b['prompt'])}")
    if b.get("prev_reply") and len(b["prompt"]) < 40:
        print(f"     (Claude before: {clip(b['prev_reply'][-200:])})")
    print(f"  reply setup: A={verdict(lines['reply'].get(a['id']))}  B={verdict(lines['reply'].get(b['id']))}")
    print(f"  grouped together by: {', '.join(same_by) or 'none'}")
    print()
