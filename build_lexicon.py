"""
Phase 1: the corpus pipeline.

    gu.wikipedia dump ──► native-script word counts + bigrams
                                  │
    Dakshina gu lexicon ──────────┼──► join on the native-script word
    Aksharantar guj pairs ────────┘
                                  ▼
            lexicon.tsv  +  lexicon.bigrams.tsv   ──►  build_db.py

Frequency lives on the Gujarati-script word; romanisations inherit it.
The script never leaves this file — only Latin surfaces reach the DB.

    python3 build_lexicon.py             # full run, caches wiki counts
    python3 build_lexicon.py --top 30000 # smaller lexicon

Inputs (see data/SOURCES.md for URLs, revisions and licences):
    data/guwiki-latest-pages-articles.xml.bz2
    data/aksharantar_guj.zip
    data/dakshina_dataset_v1.0.tar        optional, folded in if present

Four decisions worth knowing about:

1.  One native word has many romanisations, and most of them collapse to
    the same phonetic key. If we emitted all of them the suggestion strip
    would show thayu / thayoo / thaiu / thayun as four "different" words.
    So romanisations are grouped by whole-word strict key and each group
    gets ONE canonical surface: a seed-lexicon spelling if one is attested
    (that is the register we want), else the best attestation-minus-style
    score. Groups with under 10% of attestations are dropped as noise
    unless they are the only group.

0.  Attested data alone is not enough. Aksharantar has no entry at all
    for 18 of the 80 most frequent words (છે, આ, એક, માટે, પણ, તે ...),
    and where it has one spelling it is often a single noisy mining hit
    (aneey, nope, lookoo). So translit.py generates a rule-based spelling
    for every native word and it competes as a candidate worth 1.5
    attestations — enough to beat one noisy hit, not enough to beat
    humans who agree. When 3+ attestations all disagree with the rule,
    the rule is dropped for that word.

2.  Wikipedia counts are Zipfian (top word ~ hundreds of thousands, tail
    ~ 2). The engine's penalties (30 loose, 60 fuzzy, +40 exact) assume
    a 1–100 scale, so counts are log-scaled onto it. Same for bigrams.

3.  Wikipedia is encyclopaedic. It has no "kem cho", no "majama chu".
    The hand-built seed lexicon is merged back in as a chat-register
    overlay: its words keep at least their seed weight and its bigrams
    are kept verbatim. Corpus brings breadth; seed brings register.
"""
import argparse
import bz2
import collections
import json
import math
import os
import re
import sys
import tarfile
import unicodedata
import zipfile
import xml.etree.ElementTree as ET

from phonetics import strict_key
from translit import romanise

DATA = "data"
WIKI_DUMP = os.path.join(DATA, "guwiki-latest-pages-articles.xml.bz2")
AKSHARANTAR_ZIP = os.path.join(DATA, "aksharantar_guj.zip")
DAKSHINA_TAR = os.path.join(DATA, "dakshina_dataset_v1.0.tar")
DAKSHINA_TAR_SIZE = 2008340480          # complete download is exactly this
DAKSHINA_DIR = os.path.join(DATA, "dakshina")
WIKI_UNIGRAMS = os.path.join(DATA, "guwiki.unigrams.tsv")
WIKI_BIGRAMS = os.path.join(DATA, "guwiki.bigrams.tsv")
WIKI_TRIGRAMS = os.path.join(DATA, "guwiki.trigrams.tsv")

MIN_TRIGRAM_COUNT = 3
TRIGRAM_BIGRAM_FLOOR = 5   # count trigrams only over already-common bigrams
CONTEXTS_PER_PAIR = 8
MAX_TRIGRAMS = 200_000

MIN_WORD_COUNT = 2      # native word must occur this often in the wiki
MIN_BIGRAM_COUNT = 3
MIN_GROUP_SHARE = 0.30  # a secondary spelling group must hold this share
                        # (one mined hit vs the rule: 0.5/2.0, dropped;
                        #  one annotator vs the rule: 1/2.5, kept)
AKSHARANTAR_WEIGHT = 0.5  # one mined pair, uncounted: weak evidence
GENERATED_WEIGHT = 1.5  # rule-based spelling counts as this many attestations
TRUST_HUMANS_AT = 3     # ... until Dakshina annotators have attested this much:
GENERATED_TIEBREAK = 0.5  # then it is only a style vote, and is dropped
                          # outright if none of them agree with it
FOLLOWERS_PER_WORD = 10
MAX_BIGRAMS = 250_000

# ---------------------------------------------------------------------------
# Step A: Gujarati Wikipedia -> native-script unigram and bigram counts
# ---------------------------------------------------------------------------

_RE_COMMENT = re.compile(r"<!--.*?-->", re.S)
_RE_REF = re.compile(r"<ref[^>/]*/>|<ref[^>]*>.*?</ref>", re.S | re.I)
_RE_TABLE = re.compile(r"\{\|.*?\|\}", re.S)
_RE_TEMPLATE = re.compile(r"\{\{[^{}]*\}\}")
_RE_EXTLINK = re.compile(r"\[https?://[^\s\]]+\s*([^\]]*)\]")
_RE_LINK2 = re.compile(r"\[\[([^\[\]|]*)\|([^\[\]]*)\]\]")
_RE_LINK1 = re.compile(r"\[\[([^\[\]]*)\]\]")
_RE_URL = re.compile(r"https?://\S+")
_RE_TAG = re.compile(r"<[^>]+>")

# A token is a run of Gujarati letters, matras and signs, allowing the
# zero-width joiners some editors put inside conjuncts. Digits and the
# block's punctuation-like signs (૤ ૰ ૱) end a token.
_RE_TOKEN = re.compile(r"[ઁ-ઃઅ-હ઼-્ૐૠ-ૣ‌‍]+")
_RE_SENTENCE = re.compile(r"[।॥.!?\n|;:]+")
_RE_DIGIT = re.compile(r"[૦-૯0-9]")
# Words start with a consonant or an independent vowel, never a matra.
_RE_WORD_START = re.compile(r"^[અ-હૠૡ]")


def strip_wikitext(text):
    text = _RE_COMMENT.sub(" ", text)
    text = _RE_REF.sub(" ", text)
    text = _RE_TABLE.sub(" ", text)
    for _ in range(6):                      # nested templates, inside out
        stripped = _RE_TEMPLATE.sub(" ", text)
        if stripped == text:
            break
        text = stripped
    text = _RE_EXTLINK.sub(r"\1", text)
    text = _RE_LINK2.sub(r"\2", text)
    text = _RE_LINK1.sub(r"\1", text)
    text = _RE_URL.sub(" ", text)
    text = _RE_TAG.sub(" ", text)
    return text.replace("'''", "").replace("''", "")


def normalise_native(token):
    token = unicodedata.normalize("NFC", token)
    token = token.replace("‌", "").replace("‍", "")
    # Wikipedia editors type the visarga as a colon: છેઃ is છે.
    token = token.rstrip("ઃ")
    if not token or _RE_DIGIT.search(token) or not _RE_WORD_START.match(token):
        return None
    return token


def _iter_articles(dump_path):
    """Yield wikitext of namespace-0, non-redirect pages."""
    with bz2.open(dump_path, "rb") as fh:
        for _event, elem in ET.iterparse(fh, events=("end",)):
            if not elem.tag.endswith("}page"):
                continue
            ns = elem.find("{*}ns")
            redirect = elem.find("{*}redirect")
            text_el = elem.find("{*}revision/{*}text")
            if ns is not None and ns.text == "0" and redirect is None \
                    and text_el is not None and text_el.text:
                yield text_el.text
            elem.clear()


def count_wiki(dump_path):
    """Each distinct sentence counts once. Gujarati Wikipedia has ~18K
    village stubs generated from one template, so without this the top
    of the lexicon is "the village has a primary school, a panchayat
    house, an anganwadi and a dairy" rather than the language."""
    unigrams = collections.Counter()
    bigrams = collections.Counter()
    seen = set()
    pages = dupes = 0
    for wikitext in _iter_articles(dump_path):
        pages += 1
        if pages % 5000 == 0:
            print(f"  {pages} pages, {len(unigrams)} word types", file=sys.stderr)
        text = strip_wikitext(wikitext)
        for sentence in _RE_SENTENCE.split(text):
            toks = [normalise_native(t) for t in _RE_TOKEN.findall(sentence)]
            toks = [t for t in toks if t]
            if not toks:
                continue
            h = hash(" ".join(toks))
            if h in seen:
                dupes += 1
                continue
            seen.add(h)
            unigrams.update(toks)
            bigrams.update(zip(toks, toks[1:]))
    print(f"  {pages} articles, {len(seen)} distinct sentences ({dupes} repeats "
          f"skipped), {sum(unigrams.values())} tokens, {len(unigrams)} word types",
          file=sys.stderr)
    return unigrams, bigrams


def count_wiki_trigrams(dump_path, bigrams):
    """Second pass over the dump, same sentence dedup. Counting every
    trigram would need ~1 GB; counting only those whose two bigrams are
    both common keeps it small and drops nothing the ranker would use."""
    trigrams = collections.Counter()
    seen = set()
    for wikitext in _iter_articles(dump_path):
        text = strip_wikitext(wikitext)
        for sentence in _RE_SENTENCE.split(text):
            toks = [normalise_native(t) for t in _RE_TOKEN.findall(sentence)]
            toks = [t for t in toks if t]
            if len(toks) < 3:
                continue
            h = hash(" ".join(toks))
            if h in seen:
                continue
            seen.add(h)
            for a, b, c in zip(toks, toks[1:], toks[2:]):
                if bigrams.get((a, b), 0) >= TRIGRAM_BIGRAM_FLOOR \
                        and bigrams.get((b, c), 0) >= TRIGRAM_BIGRAM_FLOOR:
                    trigrams[(a, b, c)] += 1
    return trigrams


def wiki_trigrams(dump_path, bigrams):
    if os.path.exists(WIKI_TRIGRAMS):
        out = {}
        with open(WIKI_TRIGRAMS, encoding="utf-8") as fh:
            for line in fh:
                a, b, c, n = line.rstrip("\n").split("\t")
                out[(a, b, c)] = int(n)
        print(f"wiki trigrams from cache: {len(out)}", file=sys.stderr)
        return out
    print("counting trigrams (second pass over the dump) ...", file=sys.stderr)
    trigrams = count_wiki_trigrams(dump_path, bigrams)
    with open(WIKI_TRIGRAMS, "w", encoding="utf-8") as fh:
        for (a, b, c), n in trigrams.most_common():
            if n < 2:
                break
            fh.write(f"{a}\t{b}\t{c}\t{n}\n")
    return {k: v for k, v in trigrams.items() if v >= 2}


def wiki_counts(dump_path, refresh=False):
    """Cached: counting the dump takes a minute or two."""
    if not refresh and os.path.exists(WIKI_UNIGRAMS) and os.path.exists(WIKI_BIGRAMS):
        unigrams, bigrams = {}, {}
        with open(WIKI_UNIGRAMS, encoding="utf-8") as fh:
            for line in fh:
                w, c = line.rstrip("\n").split("\t")
                unigrams[w] = int(c)
        with open(WIKI_BIGRAMS, encoding="utf-8") as fh:
            for line in fh:
                p, n, c = line.rstrip("\n").split("\t")
                bigrams[(p, n)] = int(c)
        print(f"wiki counts from cache: {len(unigrams)} words, {len(bigrams)} bigrams",
              file=sys.stderr)
        return unigrams, bigrams

    print("counting the Wikipedia dump ...", file=sys.stderr)
    unigrams, bigrams = count_wiki(dump_path)
    with open(WIKI_UNIGRAMS, "w", encoding="utf-8") as fh:
        for w, c in unigrams.most_common():
            fh.write(f"{w}\t{c}\n")
    with open(WIKI_BIGRAMS, "w", encoding="utf-8") as fh:
        for (p, n), c in bigrams.most_common():
            if c < 2:
                break
            fh.write(f"{p}\t{n}\t{c}\n")
    return unigrams, {k: v for k, v in bigrams.items() if v >= 2}


# ---------------------------------------------------------------------------
# Step B: romanisation table  native -> {roman: attestation weight}
# ---------------------------------------------------------------------------

_RE_ROMAN = re.compile(r"^[a-z]+$")
_RE_BARE_CONSONANT = re.compile(r"[ક-હ]")
_RE_DOUBLE_VOWEL = re.compile(r"aa|ee|oo|ii|uu")
_RE_DOUBLE_CONS = re.compile(r"([b-df-hj-np-tv-z])\1")


def canon(r):
    """Display convention. Dakshina's annotators write long vowels
    (hatee, praapt, vidyaa, raajyamaan); the chat register writes
    hati, prapt, vidya, rajyama. Fold to short vowels — except a
    word-initial aa, which the register keeps (aaje, aavjo, aa) — and
    fold q/w to k/v (qarrie, widyaa). This merges attestations that
    differ only by convention, so they count together."""
    r = r.replace("q", "k").replace("w", "v")
    r = re.sub(r"ee|ii", "i", r)
    r = re.sub(r"oo|uu", "u", r)
    r = r.replace("ae", "e")                # aetle, aeva, oae -> etle, eva, oe
    head = "aa" if r.startswith("aa") else ""
    return head + r[len(head):].replace("aa", "a")


def clean_roman(r, native=None):
    """Lowercase letters only, in the display convention. Given the
    native word, also drop a trailing n/m that only spells its final
    anusvara: annotators write hatun and rajyaman, the register writes
    hatu and rajyama. A real final nasal (pan, kem, gam) has no
    anusvara in the script and is left alone."""
    r = canon(r.strip().lower())
    if native and native.endswith("ં") and len(r) > 2 \
            and r[-1] in "nm" and r[-2] in "aeiou":
        r = r[:-1]
    # Annotators also write out the final inherent vowel — ghara,
    # gujarata — that the register drops: ghar, gujarat. When the script
    # ends in a bare consonant (no matra, not a cluster like મિત્ર),
    # strip that trailing a.
    if native and len(native) > 1 and _RE_BARE_CONSONANT.match(native[-1]) \
            and native[-2] != "્" and len(r) > 3 and r[-1] == "a" and r[-2] not in "aeiou":
        r = r[:-1]
    return r if _RE_ROMAN.match(r) else None


def style_penalty(r):
    """How far a spelling is from the short chat register. Only breaks
    ties between spellings with similar attestation, so keep it small."""
    p = 0.0
    p += 0.6 * len(_RE_DOUBLE_VOWEL.findall(r))
    p += 0.6 * len(_RE_DOUBLE_CONS.findall(r))
    if r.endswith("y") and len(r) > 1 and r[-2] not in "aeiou":
        p += 0.6                                  # kary, suury
    p += 0.05 * len(r)
    return p


def extract_dakshina():
    """Pull just gu/lexicons out of the 2 GB tar, once."""
    have_lexicons = os.path.isdir(os.path.join(DAKSHINA_DIR, "gu", "lexicons"))
    have_sentences = os.path.exists(os.path.join(DAKSHINA_DIR, ROMANIZED_FILE))
    if have_lexicons and have_sentences:
        return True
    if not os.path.exists(DAKSHINA_TAR):
        return have_lexicons
    if os.path.getsize(DAKSHINA_TAR) != DAKSHINA_TAR_SIZE:
        print("Dakshina tar is incomplete, skipping it for this run", file=sys.stderr)
        return False
    print("extracting gu/lexicons and gu/romanized from the Dakshina tar ...", file=sys.stderr)
    with tarfile.open(DAKSHINA_TAR) as tar:
        for m in tar:
            if ("/gu/lexicons/" in m.name or m.name.endswith(ROMANIZED_FILE)) and m.isfile():
                m.name = m.name.split("/", 1)[1]      # drop dakshina_dataset_v1.0/
                tar.extract(m, DAKSHINA_DIR)
    return True


ROMANIZED_FILE = "gu/romanized/gu.romanized.rejoined.aligned.cased_nopunct.tsv"


def load_dakshina_sentences(table, human):
    """10K Wikipedia sentences romanised by hand, token-aligned:
    native<TAB>roman per line. Each aligned token is one more human
    attestation, which extends counted spellings well past the 30K
    words of the lexicon files."""
    path = os.path.join(DAKSHINA_DIR, ROMANIZED_FILE)
    if not os.path.exists(path):
        return
    n = 0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 2 or " " in parts[0] or " " in parts[1]:
                continue
            native = normalise_native(parts[0])
            roman = native and clean_roman(parts[1], native)
            if native and roman:
                table[native][roman] += 1
                human[native] += 1
                n += 1
    print(f"Dakshina sentences: {n} aligned tokens", file=sys.stderr)


def load_dakshina(table, human):
    """native<TAB>roman<TAB>attestations. All three splits — we are not
    training a model, we want every human-validated pair. `human`
    tracks how many annotator attestations each native word has, since
    those are the only counts that can overrule the rule-based spelling."""
    lex_dir = os.path.join(DAKSHINA_DIR, "gu", "lexicons")
    n = 0
    for name in sorted(os.listdir(lex_dir)):
        if not name.endswith(".tsv"):
            continue
        with open(os.path.join(lex_dir, name), encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 3:
                    continue
                native = normalise_native(parts[0])
                roman = native and clean_roman(parts[1], native)
                if native and roman:
                    table[native][roman] += int(parts[2])
                    human[native] += int(parts[2])
                    n += 1
    print(f"Dakshina: {n} pairs", file=sys.stderr)


def load_aksharantar(table):
    """JSON lines. Mostly one mined spelling per word with no count, so
    each pair is weak evidence, whatever its source."""
    n = 0
    with zipfile.ZipFile(AKSHARANTAR_ZIP) as z:
        for name in z.namelist():
            if not name.endswith(".json"):
                continue
            with z.open(name) as fh:
                for line in fh:
                    d = json.loads(line)
                    native = normalise_native(d["native word"])
                    roman = native and clean_roman(d["english word"], native)
                    if native and roman:
                        table[native][roman] += AKSHARANTAR_WEIGHT
                        n += 1
    print(f"Aksharantar: {n} pairs", file=sys.stderr)


# ---------------------------------------------------------------------------
# Step C: the join
# ---------------------------------------------------------------------------

def seed():
    from seed_lexicon import WORDS, BIGRAMS
    words = {}
    for surface, freq, _gloss in WORDS:
        if " " in surface:
            continue
        words[surface] = max(freq, words.get(surface, 0))
    return words, BIGRAMS


def pick_surface(members, seed_surfaces):
    """members: [(roman, weight)] sharing one phonetic key. A seed
    spelling wins outright; otherwise attestation weight, nudged by
    style, so that hati beats hatee when Dakshina has counted both and
    the shorter form wins when nobody has counted anything."""
    seeded = [m for m in members if m[0] in seed_surfaces]
    pool = seeded or members
    return max(pool, key=lambda m: (m[1] - style_penalty(m[0]), m[0]))[0]


def log_scale(x, x_max):
    return max(1, round(100 * math.log1p(x) / math.log1p(x_max)))


def build(top, out_path):
    unigrams, wiki_bigrams = wiki_counts(WIKI_DUMP)

    table = collections.defaultdict(collections.Counter)
    human = collections.Counter()
    if extract_dakshina():
        load_dakshina(table, human)
        load_dakshina_sentences(table, human)
    load_aksharantar(table)
    print(f"romanisation table: {len(table)} native words", file=sys.stderr)

    seed_words, seed_bigrams = seed()
    seed_surfaces = set(seed_words)

    surface_count = collections.Counter()      # surface -> weighted count
    surface_natives = collections.defaultdict(list)   # for the review file
    canonical = {}                             # native -> its top surface
    joined = 0
    for native, count in unigrams.items():
        if count < MIN_WORD_COUNT:
            continue
        romans = collections.Counter(table.get(native, {}))
        groups = collections.defaultdict(list)
        for roman, w in romans.items():
            groups[strict_key(roman)].append((roman, w))
        # The rule-based spelling is always a candidate, except where
        # humans have clearly attested something it disagrees with.
        generated = canon(romanise(native))
        if generated and _RE_ROMAN.match(generated):
            gkey = strict_key(generated)
            trusted = human.get(native, 0) >= TRUST_HUMANS_AT
            if gkey in groups or not trusted:
                gw = GENERATED_TIEBREAK if trusted else GENERATED_WEIGHT
                romans[generated] += gw
                groups[gkey].append((generated, gw))
        if not romans:
            continue
        joined += 1
        total = sum(romans.values())
        # The primary spelling carries the word's whole count — typing
        # "tha" should rank thayu by how common થયું is, not by 75% of
        # it. Secondary groups get a discounted copy if they are real.
        ranked_groups = sorted(groups.values(),
                               key=lambda m: -sum(w for _, w in m))
        for rank, members in enumerate(ranked_groups):
            share = sum(w for _, w in members) / total
            if rank > 0 and share < MIN_GROUP_SHARE:
                continue
            surface = pick_surface(members, seed_surfaces)
            weighted = count if rank == 0 else count * share
            surface_count[surface] += weighted
            surface_natives[surface].append((native, weighted))
            if rank == 0:
                canonical[native] = surface
    print(f"joined: {joined} native words -> {len(surface_count)} surfaces",
          file=sys.stderr)

    # Scale and cap.
    x_max = max(surface_count.values())
    ranked = sorted(surface_count.items(), key=lambda kv: -kv[1])
    lexicon = {}
    for surface, x in ranked[:top]:
        lexicon[surface] = log_scale(x, x_max)

    # Seed overlay. Where the corpus spelled a seed word by the display
    # convention (kam) and the seed spells it its own way (kaam), the seed
    # spelling takes over the corpus entry rather than sitting next to it.
    rename = {}
    for surface, freq in seed_words.items():
        c = clean_roman(surface)
        if c and c != surface and c in lexicon:
            rename[c] = surface
            lexicon[surface] = max(freq, lexicon.pop(c))
            surface_count[surface] = surface_count.pop(c)
            surface_natives[surface] = surface_natives.pop(c)
        else:
            lexicon[surface] = max(freq, lexicon.get(surface, 0))
    canonical = {k: rename.get(v, v) for k, v in canonical.items()}

    # Bigrams over surfaces, top followers per word, then seed overlay.
    pair_count = collections.Counter()
    for (p, n), c in wiki_bigrams.items():
        if c < MIN_BIGRAM_COUNT:
            continue
        ps, ns = canonical.get(p), canonical.get(n)
        if ps in lexicon and ns in lexicon and ps != ns:
            pair_count[(ps, ns)] += c
    per_prev = collections.defaultdict(list)
    for (ps, ns), c in pair_count.items():
        per_prev[ps].append((ns, c))
    c_max = max(pair_count.values()) if pair_count else 1
    bigrams = {}
    for ps, followers in per_prev.items():
        followers.sort(key=lambda f: -f[1])
        for ns, c in followers[:FOLLOWERS_PER_WORD]:
            bigrams[(ps, ns)] = (log_scale(c, c_max), c)
    kept = sorted(bigrams.items(), key=lambda kv: -kv[1][1])[:MAX_BIGRAMS]
    bigrams = {k: v[0] for k, v in kept}
    for p, n, w in seed_bigrams:
        if p in lexicon and n in lexicon:
            bigrams[(p, n)] = max(w, bigrams.get((p, n), 0))

    # Trigrams over surfaces: top followers per two-word context.
    tri_count = collections.Counter()
    for (a, b, c), n in wiki_trigrams(WIKI_DUMP, wiki_bigrams).items():
        if n < MIN_TRIGRAM_COUNT:
            continue
        sa, sb, sc = canonical.get(a), canonical.get(b), canonical.get(c)
        if sa in lexicon and sb in lexicon and sc in lexicon and len({sa, sb, sc}) == 3:
            tri_count[(sa, sb, sc)] += n
    per_ctx = collections.defaultdict(list)
    for (sa, sb, sc), n in tri_count.items():
        per_ctx[(sa, sb)].append((sc, n))
    t_max = max(tri_count.values()) if tri_count else 1
    trigrams = {}
    for ctx, followers in per_ctx.items():
        followers.sort(key=lambda f: -f[1])
        for sc, n in followers[:CONTEXTS_PER_PAIR]:
            trigrams[ctx + (sc,)] = (log_scale(n, t_max), n)
    kept_t = sorted(trigrams.items(), key=lambda kv: -kv[1][1])[:MAX_TRIGRAMS]
    trigrams = {k: v[0] for k, v in kept_t}

    # Deliverables.
    stem = os.path.splitext(out_path)[0]
    with open(out_path, "w", encoding="utf-8") as fh:
        for surface, freq in sorted(lexicon.items(), key=lambda kv: (-kv[1], kv[0])):
            fh.write(f"{surface}\t{freq}\n")
    with open(stem + ".bigrams.tsv", "w", encoding="utf-8") as fh:
        for (p, n), w in sorted(bigrams.items(), key=lambda kv: (-kv[1], kv[0])):
            fh.write(f"{p}\t{n}\t{w}\n")
    with open(stem + ".trigrams.tsv", "w", encoding="utf-8") as fh:
        for (a, b, c), w in sorted(trigrams.items(), key=lambda kv: (-kv[1], kv[0])):
            fh.write(f"{a}\t{b}\t{c}\t{w}\n")
    # Surface -> the Gujarati-script word behind it, for the script
    # preview. This is the one place the script leaves the pipeline.
    with open(stem + ".native.tsv", "w", encoding="utf-8") as fh:
        for surface in sorted(lexicon):
            natives = surface_natives.get(surface)
            if natives:
                fh.write(f"{surface}\t{max(natives, key=lambda t: t[1])[0]}\n")

    # Review file: the native words behind each surface. Never ships.
    with open(stem + ".review.tsv", "w", encoding="utf-8") as fh:
        fh.write("surface\tfreq\tweighted_count\tnative_words\n")
        for surface, freq in sorted(lexicon.items(), key=lambda kv: (-kv[1], kv[0])):
            natives = sorted(surface_natives.get(surface, []), key=lambda t: -t[1])
            shown = " ".join(f"{n}({int(c)})" for n, c in natives[:4])
            fh.write(f"{surface}\t{freq}\t{int(surface_count.get(surface, 0))}\t{shown}\n")

    print(f"{out_path}: {len(lexicon)} surfaces; "
          f"{stem}.bigrams.tsv: {len(bigrams)} bigrams; "
          f"{stem}.trigrams.tsv: {len(trigrams)} trigrams", file=sys.stderr)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=80000,
                    help="keep this many corpus surfaces (seed words always kept)")
    ap.add_argument("--out", default="lexicon.tsv")
    ap.add_argument("--refresh-wiki", action="store_true",
                    help="recount the dump instead of using the cache")
    args = ap.parse_args()
    if args.refresh_wiki:
        for p in (WIKI_UNIGRAMS, WIKI_BIGRAMS, WIKI_TRIGRAMS):
            if os.path.exists(p):
                os.remove(p)
    build(args.top, args.out)
