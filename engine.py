"""
The suggestion engine. This is the piece that gets ported to Swift
almost line for line, so it deliberately uses nothing clever.

Ranking, in order of influence:
  1. bigram weight for the previous word   (strongest signal)
  2. user dictionary count                  (learns your spellings)
  3. corpus frequency
  4. shorter completions before longer ones
"""
import sqlite3

from phonetics import strict_key, loose_key

MAX_SUGGESTIONS = 5


class GujlishEngine:
    def __init__(self, db_path="gujlish.db"):
        self.conn = sqlite3.connect(
            f"file:{db_path}?mode=ro", uri=True, check_same_thread=False
        )
        self.conn.row_factory = sqlite3.Row
        self.user_counts = {}   # surface -> times accepted

    # ---------- lookup ----------

    def _by_prefix(self, key_prefix, column, limit=60):
        cur = self.conn.execute(
            f"SELECT id, surface, strict_k, loose_k, freq FROM words "
            f"WHERE {column} >= ? AND {column} < ? "
            f"ORDER BY freq DESC LIMIT ?",
            (key_prefix, key_prefix + "\uffff", limit),
        )
        return cur.fetchall()

    def _fuzzy(self, key, limit=40):
        """Fallback for dropped or inserted vowels: mjama -> majama.
        Compares against keys of a similar length only, so it stays cheap."""
        lo, hi = max(1, len(key) - 1), len(key) + 2
        cur = self.conn.execute(
            "SELECT id, surface, strict_k, loose_k, freq FROM words "
            "WHERE LENGTH(loose_k) BETWEEN ? AND ? "
            "ORDER BY freq DESC LIMIT 400",
            (lo, hi),
        )
        out = []
        for row in cur:
            if _within_one_edit(key, row["loose_k"]):
                out.append(row)
                if len(out) >= limit:
                    break
        return out

    def _bigram_weights(self, prev_word):
        if not prev_word:
            return {}
        cur = self.conn.execute(
            "SELECT b.next_id, b.weight FROM bigrams b "
            "JOIN words w ON w.id = b.prev_id WHERE w.loose_k = ?",
            (loose_key(prev_word, prefix=True),),
        )
        return {r["next_id"]: r["weight"] for r in cur}

    # ---------- public API ----------

    def suggest(self, typed, prev_word=None):
        """Candidates for a partially typed word."""
        sk = strict_key(typed, prefix=True)
        lk = loose_key(typed, prefix=True)
        if not sk:
            return self.next_word(prev_word)

        # Tier 1: aspiration-preserving match. Tier 2: aspiration folded,
        # scored down. Tier 3: one edit away, only for longer input.
        # Words are indexed un-stripped, so also try the nasal-stripped
        # form: typing "chhun" must still reach "chu".
        sk_alt, lk_alt = strict_key(typed), loose_key(typed)

        strict_rows = self._by_prefix(sk, "strict_k")
        if sk_alt != sk and len(strict_rows) < 3:
            have = {r["id"] for r in strict_rows}
            strict_rows += [r for r in self._by_prefix(sk_alt, "strict_k")
                            if r["id"] not in have]
        tiers = [(strict_rows, 0)]
        seen = {r["id"] for r in strict_rows}
        loose_rows = [r for r in self._by_prefix(lk, "loose_k")
                      if r["id"] not in seen]
        if lk_alt != lk and len(strict_rows) + len(loose_rows) < 3:
            have = seen | {r["id"] for r in loose_rows}
            loose_rows += [r for r in self._by_prefix(lk_alt, "loose_k")
                           if r["id"] not in have]
        tiers.append((loose_rows, 30))
        seen |= {r["id"] for r in tiers[1][0]}
        if sum(len(t[0]) for t in tiers) < 3 and len(lk) >= 4:
            tiers.append(([r for r in self._fuzzy(lk)
                           if r["id"] not in seen], 60))

        weights = self._bigram_weights(prev_word)
        scored = []
        for rows_, penalty in tiers:
            for r in rows_:
                score = r["freq"] - penalty
                score += weights.get(r["id"], 0) * 4
                score += user_boost(self.user_counts.get(r["surface"], 0))
                score -= (len(r["loose_k"]) - len(lk)) * 3
                if r["strict_k"] == sk:
                    score += 40
                scored.append((score, r["surface"]))

        scored.sort(key=lambda x: (-x[0], len(x[1]), x[1]))
        seen, out = set(), []
        for _s, surface in scored:
            if surface in seen:
                continue
            seen.add(surface)
            out.append(surface)
            if len(out) >= MAX_SUGGESTIONS:
                break
        return out

    def next_word(self, prev_word):
        """Candidates when nothing is typed yet — pure prediction."""
        if not prev_word:
            return []
        cur = self.conn.execute(
            "SELECT w2.surface, b.weight FROM bigrams b "
            "JOIN words w1 ON w1.id = b.prev_id "
            "JOIN words w2 ON w2.id = b.next_id "
            "WHERE w1.loose_k = ? ORDER BY b.weight DESC LIMIT ?",
            (loose_key(prev_word, prefix=True), MAX_SUGGESTIONS),
        )
        return [r["surface"] for r in cur]

    def accept(self, surface):
        """Call when the user taps a suggestion. On device this also
        writes to the user dictionary in the app group container."""
        self.user_counts[surface] = self.user_counts.get(surface, 0) + 1


def user_boost(count):
    """Three acceptances put a word firmly ahead of the corpus; beyond
    that it grows slowly, so a chat export where one word appears 800
    times does not drown everything else. Mirrored in web/gujlish.js."""
    import math
    return 25 * min(count, 3) + 10 * math.log1p(count) if count else 0


def _within_one_edit(a, b):
    if a == b:
        return True
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) > len(b):
        a, b = b, a
    i = j = 0
    edited = False
    while i < len(a) and j < len(b):
        if a[i] == b[j]:
            i += 1
            j += 1
            continue
        if edited:
            return False
        edited = True
        if len(a) == len(b):
            i += 1
        j += 1
    return True


if __name__ == "__main__":
    eng = GujlishEngine()
    trials = [
        ("che", None), ("ch", None), ("tha", None), ("thay", None),
        ("kem", None), ("cho", "kem"), ("", "kem"), ("", "su"),
        ("k", "su"), ("kar", "su"), ("nat", "khabar"), ("", "khabar"),
        ("maj", None), ("mjama", None), ("shu", None), ("chh", None),
        ("jam", None), ("", "thayu"), ("gh", None), ("tmne", None),
    ]
    for typed, prev in trials:
        res = eng.suggest(typed, prev) if typed else eng.next_word(prev)
        ctx = f"[{prev}] " if prev else ""
        print(f"{ctx}{typed!r:<10} -> {', '.join(res) or '(nothing)'}")
