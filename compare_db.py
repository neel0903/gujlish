"""
Acceptance test for a rebuilt lexicon: the same prompts against the seed
DB and the corpus DB, side by side. Eyeball it.

    python3 compare_db.py                       # gujlish.seed.db vs gujlish.db
    python3 compare_db.py old.db new.db
"""
import sys

from engine import GujlishEngine

TRIALS = [
    # (typed, previous word). The engine.py harness plus the acceptance
    # phrases from BUILD_PLAN.md plus some breadth probes.
    ("che", None), ("ch", None), ("tha", None), ("thay", None),
    ("kem", None), ("cho", "kem"), ("", "kem"), ("", "su"),
    ("k", "su"), ("kar", "su"), ("nat", "khabar"), ("", "khabar"),
    ("maj", None), ("mjama", None), ("shu", None), ("chh", None),
    ("jam", None), ("", "thayu"), ("gh", None), ("tmne", None),
    # breadth: words the seed never had
    ("sarkar", None), ("vidya", None), ("bhar", None), ("gujar", None),
    ("amda", None), ("prat", None), ("mahi", None), ("lok", None),
    ("sam", None), ("pra", None), ("", "bharat"), ("", "gujarat"),
    ("", "ane"), ("", "ek"),
]


def run(db_path):
    eng = GujlishEngine(db_path)
    out = []
    for typed, prev in TRIALS:
        res = eng.suggest(typed, prev) if typed else eng.next_word(prev)
        out.append(", ".join(res) or "(nothing)")
    return out


if __name__ == "__main__":
    old = sys.argv[1] if len(sys.argv) > 1 else "gujlish.seed.db"
    new = sys.argv[2] if len(sys.argv) > 2 else "gujlish.db"
    a, b = run(old), run(new)
    width = max(len(x) for x in a) + 2
    print(f"{'input':<18}{old:<{width}}{new}")
    for (typed, prev), x, y in zip(TRIALS, a, b):
        ctx = f"[{prev}] " if prev else ""
        label = f"{ctx}{typed!r}"
        print(f"{label:<18}{x:<{width}}{y}")
