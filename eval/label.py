#!/usr/bin/env python3
"""Label the gold set one pair at a time, in a terminal.

Keys: y = same task, n = different tasks, ? = can't tell, s = skip for now,
      b = back one pair, q = save and quit.
Answers are written to labeling_sheet.csv after every key, so you can stop any time.
Pairs that matter most for the context question come first. The order uses the
hidden key only for sorting; no group names, scores or answers are ever shown.

Run in a Terminal tab (it needs the keyboard):
  python3 -I eval/label.py            # unlabeled pairs, most important first
  python3 -I eval/label.py --all      # every pair, incl. ones already labeled
"""
import argparse
import csv
import json
import os
import shutil
import sys
import termios
import textwrap
import tty

EVAL_DIR = os.path.expanduser("~/Library/Application Support/Gooby/eval")
SHEET = os.path.join(EVAL_DIR, "labeling_sheet.csv")
KEY = os.path.join(EVAL_DIR, "pairs_key.jsonl")
LABEL_COL = "same_task (y/n/?)"
PRIORITY = {"context": 0, "actions": 0, "lookalike": 1, "mid": 2, "random": 3}


def read_key():
    """One keypress, no Enter needed."""
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        return sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def save(rows, fields):
    tmp = SHEET + ".tmp"
    with open(tmp, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    os.chmod(tmp, 0o600)
    os.replace(tmp, SHEET)


def show(row, done, total):
    width = min(shutil.get_terminal_size((100, 30)).columns, 110) - 4
    wrap = lambda t: textwrap.fill(" ".join((t or "").split()), width, initial_indent="    ",  # noqa: E731
                                   subsequent_indent="    ") or "    (none)"
    clip = lambda t, n: t if len(t) <= n else "…" + t[-n:]  # noqa: E731
    os.system("clear")
    print(f"{row['pair_id']}   ({done} labeled of {total})\n")
    for side in ("A", "B"):
        before = row[f"{side}_claude_said_before"]
        prompt = row[f"{side}_prompt"]
        print(f"{side}:")
        if before and len(prompt.strip()) < 60:
            print("  Claude said just before:")
            print(wrap(clip(before, 400)))
        print("  The developer asked:")
        print(wrap(prompt[:900]))
        print()
    print("Is this the SAME reusable task (would one skill do both)?")
    print("  y = same   n = different   ? = can't tell   s = skip   b = back   q = save & quit")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()
    if not sys.stdin.isatty():
        sys.exit("Run this in a Terminal tab; it reads single keypresses.")
    with open(SHEET, newline="") as f:
        reader = csv.DictReader(f)
        fields = reader.fieldnames
        rows = list(reader)
    order = {}
    if os.path.exists(KEY):
        for line in open(KEY):
            p = json.loads(line)
            order[p["pair_id"]] = PRIORITY.get(p.get("stratum"), 9)
    queue = [r for r in rows if args.all or not (r[LABEL_COL] or "").strip()]
    queue.sort(key=lambda r: (order.get(r["pair_id"], 9), r["pair_id"]))
    i = 0
    while 0 <= i < len(queue):
        done = sum(bool((r[LABEL_COL] or "").strip()) for r in rows)
        show(queue[i], done, len(rows))
        k = read_key().lower()
        if k in ("y", "n", "?"):
            queue[i][LABEL_COL] = k
            save(rows, fields)
            i += 1
        elif k == "s":
            i += 1
        elif k == "b":
            i = max(0, i - 1)
        elif k in ("q", "\x03"):
            break
    save(rows, fields)
    done = sum(bool((r[LABEL_COL] or "").strip()) for r in rows)
    print(f"\nSaved. {done} of {len(rows)} pairs labeled. Score with: python3 -I eval/score.py")


if __name__ == "__main__":
    main()
