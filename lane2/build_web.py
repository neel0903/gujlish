"""
Build web/index.html from web/index.template.html: inlines a compact
lexicon (top words by frequency with their phonetic keys, and the
bigrams among them) for the Lane 1 strip, and copies the int8 ONNX
graphs + vocab.json into web/model/.

    python3 build_web.py [--min-freq 40]
"""
import argparse
import json
import os
import shutil
import sqlite3

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-freq", type=int, default=40)
    ap.add_argument("--min-bigram", type=int, default=20)
    ap.add_argument("--docs", action="store_true",
                    help="also copy the finished page into ../docs/fix/ for GitHub Pages (https, offline)")
    args = ap.parse_args()

    conn = sqlite3.connect(os.path.join(ROOT, "gujlish.db"))
    words = conn.execute(
        "SELECT id, surface, strict_k, loose_k, freq FROM words WHERE freq >= ? "
        "ORDER BY freq DESC, surface", (args.min_freq,)).fetchall()
    ids = {r[0]: i for i, r in enumerate(words)}
    bigrams = []
    for p, n, w in conn.execute("SELECT prev_id, next_id, weight FROM bigrams WHERE weight >= ?",
                                (args.min_bigram,)):
        if p in ids and n in ids:
            bigrams.append([ids[p], ids[n], w])
    lex = {"w": [[r[1], r[2], r[3], r[4]] for r in words], "b": bigrams}
    blob = json.dumps(lex, separators=(",", ":"))

    web = os.path.join(HERE, "web")
    tpl = open(os.path.join(web, "index.template.html"), encoding="utf-8").read()
    html = tpl.replace("__LEXICON_JSON__", blob)
    gv = os.path.join(HERE, "models", "gate_vocab.json")
    if not os.path.exists(gv):
        import subprocess
        subprocess.run([os.environ.get("PYTHON", "python3"), os.path.join(HERE, "gate.py")],
                       check=True, capture_output=True)
    gate = json.load(open(gv))
    html = html.replace("__GATE_JSON__", json.dumps(gate, separators=(",", ":")))
    open(os.path.join(web, "index.html"), "w", encoding="utf-8").write(html)

    mdir = os.path.join(web, "model")
    os.makedirs(mdir, exist_ok=True)
    copied = []
    for name in ("encoder_int8.onnx", "decoder_int8.onnx", "vocab.json"):
        src = os.path.join(HERE, "models", name)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(mdir, name))
            copied.append(name)
    print(f"index.html: {len(words)} words, {len(bigrams)} bigrams, "
          f"{len(html)/1e6:.2f} MB; model files copied: {copied or 'none yet'}")

    if args.docs:
        # The hosted copy: docs/ is what GitHub Pages serves, so this lands at
        # https://neel0903.github.io/gujlish/fix/ next to the main PWA, with
        # its own service worker (scope /gujlish/fix/).
        docs = os.path.join(ROOT, "docs", "fix")
        if os.path.isdir(docs):
            shutil.rmtree(docs)
        shutil.copytree(web, docs, ignore=shutil.ignore_patterns("index.template.html"))
        print(f"docs/fix: {sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(docs) for f in fs)/1e6:.2f} MB")


if __name__ == "__main__":
    main()
