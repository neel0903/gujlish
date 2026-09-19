"""
Phase 2: build the self-contained web tester.

    python build_tester.py          # -> tester.html (+ web/lexicon.js, web/expected.json)
    node web/test_port.js           # JS port vs the Python engine

tester.html is one file: template + engine port + lexicon inlined as
JSON. Copy it to the phone (AirDrop, Drive, or serve this folder with
`python -m http.server` and open http://<this machine>:8000/tester.html)
and add it to the home screen.

Also writes web/expected.json — the Python engine's answers for the
trial prompts plus every word's phonetic keys — so test_port.js can
check that the JavaScript is a faithful port.
"""
import json
import os

from phonetics import strict_key, loose_key
from engine import GujlishEngine
from compare_db import TRIALS

WEB = "web"
LEXICON = "lexicon.tsv"
BIGRAMS = "lexicon.bigrams.tsv"


def load():
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

    bigrams = {}
    n = 0
    with open(BIGRAMS, encoding="utf-8") as fh:
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) < 3 or p[0] not in index or p[1] not in index:
                continue
            bigrams.setdefault(index[p[0]], []).extend([index[p[1]], int(p[2])])
            n += 1
    return words, bigrams, n


def expected(words):
    """What the Python engine says, for the port test."""
    eng = GujlishEngine("gujlish.db")
    trials = []
    for typed, prev in TRIALS:
        res = eng.suggest(typed, prev) if typed else eng.next_word(prev)
        trials.append({"typed": typed, "prev": prev, "result": res})
    keys = [[s, strict_key(s, True), loose_key(s, True), strict_key(s), loose_key(s)]
            for s, _ in words]
    probes = ["thayu", "chhun", "jam", "kem", "Thayoo!", "x", "", "aa", "sacchu",
              "jamwa", "phaphda", "zaju", "kharekhar", "haan", "chhe"]
    probe_keys = [[p, strict_key(p, True), loose_key(p, True), strict_key(p), loose_key(p)]
                  for p in probes]
    return {"trials": trials, "keys": keys, "probeKeys": probe_keys}


def main():
    words, bigrams, n_bigrams = load()
    data = {"words": [[s, f] for s, f in words], "bigrams": bigrams, "bigramCount": n_bigrams}
    data_js = "var GUJLISH_DATA = " + json.dumps(data, separators=(",", ":"), ensure_ascii=True) + ";"
    with open(os.path.join(WEB, "lexicon.js"), "w", encoding="utf-8") as fh:
        fh.write(data_js + "\n")

    with open(os.path.join(WEB, "gujlish.js"), encoding="utf-8") as fh:
        engine_js = fh.read()
    with open(os.path.join(WEB, "tester_template.html"), encoding="utf-8") as fh:
        html = fh.read()
    html = html.replace("/*__ENGINE__*/", engine_js).replace("/*__DATA__*/", data_js)
    with open("tester.html", "w", encoding="utf-8") as fh:
        fh.write(html)

    with open(os.path.join(WEB, "expected.json"), "w", encoding="utf-8") as fh:
        json.dump(expected(words), fh, ensure_ascii=False)

    print(f"tester.html: {os.path.getsize('tester.html') / 1024:.0f} KB, "
          f"{len(words)} words, {n_bigrams} bigrams")


if __name__ == "__main__":
    main()
