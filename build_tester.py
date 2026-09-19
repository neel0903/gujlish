"""
Shared loaders for the web builds, plus the single-file Phase 2 tester.

    python build_tester.py          # -> tester.html (the old single-file tester)

build_site.py imports load() and expected() from here. expected() dumps
the Python engine's answers for the trial prompts, corrections and every
word's phonetic keys, so web/test_port.js can check that the JavaScript
is a faithful port.
"""
import json
import os

from phonetics import strict_key, loose_key
from engine import GujlishEngine
from compare_db import TRIALS

WEB = "web"
LEXICON = "lexicon.tsv"
BIGRAMS = "lexicon.bigrams.tsv"
TRIGRAMS = "lexicon.trigrams.tsv"


def load():
    """words sorted by freq desc; bigrams {prevIdx: [nextIdx, w, ...]};
    trigrams {"p2Idx p1Idx": [nextIdx, w, ...]}."""
    words = []
    with open(LEXICON, encoding="utf-8") as fh:
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 2:
                words.append((p[0], int(p[1])))
    # Frequency order is what makes the JS "LIMIT n" scans cheap; ties
    # in surface order so the build is deterministic.
    words.sort(key=lambda w: (-w[1], w[0]))
    index = {s: i for i, (s, _) in enumerate(words)}

    bigrams, n_bi = {}, 0
    with open(BIGRAMS, encoding="utf-8") as fh:
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) < 3 or p[0] not in index or p[1] not in index:
                continue
            bigrams.setdefault(index[p[0]], []).extend([index[p[1]], int(p[2])])
            n_bi += 1
    trigrams, n_tri = {}, 0
    if os.path.exists(TRIGRAMS):
        with open(TRIGRAMS, encoding="utf-8") as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) < 4 or any(x not in index for x in p[:3]):
                    continue
                trigrams.setdefault(f"{index[p[0]]} {index[p[1]]}", []).extend([index[p[2]], int(p[3])])
                n_tri += 1
    return words, bigrams, trigrams, n_bi, n_tri


def expected(words):
    """What the Python engine says, for the port test."""
    eng = GujlishEngine("gujlish.db")
    trials = []
    for t in TRIALS:
        typed, prev, prev2 = (tuple(t) + (None,))[:3]
        res = eng.suggest(typed, prev, prev2) if typed else eng.next_word(prev, prev2)
        trials.append({"typed": typed, "prev": prev, "prev2": prev2, "result": res})
    keys = [[s, strict_key(s, True), loose_key(s, True), strict_key(s), loose_key(s)]
            for s, _ in words]
    probes = ["thayu", "chhun", "jam", "kem", "Thayoo!", "x", "", "aa", "sacchu",
              "jamwa", "phaphda", "zaju", "kharekhar", "haan", "chhe"]
    probe_keys = [[p, strict_key(p, True), loose_key(p, True), strict_key(p), loose_key(p)]
                  for p in probes]
    corrections = []
    for typed, prev, prev2 in [("avi", None, None), ("gaye", "aavi", None), ("ghara", "gaya", "aavi"),
                               ("thayoo", None, None), ("gharey", None, None), ("chhe", None, None),
                               ("nathee", None, None), ("majaama", None, None), ("kem", None, None),
                               ("che", None, None), ("tamne", None, None), ("jsk", None, None),
                               ("karvu", None, None), ("bhulyo", None, None), ("pn", None, None),
                               ("kemcho", None, None), ("jamva", "chalo", None), ("thyu", "kem", None),
                               ("sarkr", None, None), ("gujrat", None, None), ("ghara", "gaya", None)]:
        corrections.append({"typed": typed, "prev": prev, "prev2": prev2,
                            "result": eng.correct(typed, prev, prev2)})
    return {"trials": trials, "keys": keys, "probeKeys": probe_keys, "corrections": corrections}


def main():
    words, bigrams, trigrams, n_bigrams, n_trigrams = load()
    data = {"words": [[s, f] for s, f in words], "bigrams": bigrams, "trigrams": trigrams,
            "bigramCount": n_bigrams, "trigramCount": n_trigrams}
    data_js = "var GUJLISH_DATA = " + json.dumps(data, separators=(",", ":"), ensure_ascii=True) + ";"
    with open(os.path.join(WEB, "gujlish.js"), encoding="utf-8") as fh:
        engine_js = fh.read()
    with open(os.path.join(WEB, "tester_template.html"), encoding="utf-8") as fh:
        html = fh.read()
    html = html.replace("/*__ENGINE__*/", engine_js).replace("/*__DATA__*/", data_js)
    with open("tester.html", "w", encoding="utf-8") as fh:
        fh.write(html)
    print(f"tester.html: {os.path.getsize('tester.html') / 1024:.0f} KB, "
          f"{len(words)} words, {n_bigrams} bigrams, {n_trigrams} trigrams")


if __name__ == "__main__":
    main()
