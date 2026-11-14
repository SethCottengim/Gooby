#!/usr/bin/env python3
"""Debug helper: show the shell commands that produce a given signature entry.

Run with:  python3 -I eval/debug_signature.py api [--limit 5]
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("entry")
ap.add_argument("--limit", type=int, default=5)
args = ap.parse_args()

shown = 0
for line in open(os.path.join(extract.OUT_DIR, "prompts.jsonl")):
    r = json.loads(line)
    for t in r["tools"]:
        if t.startswith("Bash: ") and args.entry in extract.signature([t]):
            print(repr(t[:160]))
            print("   ->", extract.signature([t]))
            shown += 1
            if shown >= args.limit:
                sys.exit(0)
