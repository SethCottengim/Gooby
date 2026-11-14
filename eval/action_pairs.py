#!/usr/bin/env python3
"""Step 2b: add an "actions" stratum to the gold set (P201+), leaving P001-P200 untouched.

Only prompts that have a session log AND real actions (after dropping read-only and
plumbing commands) are used, so every new pair has an action-based label that
neither the labeler nor the model chose. Balanced: half "same", half "different"
(as far as the data allows). Appends to labeling_sheet.csv and pairs_key.jsonl.

Run with:  python3 -I eval/action_pairs.py [--count 40] [--seed 11]
"""
import argparse
import collections
import csv
import itertools
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sample_pairs as sp  # noqa: E402  (same filters and labels as the main sampler)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=40)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--replace", action="store_true", help="drop an existing actions stratum first")
    args = ap.parse_args()
    rng = random.Random(args.seed)

    records = [json.loads(l) for l in open(os.path.join(sp.EVAL_DIR, "prompts.jsonl"))]
    by_id = {r["id"]: r for r in records}
    key_path = os.path.join(sp.EVAL_DIR, "pairs_key.jsonl")
    sheet_path = os.path.join(sp.EVAL_DIR, "labeling_sheet.csv")
    existing = [json.loads(l) for l in open(key_path)]
    if any(p["stratum"] == "actions" for p in existing):
        if not args.replace:
            sys.exit("actions stratum already present; use --replace to rebuild it")
        drop = {p["pair_id"] for p in existing if p["stratum"] == "actions"}
        existing = [p for p in existing if p["pair_id"] not in drop]
        with open(sheet_path, newline="") as f:
            all_rows = [row for row in csv.reader(f) if row]
        if any(len(row) > 5 and row[5].strip() for row in all_rows[1:] if row[0] in drop):
            sys.exit("refusing: some pairs being dropped are already labeled")
        rows = [row for row in all_rows if row[0] not in drop]
        with open(sheet_path, "w", newline="") as f:
            csv.writer(f).writerows(rows)
        with open(key_path, "w") as f:
            for p in existing:
                f.write(json.dumps(p) + "\n")
        print(f"dropped {len(drop)} previous actions pairs")
    used = {tuple(sorted((p["a"], p["b"]))) for p in existing}

    logged = [r for r in records if r["has_log"] and sp.worth(r) and sp.action_set(r)]
    same, diff = [], []
    for a, b in itertools.combinations(logged, 2):
        if a["session"] == b["session"] or tuple(sorted((a["id"], b["id"]))) in used:
            continue
        label = sp.action_label(a, b)
        if label == "same":
            same.append((a["id"], b["id"]))
        elif label == "different":
            diff.append((a["id"], b["id"]))
    print(f"logged prompts with real actions: {len(logged)} in {len(set(r['session'] for r in logged))} sessions")
    print(f"candidate cross-session pairs: same={len(same)} different={len(diff)}")

    # Spread pairs across prompts: no prompt used more than twice.
    def pick(pool, n):
        rng.shuffle(pool)
        uses, out = collections.Counter(), []
        for a, b in pool:
            if len(out) >= n:
                break
            if uses[a] < 2 and uses[b] < 2:
                out.append((a, b))
                uses[a] += 1
                uses[b] += 1
        return out

    chosen_same = pick(same, args.count // 2)
    chosen_diff = pick(diff, args.count - len(chosen_same))
    new = [{"stratum": "actions", "a": a, "b": b, "cosine": None, "action_label": lab}
           for lab, group in (("same", chosen_same), ("different", chosen_diff)) for a, b in group]
    rng.shuffle(new)
    start = len(existing) + 1
    for n, p in enumerate(new, start):
        p["pair_id"] = f"P{n:03d}"

    def show(r, field):
        v = r.get(field) or ""
        return v if len(v) <= 600 else "…" + v[-600:]

    with open(sheet_path, "a", newline="") as f:
        w = csv.writer(f)
        for p in new:
            a, b = by_id[p["a"]], by_id[p["b"]]
            w.writerow([p["pair_id"], show(a, "prev_reply"), a["prompt"][:1500], show(b, "prev_reply"),
                        b["prompt"][:1500], "", ""])
    with open(key_path, "a") as f:
        for p in new:
            f.write(json.dumps(p) + "\n")
    print(f"added {len(new)} pairs ({len(chosen_same)} same, {len(chosen_diff)} different) "
          f"as P{start:03d}-P{start + len(new) - 1:03d}")
    top = collections.Counter(s for r in logged for s in sp.action_set(r)).most_common(12)
    print("most common real actions:", top)


if __name__ == "__main__":
    main()
