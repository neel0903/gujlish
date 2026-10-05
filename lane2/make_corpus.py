"""
Clean Gujlish sentence corpus for Lane 2.

Three sources, no internet:
  1. templates.txt (hand-written chat sentences) with slot filling
  2. random walks over the seed BIGRAMS in seed_lexicon.py
  3. random walks over lexicon.bigrams.tsv (the real corpus bigrams),
     restricted to common words, so the model meets a wide vocabulary
     it must learn to leave alone

Split 90/5/5 by *group* (template id, or the chain's first word), so
the test set holds sentence shapes the model never saw.

Swapping in a real clean corpus later: add it in `sources()`.
"""
import argparse
import hashlib
import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
from seed_lexicon import BIGRAMS  # noqa: E402

SLOTS = {
    "person": ["bhai", "ben", "mummy", "pappa", "kaka", "kaki", "mama",
               "mami", "dada", "dadi", "dost", "foi", "nani", "nana"],
    "place": ["ghare", "office", "bajar", "school", "mandir", "hospital",
              "station", "gam", "bahar", "dukan"],
    "time": ["aaje", "kale", "have", "pachhi", "savare", "sanje", "ratre",
             "bapore", "hamna", "roj"],
    "food": ["rotli", "shaak", "dal", "bhat", "khichdi", "thepla", "dhokla",
             "cha", "nasto", "jalebi"],
    "num": ["ek", "be", "tran", "char", "panch", "chha", "sat", "aath",
            "nav", "das"],
    "thing": ["phone", "message", "photo", "gadi", "paisa", "bill",
              "ticket", "chavi", "bag", "book"],
}

SLOT_RE = re.compile(r"\{(\w+)\}")


def load_lexicon():
    freq = {}
    with open(os.path.join(ROOT, "lexicon.tsv"), encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0]:
                freq[parts[0]] = int(parts[1])
    return freq


def expand_templates(path):
    """-> list of (group, sentence)."""
    out = []
    with open(path, encoding="utf-8") as f:
        for ti, line in enumerate(f):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            slots = SLOT_RE.findall(line)
            group = f"t{ti}"
            if not slots:
                out.append((group, line))
                continue
            combos = [[]]
            for s in slots:
                combos = [c + [v] for c in combos for v in SLOTS[s]]
            for c in combos:
                sent = line
                for s, v in zip(slots, c):
                    sent = sent.replace("{" + s + "}", v, 1)
                out.append((group, sent))
    return out


def walk(bigrams, rng, n, minlen=2, maxlen=5, prefix="s"):
    """Random walks over a weighted bigram table -> (group, sentence)."""
    nxt = {}
    for a, b, w in bigrams:
        nxt.setdefault(a, []).append((b, w))
    starts = sorted(nxt)
    start_w = [sum(w for _, w in nxt[a]) for a in starts]
    out, seen = [], set()
    tries = 0
    while len(out) < n and tries < n * 20:
        tries += 1
        w = rng.choices(starts, start_w)[0]
        words = [w]
        target = rng.randint(minlen, maxlen)
        while len(words) < target and words[-1] in nxt:
            cands = nxt[words[-1]]
            words.append(rng.choices([c for c, _ in cands], [x for _, x in cands])[0])
        if len(words) < minlen:
            continue
        sent = " ".join(words)
        if sent in seen:
            continue
        seen.add(sent)
        out.append((f"{prefix}:{words[0]}", sent))
    return out


def load_real_bigrams(freq, min_freq):
    out = []
    with open(os.path.join(ROOT, "lexicon.bigrams.tsv"), encoding="utf-8") as f:
        for line in f:
            a, b, w = line.rstrip("\n").split("\t")
            if freq.get(a, 0) >= min_freq and freq.get(b, 0) >= min_freq:
                out.append((a, b, int(w)))
    return out


def split_name(group, train=90, dev=5):
    h = int(hashlib.md5(group.encode()).hexdigest(), 16) % 100
    return "train" if h < train else ("dev" if h < train + dev else "test")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--seed-chains", type=int, default=3000)
    ap.add_argument("--lex-chains", type=int, default=14000)
    ap.add_argument("--lex-min-freq", type=int, default=45)
    ap.add_argument("--out", default=os.path.join(HERE, "data"))
    args = ap.parse_args()
    rng = random.Random(args.seed)
    freq = load_lexicon()

    rows = expand_templates(os.path.join(HERE, "templates.txt"))
    n_templates = len(rows)
    unknown = sorted({w for _, s in rows for w in s.split() if w not in freq})
    if unknown:
        print("templates.txt words not in lexicon.tsv:", " ".join(unknown))
    rows += walk(BIGRAMS, rng, args.seed_chains, prefix="s")
    n_seed = len(rows) - n_templates
    rows += walk(load_real_bigrams(freq, args.lex_min_freq), rng,
                 args.lex_chains, prefix="l")
    n_lex = len(rows) - n_templates - n_seed

    # dedupe on the sentence; the first group wins
    seen, uniq = set(), []
    for g, s in rows:
        s = " ".join(s.lower().split())
        if s in seen or not s or len(s) > 64:
            continue
        seen.add(s)
        uniq.append((g, s))
    rng.shuffle(uniq)

    os.makedirs(args.out, exist_ok=True)
    counts = {"train": 0, "dev": 0, "test": 0}
    files = {k: open(os.path.join(args.out, f"clean_{k}.jsonl"), "w") for k in counts}
    for g, s in uniq:
        k = split_name(g)
        files[k].write(json.dumps({"text": s, "group": g}) + "\n")
        counts[k] += 1
    for f in files.values():
        f.close()
    print(f"templates {n_templates}  seed chains {n_seed}  lexicon chains {n_lex}  "
          f"unique {len(uniq)}  -> {counts}")


if __name__ == "__main__":
    main()
