"""
Word-level confidence gate shared by correct.py, eval.py and (ported)
web/index.html. The model only knows the words it was trained on, so a
change is accepted only when all of these hold:

  1. every output word is in the accepted vocabulary: the training
     corpus vocabulary plus lexicon words with freq >= 40
  2. the change is phonetically plausible: loose keys within one edit
     (transposition counts as one), or the raw spellings within two
  3. the input word is not a mid-sentence Capitalised word (a name)
  4. the input word is not an English word that outranks its Gujlish
     reading, unless the change is a pure spelling normalisation
     (same loose key: "sun" -> "su" is allowed, "john" -> "jo" is not)

Word count may differ (dropped spaces): unequal blocks are accepted
when every output word is accepted and the joined loose keys are
within two edits.  A 40% whole-segment edit-distance cap backstops it.
"""
import difflib
import json
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
from phonetics import loose_key  # noqa: E402

SEGMENT_CAP = 0.40
LEX_MIN_FREQ = 40


def osa(a, b):
    """Optimal string alignment distance (adjacent transposition = 1)."""
    n, m = len(a), len(b)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = a[i - 1] != b[j - 1]
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[n][m]


def build_vocab(db_path=os.path.join(ROOT, "gujlish.db"), data=os.path.join(HERE, "data")):
    """-> (accepted output words, english words to keep). Cached as JSON."""
    cache = os.path.join(HERE, "models", "gate_vocab.json")
    if os.path.exists(cache):
        d = json.load(open(cache))
        return set(d["ok"]), set(d["keep"])
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    gfreq = {s: f for s, f in conn.execute("SELECT surface, freq FROM words")}
    ok = {s for s, f in gfreq.items() if f >= LEX_MIN_FREQ}
    for split in ("train", "dev", "test"):
        p = os.path.join(data, f"clean_{split}.jsonl")
        if os.path.exists(p):
            for line in open(p):
                ok.update(json.loads(line)["text"].split())
    keep = {w for w, f in conn.execute("SELECT word, freq FROM english")
            if len(w) >= 3 and f > gfreq.get(w, 0)}
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    json.dump({"ok": sorted(ok), "keep": sorted(keep)}, open(cache, "w"))
    return ok, keep


class Gate:
    def __init__(self, ok=None, keep=None):
        if ok is None:
            ok, keep = build_vocab()
        self.ok, self.keep = ok, keep

    def plausible(self, src, out):
        ks, ko = loose_key(src), loose_key(out)
        return osa(ks, ko) <= 1 or osa(src, out) <= 2

    def word_ok(self, src, out, initial):
        """src/out are lowercase; src_raw's capitalisation passed via `initial`."""
        if src == out:
            return True
        if out not in self.ok:
            return False
        if not self.plausible(src, out):
            return False
        if src in self.keep and loose_key(src) != loose_key(out):
            return False
        return True

    def apply(self, src_raw, out):
        """src_raw keeps the user's capitalisation; out is the model's
        lowercase output. Returns the gated lowercase segment."""
        src = src_raw.lower()
        if not out:
            return src
        sw, ow, rw = src.split(), out.split(), src_raw.split()
        if not sw or not ow:
            return src
        res = []
        sm = difflib.SequenceMatcher(a=sw, b=ow, autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            s_blk, o_blk = sw[i1:i2], ow[j1:j2]
            if tag == "equal":
                res += s_blk
                continue
            if tag == "replace" and len(s_blk) == len(o_blk):
                for k, (s, o) in enumerate(zip(s_blk, o_blk)):
                    raw = rw[i1 + k]
                    named = raw[:1].isupper() and (i1 + k) > 0
                    res.append(o if not named and self.word_ok(s, o, i1 + k == 0) else s)
                continue
            # unequal block (space dropped or inserted)
            if (o_blk and all(o in self.ok for o in o_blk)
                    and not any(rw[i][:1].isupper() for i in range(max(i1, 1), i2))
                    and not any(s in self.keep for s in s_blk)
                    and osa(loose_key("".join(s_blk)), loose_key("".join(o_blk))) <= 2):
                res += o_blk
            else:
                res += s_blk
        gated = " ".join(res)
        if osa(src, gated) > SEGMENT_CAP * max(1, len(src)):
            return src
        return gated


if __name__ == "__main__":
    g = Gate()
    print(len(g.ok), "accepted words,", len(g.keep), "english keep words")
    for s, o in [("kem cho majama su thyu", "kem cho majama su thayu"),
                 ("john ne kaho", "jo nemakaho"),
                 ("good night thanks", "gud nighat thani"),
                 ("kemcho majama", "kem cho majama"),
                 ("hu ghrejau chu", "hu ghare jau chu"),
                 ("sun thyu", "su thayu"),
                 ("Neel ne kaho", "nel ne kaho"),
                 ("tamne kabar nathee", "tamne khabar nathi")]:
        print(f"{s:<26} model {o:<26} -> {g.apply(s, o)}")
