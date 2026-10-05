"""
Sentence accuracy and character error rate on data/pairs_test.jsonl for:
  identity   - leave the input alone (what "no corrector" scores)
  baseline   - lexicon-only, suggest top-1 on key match
  autocorrect- the keyboard's engine.correct() per word
  model      - the trained corrector (with the confidence gate)

    python3 eval.py [--limit N] [--model models/gujlish_corrector.pt]
"""
import argparse
import json
import os
import random
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from baseline import Baseline  # noqa: E402
from train import cer, load_pairs  # noqa: E402


def score(name, hyps, refs, secs):
    acc = sum(h == r for h, r in zip(hyps, refs)) / len(refs)
    print(f"{name:<12} sent-acc {acc:6.1%}   CER {cer(hyps, refs):.4f}   "
          f"{secs*1000/len(refs):6.1f} ms/sent")
    return acc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=1500)
    ap.add_argument("--model", default=os.path.join(HERE, "models", "gujlish_corrector.pt"))
    ap.add_argument("--no-model", action="store_true")
    ap.add_argument("--show", type=int, default=12, help="print N model mistakes")
    args = ap.parse_args()

    pairs = load_pairs(os.path.join(HERE, "data", "pairs_test.jsonl"))
    random.Random(0).shuffle(pairs)
    pairs = pairs[:args.limit]
    srcs, refs = [s for s, _ in pairs], [t for _, t in pairs]
    print(f"test pairs: {len(pairs)}")

    score("identity", srcs, refs, 0)
    for mode in ("suggest", "correct"):
        b = Baseline(mode=mode)
        t = time.time()
        hyps = [b.fix(s) for s in srcs]
        score("baseline" if mode == "suggest" else "autocorrect", hyps, refs, time.time() - t)

    if args.no_model or not os.path.exists(args.model):
        print("(no model)")
        return
    from correct import Corrector
    c = Corrector(path=args.model, backend="torch", gate=True)
    t = time.time()
    hyps = c.fix_batch(srcs)
    score("model", hyps, refs, time.time() - t)
    c.gate = None
    t = time.time()
    raw = c.fix_batch(srcs)
    score("model-nogate", raw, refs, time.time() - t)
    c.gate = __import__("gate").Gate()
    default_model = os.path.join(HERE, "models", "gujlish_corrector.pt")
    if args.model == default_model and os.path.exists(os.path.join(HERE, "models", "encoder_int8.onnx")):
        co = Corrector(backend="ort", gate=True)
        n = min(200, len(srcs))
        t = time.time()
        oh = co.fix_batch(srcs[:n])
        score("onnx-int8", oh, refs[:n], time.time() - t)

    shown = 0
    for s, h, r in zip(srcs, hyps, refs):
        if h != r and shown < args.show:
            print(f"   src {s}\n   out {h}\n   ref {r}\n")
            shown += 1

    # real messages: golden.tsv inputs include grammar slips the corruptor
    # never makes, so this is a reality check, not a training target
    gold = []
    with open(os.path.join(os.path.dirname(HERE), "web", "golden.tsv")) as f:
        for line in f:
            if line.startswith("#") or "\t" not in line:
                continue
            a, b = line.rstrip("\n").split("\t")[:2]
            gold.append((a, b))
    print(f"\ngolden.tsv ({len(gold)} real messages; expected includes grammar fixes):")
    hyps = [c.fix(a) for a, _ in gold]
    score("model", hyps, [b for _, b in gold], 0)
    for (a, b), h in zip(gold, hyps):
        flag = "  " if h == b else "* "
        print(f"  {flag}{a:<34} -> {h}")


if __name__ == "__main__":
    main()
