"""
Synthetic corruption: run the phonetic variation backwards.

Takes clean Gujlish sentences and mistypes them the way people do, so
the model can learn to undo it. Operators and probabilities are the
table in BUILD_PLAN_v2.md; the digraph and vowel-run inventories come
from phonetics.py so the two never drift apart.

    python3 corrupt.py --demo             # eyeball 20 pairs
    python3 corrupt.py --seed 1 --per 5   # data/pairs_{train,dev,test}.jsonl
"""
import argparse
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from phonetics import _DIGRAPHS, _VOWEL_RUNS, VOWELS  # noqa: E402

# Aspirated digraphs whose h people drop: th dh kh gh ph bh jh zh.
# "ch"/"sh" are excluded: nobody writes "ce" for "che".
ASPIRATED = [s for s, _ in _DIGRAPHS
             if len(s) == 2 and s.endswith("h") and s not in ("ch", "sh")]
DIGRAPHS_ALL = [s for s, _ in _DIGRAPHS]
# single vowel -> long spelling(s) people use, from the vowel-run table
# Only the long spellings people actually use: saaru, nathee, saroo.
# ("ii", "uu", "ei" are folded by phonetics but nobody types them.)
LENGTHEN = {single: [run] for run, single in _VOWEL_RUNS
            if run in ("aa", "ee", "oo")}
SHORTEN = {run: single for run, single in _VOWEL_RUNS}

QWERTY = {
    "q": "wa", "w": "qes", "e": "wrd", "r": "etf", "t": "ryg", "y": "tuh",
    "u": "yij", "i": "uok", "o": "ipl", "p": "ol", "a": "qsz", "s": "awdxz",
    "d": "serfcx", "f": "drtgvc", "g": "ftyhbv", "h": "gyujnb", "j": "huikmn",
    "k": "jiolm", "l": "kop", "z": "asx", "x": "zsdc", "c": "xdfv",
    "v": "cfgb", "b": "vghn", "n": "bhjm", "m": "njk",
}

# (name, probability) — the table from the brief
OPERATORS = [
    ("drop_h", 0.25),
    ("double_consonant", 0.10),
    ("schwa", 0.15),
    ("vowel_length", 0.25),
    ("y_i", 0.20),
    ("consonant_swap", 0.20),
    ("nasal", 0.15),
    ("keyboard", 0.08),
    ("transpose", 0.05),
    ("chh_ch", 0.30),
    ("final_ey", 0.10),      # ghare -> gharey, che -> chey (same phonetic key)
    ("final_vowel", 0.06),   # gaya -> gaye, ghare -> ghara: the matra slip at the end
]
P_UNTOUCHED = 0.30
P_DROP_SPACE = 0.08


def _is_vowel(c):
    return c in VOWELS


def _positions(w, sub):
    out, i = [], w.find(sub)
    while i != -1:
        out.append(i)
        i = w.find(sub, i + 1)
    return out


def _replace_at(w, i, old_len, new):
    return w[:i] + new + w[i + old_len:]


def op_drop_h(w, rng):
    hits = [(i, d) for d in ASPIRATED for i in _positions(w, d)]
    if not hits:
        return None
    i, d = rng.choice(hits)
    return _replace_at(w, i, 2, d[0])


def op_double_consonant(w, rng):
    idx = [i for i in range(1, len(w) - 1)
           if not _is_vowel(w[i]) and w[i] != "h" and w[i] != w[i - 1]
           and w[i] != w[i + 1] and _is_vowel(w[i - 1])]
    if not idx:
        return None
    i = rng.choice(idx)
    return w[:i] + w[i] + w[i:]


def _starts_digraph(w, i):
    return any(w.startswith(d, i) for d in DIGRAPHS_ALL)


def op_schwa(w, rng):
    if rng.random() < 0.55:
        # drop an inner "a" sitting between two consonants: majama -> mjama
        idx = [i for i in range(1, len(w) - 1) if w[i] == "a"
               and not _is_vowel(w[i - 1]) and not _is_vowel(w[i + 1])]
        if idx:
            i = rng.choice(idx)
            return w[:i] + w[i + 1:]
    # insert an "a" between two consonants that are not a digraph: dikro -> dikaro
    idx = [i for i in range(1, len(w) - 1)
           if not _is_vowel(w[i]) and not _is_vowel(w[i + 1])
           and w[i] != w[i + 1] and not _starts_digraph(w, i)]
    if not idx:
        return None
    i = rng.choice(idx)
    return w[:i + 1] + "a" + w[i + 1:]


def op_vowel_length(w, rng):
    opts = []
    for run in SHORTEN:
        for i in _positions(w, run):
            opts.append((i, len(run), SHORTEN[run]))
    for i, c in enumerate(w):
        if c in LENGTHEN and (i + 1 >= len(w) or not _is_vowel(w[i + 1])) \
                and (i == 0 or not _is_vowel(w[i - 1])):
            for run in LENGTHEN[c]:
                opts.append((i, 1, run))
    if not opts:
        return None
    i, n, new = rng.choice(opts)
    return _replace_at(w, i, n, new)


def op_y_i(w, rng):
    opts = []
    for i, c in enumerate(w):
        if c == "y" and i > 0:
            opts.append((i, "i"))
        elif c == "i" and i > 0 and (_is_vowel(w[i - 1]) or
                                     (i + 1 < len(w) and _is_vowel(w[i + 1]))):
            opts.append((i, "y"))
    if not opts:
        return None
    i, new = rng.choice(opts)
    return _replace_at(w, i, 1, new)


def op_consonant_swap(w, rng):
    opts = []
    for i, c in enumerate(w):
        if c == "v":
            opts.append((i, 1, "w"))
        elif c == "w":
            opts.append((i, 1, "v"))
        elif c == "j" and not (i > 0 and w[i - 1] == "h"):
            opts.append((i, 1, "z"))
        elif c == "z":
            opts.append((i, 1, "j"))
        elif c == "s" and not w.startswith("sh", i):
            opts.append((i, 1, "sh"))
        elif w.startswith("sh", i):
            opts.append((i, 2, "s"))
        elif w.startswith("ph", i):
            opts.append((i, 2, "f"))
        elif c == "f":
            opts.append((i, 1, "ph"))
    if not opts:
        return None
    i, n, new = rng.choice(opts)
    return _replace_at(w, i, n, new)


def op_nasal(w, rng):
    if len(w) < 2:
        return None
    if w[-1] in "nm" and _is_vowel(w[-2]):
        return w[:-1]
    if _is_vowel(w[-1]):
        return w + ("n" if rng.random() < 0.8 else "m")
    return None


def op_keyboard(w, rng):
    if len(w) < 4:
        return None
    i = rng.randrange(len(w))
    nb = QWERTY.get(w[i])
    if not nb:
        return None
    return _replace_at(w, i, 1, rng.choice(nb))


def op_transpose(w, rng):
    if len(w) < 4:
        return None
    i = rng.randrange(1, len(w) - 1)
    return w[:i] + w[i + 1] + w[i] + w[i + 2:]


def op_chh_ch(w, rng):
    if "chh" in w:
        i = rng.choice(_positions(w, "chh"))
        return _replace_at(w, i, 3, "ch")
    hits = _positions(w, "ch")
    if not hits:
        return None
    i = rng.choice(hits)
    return _replace_at(w, i, 2, "chh")


def op_final_ey(w, rng):
    if len(w) >= 3 and w.endswith("e") and not w.endswith("ee"):
        return w + "y"
    if w.endswith("ey"):
        return w[:-1]
    return None


def op_final_vowel(w, rng):
    if len(w) < 3:
        return None
    if w[-1] == "e" and w[-2] not in VOWELS:
        return w[:-1] + "a"
    if w[-1] == "a" and w[-2] not in VOWELS:
        return w[:-1] + "e"
    return None


OPS = {name: globals()["op_" + name] for name, _ in OPERATORS}
OP_NAMES = [n for n, _ in OPERATORS]
OP_WEIGHTS = [p for _, p in OPERATORS]


def corrupt_word(w, rng, max_ops=3):
    if len(w) < 2 or not w.isalpha() or rng.random() < P_UNTOUCHED:
        return w
    n_ops = rng.choices([1, 2, 3], [0.7, 0.25, 0.05])[0]
    n_ops = min(n_ops, max_ops)
    done, used = 0, set()
    for _ in range(8):
        if done >= n_ops:
            break
        name = rng.choices(OP_NAMES, OP_WEIGHTS)[0]
        if name in used:
            continue
        out = OPS[name](w, rng)
        if out and out != w:
            w = out
            done += 1
            used.add(name)
    return w


def corrupt(sentence, rng):
    words = [corrupt_word(w, rng) for w in sentence.split()]
    out = []
    for i, w in enumerate(words):
        if out and rng.random() < P_DROP_SPACE:
            out[-1] += w
        else:
            out.append(w)
    return " ".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--per", type=int, default=5, help="corruptions per sentence")
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--data", default=os.path.join(HERE, "data"))
    args = ap.parse_args()
    rng = random.Random(args.seed)

    if args.demo:
        demo = ["kem cho majama", "su thayu", "mane khabar nathi", "thayu che",
                "hu ghare jau chu", "jaman thayu", "kale malse", "ghare aavo",
                "su chale che", "sachu kahu chu", "tame kya cho", "dikro aavi gayo",
                "khabar nathi bhai", "thodu modu thase", "saru che", "jamva chalo",
                "mane bahu gamyu", "kaam puru thayu", "badhu thik che", "aaje varsad che"]
        for s in demo:
            print(f"{s:<24} -> {corrupt(s, rng)}")
        return

    for split in ("train", "dev", "test"):
        src = os.path.join(args.data, f"clean_{split}.jsonl")
        dst = os.path.join(args.data, f"pairs_{split}.jsonl")
        n = 0
        with open(src) as fi, open(dst, "w") as fo:
            for line in fi:
                clean = json.loads(line)["text"]
                seen = set()
                for _ in range(args.per):
                    messy = corrupt(clean, rng)
                    if messy in seen:
                        continue
                    seen.add(messy)
                    fo.write(json.dumps({"src": messy, "tgt": clean}) + "\n")
                    n += 1
        print(f"{split}: {n} pairs -> {dst}")


if __name__ == "__main__":
    main()
