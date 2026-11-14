#!/usr/bin/env python3
"""Step 4: score replay runs against the gold set.

Ground truth, two independent kinds:
  human   labeling_sheet.csv column "same_task (y/n/?)"  (y/n only; ? and blank skipped)
  actions pairs_key.jsonl action_label same/different   (from what Claude actually ran)

A setup predicts "same task" for a pair when both prompts landed in the same intent.
Prompts skipped by the local filter, ignored by Claude, or failed count as "not same".

Reports per setup and run: precision/recall/F1 (overall and per stratum), agreement
across the 3 runs, offers that would have fired (3 distinct sessions) and when,
latency p50/p95, errors/retries; plus a TF-IDF cosine baseline at several cutoffs.

Note: confidence cutoffs above 0.75 are simulated after the fact (matches below the
cutoff treated as "not same"); that ignores how a stricter cutoff would have changed
later state. Cutoffs below 0.75 need a rerun, because those matches were never recorded.

Run with:  python3 -I eval/score.py [--out report.md]
"""
import argparse
import collections
import csv
import glob
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sample_pairs as sp  # noqa: E402

EVAL_DIR = sp.EVAL_DIR
SETUPS = ["prompt", "reply", "title", "reply+title"]
CUTOFFS = [0.75, 0.80, 0.85, 0.90, 0.95]
OFFER_THRESHOLD = 5  # keep in sync with IntentStore.offerThreshold


def prf(pred, gold):
    tp = sum(p and g for p, g in zip(pred, gold))
    fp = sum(p and not g for p, g in zip(pred, gold))
    fn = sum(g and not p for p, g in zip(pred, gold))
    tn = sum(not p and not g for p, g in zip(pred, gold))
    prec = tp / (tp + fp) if tp + fp else float("nan")
    rec = tp / (tp + fn) if tp + fn else float("nan")
    f1 = 2 * prec * rec / (prec + rec) if tp and prec + rec else 0.0
    return {"n": len(gold), "tp": tp, "fp": fp, "fn": fn, "tn": tn,
            "precision": prec, "recall": rec, "f1": f1}


def fmt(x):
    return "n/a" if x != x else f"{x:.4f}"  # NaN check


def load_runs():
    runs = {}
    for path in sorted(glob.glob(os.path.join(EVAL_DIR, "replay", "*-run[0-9]*.jsonl"))):
        name = os.path.basename(path)[:-len(".jsonl")]
        setup, run = name.rsplit("-run", 1)
        if setup not in SETUPS or run == "0" or int(run) >= 100:  # 100+: targeted checks
            continue
        lines = [json.loads(l) for l in open(path) if l.strip()]
        runs[(setup, int(run))] = {l["id"]: l for l in lines}
    return runs


def load_gold():
    key = {p["pair_id"]: p for p in (json.loads(l) for l in open(os.path.join(EVAL_DIR, "pairs_key.jsonl")))}
    human = {}
    with open(os.path.join(EVAL_DIR, "labeling_sheet.csv"), newline="") as f:
        for row in csv.DictReader(f):
            v = (row.get("same_task (y/n/?)") or "").strip().lower()
            if v in ("y", "yes", "n", "no"):
                human[row["pair_id"]] = v.startswith("y")
    return key, human


def same_intent(lines, a, b, cutoff=0.75):
    la, lb = lines.get(a), lines.get(b)
    if not la or not lb:
        return None  # not reached yet (run still going)

    def intent(l):
        if l.get("kind") == "new":
            return l["intentID"]
        if l.get("kind") == "match" and (l.get("confidence") or 0) >= cutoff:
            return l["intentID"]
        return None

    ia, ib = intent(la), intent(lb)
    return ia is not None and ia == ib


def offers(lines, records):
    """Intents reaching OFFER_THRESHOLD distinct sessions, with the date that session was first seen."""
    sessions = collections.defaultdict(list)
    slug = {}
    for rid in sorted(lines, key=lambda i: (records[i]["ts"], i)):
        l = lines[rid]
        if l.get("kind") in ("new", "match") and l.get("intentID"):
            iid = l["intentID"]
            slug.setdefault(iid, l.get("slug"))
            s = records[rid]["session"]
            if s not in [x[0] for x in sessions[iid]]:
                sessions[iid].append((s, records[rid]["ts"]))
    out = []
    for iid, ss in sessions.items():
        if len(ss) >= OFFER_THRESHOLD:
            out.append((ss[OFFER_THRESHOLD - 1][1], slug[iid], len(ss), iid))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(EVAL_DIR, "report.md"))
    args = ap.parse_args()

    records = {r["id"]: r for r in (json.loads(l) for l in open(os.path.join(EVAL_DIR, "prompts.jsonl")))}
    key, human = load_gold()
    runs = load_runs()
    action = {pid: p["action_label"] == "same" for pid, p in key.items() if p["action_label"] in ("same", "different")}
    lines_out = []
    w = lines_out.append

    w("# Gooby skill-coach evaluation\n")
    w(f"Prompts: {len(records)}. Gold pairs: {len(key)}. Human labels (y/n): {len(human)}. "
      f"Action labels (same/different): {len(action)}.\n")
    if not human:
        w("**No human labels yet** — human-label metrics are skipped until labeling_sheet.csv is filled in.\n")

    # Progress
    w("## Run progress\n")
    w("| setup | run | prompts done | classified | skipped | errors | retried | intents |")
    w("|---|---|---|---|---|---|---|---|")
    for (setup, run), lines in sorted(runs.items()):
        vals = list(lines.values())
        cls = [l for l in vals if not l["skipped"]]
        intents = len({l["intentID"] for l in cls if l.get("kind") == "new"})
        w(f"| {setup} | {run} | {len(vals)}/{len(records)} | {len(cls)} | {len(vals) - len(cls)} | "
          f"{sum(l.get('kind') == 'error' for l in cls)} | {sum((l.get('attempts') or 1) > 1 for l in cls)} | {intents} |")
    w("")

    # Accuracy against each ground truth
    for truth_name, truth in (("human labels", human), ("action labels", action)):
        if not truth:
            continue
        w(f"## Pair accuracy vs {truth_name}\n")
        w("| setup | run | cutoff | pairs scored | precision | recall | F1 |")
        w("|---|---|---|---|---|---|---|")
        for (setup, run), lines in sorted(runs.items()):
            for cutoff in CUTOFFS:
                pred, gold = [], []
                for pid, g in truth.items():
                    p = same_intent(lines, key[pid]["a"], key[pid]["b"], cutoff)
                    if p is None:
                        continue
                    pred.append(p)
                    gold.append(g)
                if not gold:
                    continue
                m = prf(pred, gold)
                w(f"| {setup} | {run} | {cutoff:.2f} | {m['n']} | {fmt(m['precision'])} | {fmt(m['recall'])} | {fmt(m['f1'])} |")
        w("")
        w(f"### Per stratum (cutoff 0.75) vs {truth_name}\n")
        w("| setup | run | stratum | pairs | precision | recall | F1 |")
        w("|---|---|---|---|---|---|---|")
        for (setup, run), lines in sorted(runs.items()):
            by = collections.defaultdict(lambda: ([], []))
            for pid, g in truth.items():
                p = same_intent(lines, key[pid]["a"], key[pid]["b"])
                if p is None:
                    continue
                by[key[pid]["stratum"]][0].append(p)
                by[key[pid]["stratum"]][1].append(g)
            for stratum, (pred, gold) in sorted(by.items()):
                m = prf(pred, gold)
                w(f"| {setup} | {run} | {stratum} | {m['n']} | {fmt(m['precision'])} | {fmt(m['recall'])} | {fmt(m['f1'])} |")
        w("")

    # Agreement across runs of the same setup
    w("## Run-to-run agreement (same setup, all gold pairs reached by every run)\n")
    w("| setup | runs | pairs | all runs agree |")
    w("|---|---|---|---|")
    for setup in SETUPS:
        rs = [lines for (s, _), lines in sorted(runs.items()) if s == setup]
        if len(rs) < 2:
            continue
        agree = total = 0
        for p in key.values():
            preds = [same_intent(l, p["a"], p["b"]) for l in rs]
            if any(x is None for x in preds):
                continue
            total += 1
            agree += len(set(preds)) == 1
        if total:
            w(f"| {setup} | {len(rs)} | {total} | {agree}/{total} = {agree / total:.4f} |")
    w("")

    # Offers
    w(f"## Skills that would have been offered ({OFFER_THRESHOLD} distinct sessions)\n")
    import datetime as dt
    for (setup, run), lines in sorted(runs.items()):
        offs = offers(lines, records)
        w(f"**{setup} run {run}**: {len(offs)} offers")
        for ts, slug, n, _ in offs[:25]:
            w(f"- {dt.datetime.fromtimestamp(ts / 1000):%Y-%m-%d} `/gooby-{slug}` ({n} sessions by end)")
        if len(offs) > 25:
            w(f"- … {len(offs) - 25} more")
        w("")

    # Latency
    w("## Latency and prompt size per classified prompt\n")
    w("| setup | run | calls | p50 s | p95 s | max s | mean context chars | max known intents |")
    w("|---|---|---|---|---|---|---|---|")
    for (setup, run), lines in sorted(runs.items()):
        cls = [l for l in lines.values() if not l["skipped"] and l.get("seconds") is not None]
        if not cls:
            continue
        secs = sorted(l["seconds"] for l in cls)
        p = lambda q: secs[min(len(secs) - 1, int(q * len(secs)))]  # noqa: E731
        ctx = statistics.mean(l.get("contextChars") or 0 for l in cls)
        w(f"| {setup} | {run} | {len(cls)} | {p(0.5):.2f} | {p(0.95):.2f} | {secs[-1]:.2f} | {ctx:.1f} | "
          f"{max(l.get('knownIntents') or 0 for l in cls)} |")
    w("")

    # TF-IDF baseline
    w("## Baseline: TF-IDF cosine (no model)\n")
    pool = list(records.values())
    vecs = dict(zip((r["id"] for r in pool), sp.tfidf(pool)))
    w("| truth | cutoff | pairs | precision | recall | F1 |")
    w("|---|---|---|---|---|---|")
    for truth_name, truth in (("human", human), ("actions", action)):
        if not truth:
            continue
        for cut in (0.2, 0.3, 0.4, 0.5, 0.6, 0.7):
            pred = [sp.cosine(vecs[key[pid]["a"]], vecs[key[pid]["b"]]) >= cut for pid in truth]
            m = prf(pred, list(truth.values()))
            w(f"| {truth_name} | {cut:.1f} | {m['n']} | {fmt(m['precision'])} | {fmt(m['recall'])} | {fmt(m['f1'])} |")
    w("")

    report = "\n".join(lines_out) + "\n"
    with open(args.out, "w") as f:
        f.write(report)
    os.chmod(args.out, 0o600)
    print(report[:4000])
    print(f"(full report: {args.out})")


if __name__ == "__main__":
    main()
