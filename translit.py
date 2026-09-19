"""
Rule-based Gujarati script -> chat-register Latin.

Used only inside the build pipeline, as the fallback romanisation for
every native-script word. Attested human spellings (Dakshina, Aksharantar)
override it when they carry real counts; this fills the gaps, which
include the most frequent words in the language (Aksharantar has no
entry for છે, આ, એક, માટે, પણ, તે ...) and gives one consistent style
where the attested data offers a single noisy spelling.

Style targets the seed lexicon: short vowels (hati not hatee), no
trailing nasal on whole words (chu, hatu, gamma), ch for ચ and for
word-initial છ, chh for medial છ (che, chokro, pachhi), f for ફ.

Schwa deletion is the hard part. Gujarati writes the inherent 'a' on
every bare consonant but speakers drop it at the end of a word and in
the middle of many words (સરકાર is sarkar, not sarakara). The rule here
is the standard one for Indo-Aryan: walking right to left, drop the
inherent vowel when the consonant sits between two syllables that keep
theirs, and never on a nasalised syllable. It gets
sarkar, karvama, amdavad, temne, matlab, anusarvani right and loses on
compounds (bhavangar) and English-convention place names (gujrat,
vadodra) — those come from the attested data instead.
"""

CONSONANTS = {
    "ક": "k", "ખ": "kh", "ગ": "g", "ઘ": "gh", "ઙ": "n",
    "ચ": "ch", "છ": "chh", "જ": "j", "ઝ": "jh", "ઞ": "n",
    "ટ": "t", "ઠ": "th", "ડ": "d", "ઢ": "dh", "ણ": "n",
    "ત": "t", "થ": "th", "દ": "d", "ધ": "dh", "ન": "n",
    "પ": "p", "ફ": "f", "બ": "b", "ભ": "bh", "મ": "m",
    "ય": "y", "ર": "r", "લ": "l", "ળ": "l", "વ": "v",
    "શ": "sh", "ષ": "sh", "સ": "s", "હ": "h",
}
INDEPENDENT = {
    "અ": "a", "આ": "a", "ઇ": "i", "ઈ": "i", "ઉ": "u", "ઊ": "u",
    "ઋ": "ru", "ૠ": "ru", "ઍ": "e", "એ": "e", "ઐ": "ai",
    "ઑ": "o", "ઓ": "o", "ઔ": "au", "ૐ": "om",
}
MATRAS = {
    "ા": "a", "િ": "i", "ી": "i", "ુ": "u", "ૂ": "u", "ૃ": "ru",
    "ૄ": "ru", "ૅ": "e", "ે": "e", "ૈ": "ai", "ૉ": "o", "ો": "o", "ૌ": "au",
}
VIRAMA = "્"
NASALS = "ંઁ"

# After a cluster, the final inherent vowel survives when the last
# consonant is a liquid, glide or nasal (mitra, satya, vidya, ratna) and
# goes otherwise (shabd, bhakt). A reph cluster always drops it (purn,
# varsh, dharm).
_KEEP_AFTER_CLUSTER = {"r", "l", "y", "v", "n", "m"}

# Which way to walk the word when dropping medial schwas. Where two
# adjacent syllables could each lose theirs, the direction decides which
# one does: left to right gives bhavnagar and anusravani, right to left
# gives bhavangar and anusarvani. Against Dakshina's 30K annotated words
# right to left lands in a human spelling group 91.6% of the time and
# left to right 87.9%, so right to left it is. Compounds are the known
# loss (bhavangar); the attested data covers those.
DIRECTION = "rtl"

# જ્ઞ is pronounced gn/gy, not jn.
_PRE = [("જ્ઞ", "ગ્ન")]


class _Unit:
    __slots__ = ("c", "v", "inherent", "nasal")

    def __init__(self, c, v, inherent):
        self.c, self.v, self.inherent, self.nasal = c, v, inherent, False


def _parse(word):
    for src, dst in _PRE:
        word = word.replace(src, dst)
    units = []
    for ch in word:
        if ch in CONSONANTS:
            c = CONSONANTS[ch]
            if ch == "છ" and not units:
                c = "ch"
            units.append(_Unit(c, "a", True))
        elif ch in INDEPENDENT:
            v = INDEPENDENT[ch]
            if ch == "આ" and not units:
                v = "aa"
            units.append(_Unit("", v, False))
        elif ch in MATRAS and units and units[-1].c:
            units[-1].v, units[-1].inherent = MATRAS[ch], False
        elif ch == VIRAMA and units and units[-1].c:
            units[-1].v, units[-1].inherent = None, False
        elif ch in NASALS and units:
            units[-1].nasal = True
        # visarga (rare, and Wikipedia types it as a colon), nukta,
        # ZWJ/ZWNJ, digits, anything else: ignored
    return units


def _drop_schwas(units):
    n = len(units)
    if n < 2:
        return
    last, prev = units[-1], units[-2]
    if last.c and last.inherent and not last.nasal:
        if prev.v is not None:
            last.v = None
        elif prev.c == "r" or last.c[-1] not in _KEEP_AFTER_CLUSTER:
            last.v = None
    order = range(1, n - 1) if DIRECTION == "ltr" else range(n - 2, 0, -1)
    for i in order:
        u = units[i]
        if not (u.c and u.inherent) or u.nasal:
            continue                    # a nasalised syllable is closed: anand
        p, q = units[i - 1], units[i + 1]
        if p.v is None or q.v is None:
            continue
        # No geminate guard: it would fix ananam but break the very
        # common m-final stem + માં/નું suffix (gamma, kamnu, namnu).
        u.v = None


def _render(units):
    out = []
    for i, u in enumerate(units):
        out.append(u.c)
        if u.v:
            out.append(u.v)
        if u.nasal and i < len(units) - 1:
            nxt = units[i + 1].c
            out.append("m" if nxt and nxt[0] in "pbm" else "n")
    return "".join(out)


def romanise(word):
    """Gujarati-script word -> lowercase a-z string, or '' if nothing
    in the word is Gujarati."""
    units = _parse(word)
    if not units:
        return ""
    _drop_schwas(units)
    return _render(units)


if __name__ == "__main__":
    cases = [
        ("છે", "che"), ("છું", "chu"), ("છો", "cho"), ("અને", "ane"),
        ("આ", "aa"), ("એક", "ek"), ("તે", "te"), ("માટે", "mate"),
        ("પણ", "pan"), ("માં", "ma"), ("ના", "na"), ("ન", "na"),
        ("હતું", "hatu"), ("હતી", "hati"), ("થયું", "thayu"),
        ("કરવામાં", "karvama"), ("ગામમાં", "gamma"), ("સરકાર", "sarkar"),
        ("અનુસરવાની", "anusarvani"), ("અમદાવાદ", "amdavad"), ("રાજકોટ", "rajkot"),
        ("મિત્ર", "mitra"), ("સત્ય", "satya"), ("શબ્દ", "shabd"),
        ("વર્ષ", "varsh"), ("પૂર્ણ", "purn"), ("ધન્યવાદ", "dhanyavad"),
        ("કેટલું", "ketlu"), ("એટલે", "etle"), ("ખબર", "khabar"),
        ("પછી", "pachhi"), ("છોકરો", "chokro"), ("પ્રાથમિક", "prathmik"),
        ("વ્યવસાય", "vyavsay"), ("મતલબ", "matlab"), ("સમય", "samay"),
        ("ખરેખર", "kharekhar"), ("મજામાં", "majama"), ("તેમણે", "temne"),
        ("અથવા", "athva"), ("અન્ય", "anya"), ("જોઈએ", "joie"),
        ("કર્યું", "karyu"), ("પંચાયત", "panchayat"), ("સંપૂર્ણ", "sampurn"),
        ("ઘર", "ghar"), ("ગઈ", "gai"), ("જમવા", "jamva"), ("નથી", "nathi"),
        ("કહેવું", "kahevu"), ("લોકો", "loko"), ("ઘણું", "ghanu"),
        ("ક્યાં", "kya"), ("શ્રેણી", "shreni"), ("તરીકે", "tarike"),
        ("ફોન", "fon"), ("ઝાડ", "jhad"), ("વાત", "vat"), ("બરાબર", "barabar"),
        ("આનંદથી", "aanandthi"), ("કામનું", "kamnu"), ("જ્ઞાન", "gnan"),
        ("અજ્ઞાત", "agnat"), ("સંબંધ", "sambandh"), ("આનંદ", "aanand"),
    ]
    bad = 0
    for native, want in cases:
        got = romanise(native)
        ok = got == want
        bad += not ok
        if not ok:
            print(f"BAD {native}: got {got!r}, want {want!r}")
    print(f"{len(cases) - bad}/{len(cases)} transliterations match")
