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
    freq      INTEGER NOT NULL
);

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
"""


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

    ids = {}
    rows = []
    for i, (surface, freq) in enumerate(sorted(words.items()), start=1):
        ids[surface] = i
        rows.append((i, surface, strict_key(surface, prefix=True),
                     loose_key(surface, prefix=True), freq))
    conn.executemany("INSERT INTO words VALUES (?,?,?,?,?)", rows)

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
    print(f"{out_path}: {len(rows)} words, {len(bg)} bigrams, {len(tg)} trigrams, {size_kb:.0f} KB")
    if dropped:
        print(f"  {dropped} bigrams dropped (word not in lexicon)")

    keys = {}
    for _, surface, key, _lk, _f in rows:
        keys.setdefault(key, []).append(surface)
    collisions = {k: v for k, v in keys.items() if len(v) > 1}
    print(f"  {len(collisions)} phonetic keys carry more than one word")
    for k, v in sorted(collisions.items(), key=lambda x: -len(x[1]))[:8]:
        print(f"    {k}: {', '.join(v)}")


if __name__ == "__main__":
    build(source=sys.argv[1] if len(sys.argv) > 1 else None)
