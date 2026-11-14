#!/usr/bin/env python3
"""Targeted check of a classifier rule change on the skills that would have been offered.

  prepare: from a finished replay run (default reply run 1), list every intent that reached
           the offer threshold and the prompts behind it; write shard id files for the replay
           tool (--ids ... --independent, runs 101..100+N).
  report:  after those check runs, show per offer how many of its prompts the new rule
           still treats as a task, and whether it would still reach the threshold
           (distinct sessions among prompts not ignored).

Run with:
  python3 -I eval/offer_check.py prepare [--setup reply --run 1 --shards 4]
  python3 -I eval/offer_check.py report  [--setup reply --run 1 --shards 4]
"""
import argparse
import collections
import glob
import json
import os

EVAL_DIR = os.path.expanduser("~/Library/Application Support/Gooby/eval")
CHECK_DIR = os.path.join(EVAL_DIR, "offer_check")
THRESHOLD = 5  # keep in sync with IntentStore.offerThreshold


def load(path):
    return [json.loads(l) for l in open(path) if l.strip()]


def offers(setup, run, records):
    lines = load(os.path.join(EVAL_DIR, "replay", f"{setup}-run{run}.jsonl"))
    by_intent = collections.defaultdict(list)
    slug = {}
    for l in lines:
        if l.get("kind") in ("new", "match") and l.get("intentID"):
            by_intent[l["intentID"]].append(l["id"])
            slug.setdefault(l["intentID"], l.get("slug"))
    out = []
    for iid, ids in by_intent.items():
        sessions = {records[i]["session"] for i in ids}
        if len(sessions) >= THRESHOLD:
            out.append({"intent": iid, "slug": slug[iid], "sessions": len(sessions), "ids": sorted(ids)})
    return sorted(out, key=lambda o: -o["sessions"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("step", choices=["prepare", "report"])
    ap.add_argument("--setup", default="reply")
    ap.add_argument("--run", type=int, default=1)
    ap.add_argument("--shards", type=int, default=4)
    args = ap.parse_args()
    records = {r["id"]: r for r in load(os.path.join(EVAL_DIR, "prompts.jsonl"))}
    os.makedirs(CHECK_DIR, mode=0o700, exist_ok=True)
    offs = offers(args.setup, args.run, records)

    if args.step == "prepare":
        ids = sorted({i for o in offs for i in o["ids"]})
        for k in range(args.shards):
            path = os.path.join(CHECK_DIR, f"ids-{k + 1}.txt")
            with open(path, "w") as f:
                f.write("\n".join(str(i) for i in ids[k::args.shards]) + "\n")
            os.chmod(path, 0o600)
        print(f"{len(offs)} offers in {args.setup} run {args.run}; {len(ids)} prompts behind them; "
              f"{args.shards} shards in {CHECK_DIR}")
        for k in range(args.shards):
            print(f"  run {101 + k}: --ids {os.path.join(CHECK_DIR, f'ids-{k + 1}.txt')}")
        return

    verdict = {}
    for path in glob.glob(os.path.join(EVAL_DIR, "replay", f"{args.setup}-run1[0-9][0-9].jsonl")):
        for l in load(path):
            verdict[l["id"]] = "skipped" if l.get("skipped") else l.get("kind")
    print(f"| offer | sessions before | prompts | not checked yet | still a task | now ignored | sessions after | still offered |")
    print("|---|---|---|---|---|---|---|---|")
    kept = 0
    missing = 0
    for o in offs:
        v = [verdict.get(i) for i in o["ids"]]
        missing += sum(x is None for x in v)
        task_ids = [i for i, x in zip(o["ids"], v) if x in ("new", "match")]
        after = len({records[i]["session"] for i in task_ids})
        unchecked = [i for i, x in zip(o["ids"], v) if x is None]
        could_reach = len({records[i]["session"] for i in task_ids + unchecked}) >= THRESHOLD
        still = after >= THRESHOLD
        kept += still
        status = "yes" if still else ("pending" if unchecked and could_reach else "**no**")
        print(f"| `{o['slug']}` | {o['sessions']} | {len(o['ids'])} | {len(unchecked)} | {len(task_ids)} | "
              f"{sum(x in ('ignore', 'skipped') for x in v)} | {after} | {status} |")
    pending = "" if not missing else " so far"
    print(f"\n{kept} of {len(offs)} offers survive the new rule{pending}.")
    if missing:
        print(f"({missing} prompts not checked yet; rerun after the check runs finish.)")


if __name__ == "__main__":
    main()
