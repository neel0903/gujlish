"""
Lexicon-only corrector: the number the model has to beat, and the
fallback the web page uses when the model fails to load.

Two flavours:
  suggest  - per word, top-1 of GujlishEngine.suggest(word, prev) if its
             loose phonetic key equals the typed word's, else keep
  correct  - per word, GujlishEngine.correct(word, prev, prev2), which is
             what the keyboard's autocorrect-on-space actually does
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
from engine import GujlishEngine  # noqa: E402
from phonetics import loose_key  # noqa: E402


class Baseline:
    def __init__(self, db_path=os.path.join(ROOT, "gujlish.db"), mode="suggest"):
        self.eng = GujlishEngine(db_path)
        self.mode = mode

    def fix_word(self, word, prev=None, prev2=None):
        if self.mode == "correct":
            return self.eng.correct(word, prev, prev2) or word
        cands = self.eng.suggest(word, prev)
        if cands and loose_key(cands[0]) == loose_key(word):
            return cands[0]
        return word

    def fix(self, text):
        out, prev, prev2 = [], None, None
        for w in text.split():
            f = self.fix_word(w, prev, prev2)
            out.append(f)
            prev2, prev = prev, f
        return " ".join(out)


if __name__ == "__main__":
    text = " ".join(sys.argv[1:]) or "kem cho majama su thyu"
    for mode in ("suggest", "correct"):
        print(f"{mode:<8} {Baseline(mode=mode).fix(text)}")
