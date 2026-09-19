"""
Gujlish phonetic normalisation.

The whole engine rests on one idea: romanised Gujarati has no standard
spelling. "chhe", "che" and "chey" are the same word. So we map every
surface form to a coarse phonetic key, index on the key, and display
the canonical surface form.

Two keys per word, because not all variation is equal:

  strict_key  keeps aspiration (th / dh / kh / gh / bh / jh / ph)
  loose_key   throws it away

People are nearly unanimous about writing "thayu" with the h, so
conflating th and t at the top level makes "tha" suggest "tame" ahead
of "thayu" -- wrong, and annoying. But some people do write "tayu", so
the loose key stays available as a scored-down fallback.

Prefix mode matters too. A whole word gets its trailing nasal stripped
("chhun" -> "cu") because nasalisation is written inconsistently. A
half-typed prefix must not: stripping the m from "jam" gives "ja" and
buries "jaman" under every word starting with ja-.

This is the reference implementation, ported to Swift for the keyboard.
Dependency-free and deliberately dull: no regex, no unicode tricks.
"""

# Aspirated consonants get a private uppercase symbol so later rules
# can't touch them and so the loose key can undo them in one pass.
_DIGRAPHS = [
    ("chh", "C"),
    ("ch", "C"),
    ("shh", "s"),
    ("sh", "s"),
    ("th", "T"),
    ("dh", "D"),
    ("kh", "K"),
    ("gh", "G"),
    ("ph", "F"),
    ("bh", "B"),
    ("jh", "J"),
    ("zh", "J"),
]

_SINGLES = {"z": "J", "w": "v", "q": "k", "f": "F"}

_VOWEL_RUNS = [
    ("aa", "a"), ("ee", "i"), ("ii", "i"),
    ("oo", "u"), ("uu", "u"), ("ei", "e"),
]

# strict symbol -> loose equivalent
_DEASPIRATE = {
    "T": "t", "D": "d", "K": "k", "G": "g",
    "F": "f", "B": "b", "J": "j", "C": "c",
}

VOWELS = set("aeiou")


def _core(word, prefix):
    w = "".join(c for c in word.lower() if c.isalpha())
    if not w:
        return ""

    w = w.replace("x", "ks")

    for src, dst in _DIGRAPHS:
        w = w.replace(src, dst)

    w = "".join(_SINGLES.get(c, c) for c in w)

    # y is a vowel everywhere but word-initially: thayu/thaiu, chey/che,
    # kay/kai all need to land together.
    if len(w) > 1:
        w = w[0] + w[1:].replace("y", "i")

    for _ in range(3):
        before = w
        for src, dst in _VOWEL_RUNS:
            w = w.replace(src, dst)
        if w == before:
            break

    # Doubled consonants: sachchu / sacchu / sachu. Compare
    # case-insensitively so c+C collapses to the aspirated form.
    out = []
    for c in w:
        if out and out[-1].lower() == c.lower() and c.lower() not in VOWELS:
            if c.isupper():
                out[-1] = c
            continue
        out.append(c)
    w = "".join(out)

    if not prefix:
        # Whole words only. Nasalisation and a trailing bare h carry no
        # information: chhu/chhun/chun, ha/haan/han.
        while len(w) > 2 and w[-1] in "nm" and w[-2] in VOWELS:
            w = w[:-1]
        while len(w) > 2 and w[-1] == "h":
            w = w[:-1]

    return w


def strict_key(word, prefix=False):
    """Phonetic key that preserves aspiration."""
    return _core(word, prefix)


def loose_key(word, prefix=False):
    """Phonetic key that also folds th->t, kh->k, chh->ch and so on."""
    w = _core(word, prefix)
    return "".join(_DEASPIRATE.get(c, c) for c in w)


if __name__ == "__main__":
    groups = [
        ["che", "chhe", "chey", "chhey"],
        ["chu", "chhu", "chhun", "chun"],
        ["thayu", "thayoo", "thaiu"],
        ["su", "shu", "shoo", "soo"],
        ["majama", "majaama"],
        ["nathi", "nathee"],
        ["jamva", "jamwa", "jamvaa"],
        ["khabar", "khabbar"],
        ["saru", "saaru", "sarun"],
        ["kai", "kay", "kaai"],
        ["ghare", "gharey"],
        ["sacchu", "sachu", "sachchu"],
        ["aavjo", "avjo"],
        ["tame", "tamey", "tamme"],
        ["dikro", "deekro"],
        ["paisa", "paysa", "paisaa"],
        ["fafda", "phaphda", "faphda"],
        ["jhaju", "zaju"],
    ]
    bad = 0
    for g in groups:
        keys = {strict_key(w) for w in g}
        if len(keys) != 1:
            bad += 1
        print(f"{'ok ' if len(keys) == 1 else 'BAD'} {g[0]:<10} -> {sorted(keys)}")
    print(f"\n{len(groups) - bad}/{len(groups)} variant groups collapse on the strict key")

    print("\nAspiration kept apart on strict, folded on loose:")
    for a, b in [("thayu", "tayu"), ("khabar", "kabar"), ("ghare", "gare")]:
        print(f"    {a}/{b}: strict {strict_key(a)}/{strict_key(b)}"
              f"   loose {loose_key(a)}/{loose_key(b)}")

    print("\nPrefix mode must not strip the trailing nasal:")
    for p in ["jam", "kem", "chhu", "tam"]:
        print(f"    {p!r}: word {strict_key(p)!r}  prefix {strict_key(p, True)!r}")
