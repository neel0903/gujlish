"""
Build gujlish.db from a lexicon source.

This produces the exact file the iOS keyboard will bundle and open
read-only. Keep the schema stable — the Swift port will depend on it.

  python3 build_db.py            # from the hand-built seed lexicon
  python3 build_db.py corpus.tsv # from build_lexicon.py output
"""
import sqlite3
import sys
import os

from phonetics import strict_key, loose_key

SCHEMA = """
DROP TABLE IF EXISTS words;
DROP TABLE IF EXISTS bigrams;

CREATE TABLE words (
    id       INTEGER PRIMARY KEY,
    surface   TEXT NOT NULL,
    strict_k  TEXT NOT NULL,
    loose_k   TEXT NOT NULL,
    freq      INTEGER NOT NULL,
    native    TEXT              -- Gujarati-script form, for script mode
);

-- English words for mixed mode, same 1..100 log scale as freq.
DROP TABLE IF EXISTS english;
CREATE TABLE english (
    word  TEXT PRIMARY KEY,
    freq  INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE bigrams (
    prev_id INTEGER NOT NULL,
    next_id INTEGER NOT NULL,
    weight  INTEGER NOT NULL,
    PRIMARY KEY (prev_id, next_id)
) WITHOUT ROWID;

DROP TABLE IF EXISTS trigrams;
CREATE TABLE trigrams (
    prev2_id INTEGER NOT NULL,
    prev1_id INTEGER NOT NULL,
    next_id  INTEGER NOT NULL,
    weight   INTEGER NOT NULL,
    PRIMARY KEY (prev2_id, prev1_id, next_id)
) WITHOUT ROWID;

-- The only index that matters for typing latency.
CREATE INDEX idx_words_strict ON words(strict_k, freq DESC);
CREATE INDEX idx_words_loose ON words(loose_k, freq DESC);
CREATE INDEX idx_words_surface ON words(surface);
-- For the autocorrect scan over words one letter away.
CREATE INDEX idx_words_len ON words(LENGTH(surface));
CREATE INDEX idx_english_freq ON english(freq DESC);
"""

ENGLISH_TSV = "english.tsv"


def load_native(path):
    """surface<TAB>native beside the lexicon, if present."""
    out = {}
    native_path = os.path.splitext(path)[0] + ".native.tsv"
    if os.path.exists(native_path):
        with open(native_path, encoding="utf-8") as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) == 2:
                    out[p[0]] = p[1]
    return out


def load_english():
    """word<TAB>freq, committed at the repo root so the DB rebuilds
    without the corpus download."""
    out = []
    if os.path.exists(ENGLISH_TSV):
        with open(ENGLISH_TSV, encoding="utf-8") as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) == 2:
                    out.append((p[0], int(p[1])))
    return out


def load_seed():
    from seed_lexicon import WORDS, BIGRAMS
    words = {}
    for surface, freq, _gloss in WORDS:
        # Later duplicates win only if more frequent.
        if surface not in words or freq > words[surface]:
            words[surface] = freq
    return words, BIGRAMS, []


def load_tsv(path):
    """surface<TAB>freq per line, from build_lexicon.py, plus the
    .bigrams.tsv and .trigrams.tsv beside it."""
    words = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            words[parts[0]] = int(parts[1])
    stem = os.path.splitext(path)[0]
    bigrams, trigrams = [], []
    if os.path.exists(stem + ".bigrams.tsv"):
        with open(stem + ".bigrams.tsv", encoding="utf-8") as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 3:
                    bigrams.append((p[0], p[1], int(p[2])))
    if os.path.exists(stem + ".trigrams.tsv"):
        with open(stem + ".trigrams.tsv", encoding="utf-8") as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 4:
                    trigrams.append((p[0], p[1], p[2], int(p[3])))
    return words, bigrams, trigrams


def build(out_path="gujlish.db", source=None):
    words, bigrams, trigrams = load_tsv(source) if source else load_seed()

    conn = sqlite3.connect(out_path)
    conn.executescript(SCHEMA)

    native = load_native(source) if source else {}
    ids = {}
    rows = []
    for i, (surface, freq) in enumerate(sorted(words.items()), start=1):
        ids[surface] = i
        rows.append((i, surface, strict_key(surface, prefix=True),
                     loose_key(surface, prefix=True), freq, native.get(surface)))
    conn.executemany("INSERT INTO words VALUES (?,?,?,?,?,?)", rows)
    english = load_english()
    conn.executemany("INSERT OR REPLACE INTO english VALUES (?,?)", english)

    bg = []
    dropped = 0
    for prev, nxt, weight in bigrams:
        if prev in ids and nxt in ids:
            bg.append((ids[prev], ids[nxt], weight))
        else:
            dropped += 1
    conn.executemany(
        "INSERT OR REPLACE INTO bigrams VALUES (?,?,?)", bg
    )
    tg = [(ids[a], ids[b], ids[c], w) for a, b, c, w in trigrams
          if a in ids and b in ids and c in ids]
    conn.executemany("INSERT OR REPLACE INTO trigrams VALUES (?,?,?,?)", tg)

    conn.commit()
    conn.execute("VACUUM")
    conn.close()

    size_kb = os.path.getsize(out_path) / 1024
    print(f"{out_path}: {len(rows)} words ({sum(1 for r in rows if r[5])} with script), "
          f"{len(bg)} bigrams, {len(tg)} trigrams, {len(english)} English, {size_kb:.0f} KB")
    if dropped:
        print(f"  {dropped} bigrams dropped (word not in lexicon)")

    keys = {}
    for _, surface, key, _lk, _f, _n in rows:
        keys.setdefault(key, []).append(surface)
    collisions = {k: v for k, v in keys.items() if len(v) > 1}
    print(f"  {len(collisions)} phonetic keys carry more than one word")
    for k, v in sorted(collisions.items(), key=lambda x: -len(x[1]))[:8]:
        print(f"    {k}: {', '.join(v)}")


if __name__ == "__main__":
    build(source=sys.argv[1] if len(sys.argv) > 1 else None)
