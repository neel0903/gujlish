// Latin -> Gujarati script, rule-based. Port of web/reverse.js. The
// fallback for script mode when a word is not in the lexicon's native
// column (names, new slang, typos). Lexicon words use the real form.
//
// Deliberately simple: dental t/d (Latin cannot tell ત from ટ), s for
// સ, sh for શ, inherent 'a' assumed between consonants unless the pair
// is a common conjunct (pr, ky, tv, kl, doubled) or a nasal before a
// consonant (which becomes anusvara: sambandh -> સંબંધ).

public enum Reverse {
    // Longest first, so "chh" wins over "ch" over "c".
    private static let consonants: [(String, String)] = [
        ("chh", "છ"), ("ksh", "ક્ષ"), ("ch", "ચ"), ("kh", "ખ"), ("gh", "ઘ"), ("jh", "ઝ"), ("th", "થ"), ("dh", "ધ"),
        ("ph", "ફ"), ("bh", "ભ"), ("sh", "શ"), ("gn", "જ્ઞ"),
        ("k", "ક"), ("g", "ગ"), ("c", "ક"), ("j", "જ"), ("z", "ઝ"), ("t", "ત"), ("d", "દ"), ("n", "ન"), ("p", "પ"), ("f", "ફ"),
        ("b", "બ"), ("m", "મ"), ("y", "ય"), ("r", "ર"), ("l", "લ"), ("v", "વ"), ("w", "વ"), ("s", "સ"), ("h", "હ"), ("q", "ક"), ("x", "ક્સ"),
    ]
    // (latin, matra, independent form)
    private static let vowels: [(String, String, String)] = [
        ("aa", "ા", "આ"), ("ee", "ી", "ઈ"), ("ii", "ી", "ઈ"), ("oo", "ૂ", "ઊ"), ("uu", "ૂ", "ઊ"),
        ("ai", "ૈ", "ઐ"), ("au", "ૌ", "ઔ"), ("ei", "ે", "એ"),
        ("a", "", "અ"), ("i", "િ", "ઇ"), ("u", "ુ", "ઉ"), ("e", "ે", "એ"), ("o", "ો", "ઓ"),
    ]
    private static let virama = "્", anusvara = "ં"

    private enum Unit {
        case consonant(latin: String, script: String)
        case vowel(latin: String, sign: String, independent: String)
    }

    private static func units(_ word: String) -> [Unit] {
        var out: [Unit] = []
        var rest = Substring(word)
        while !rest.isEmpty {
            if let c = consonants.first(where: { rest.hasPrefix($0.0) }) {
                out.append(.consonant(latin: c.0, script: c.1))
                rest = rest.dropFirst(c.0.count)
            } else if let v = vowels.first(where: { rest.hasPrefix($0.0) }) {
                out.append(.vowel(latin: v.0, sign: v.1, independent: v.2))
                rest = rest.dropFirst(v.0.count)
            } else {
                rest = rest.dropFirst()
            }
        }
        return out
    }

    public static func toGujarati(_ word: String) -> String {
        let u = units(Engine.cleanSurface(word))
        var out = ""
        var i = 0
        while i < u.count {
            defer { i += 1 }
            guard case let .consonant(val, script) = u[i] else {
                if case let .vowel(_, _, independent) = u[i] { out += independent }
                continue
            }
            let next = i + 1 < u.count ? u[i + 1] : nil
            switch next {
            case let .consonant(nc, _)?:
                let isNasal = val == "n" || val == "m"
                if isNasal && !"yrlvh".contains(nc.first!) && i > 0 {
                    out += anusvara
                    continue
                }
                out += script
                // Conjunct only where Latin is unambiguous: a doubled consonant,
                // a glide (kanya, vyavsay), or r/l/v right after a word-initial
                // consonant (pravin, kripa). Mid-word "kr" is usually a dropped
                // schwa (dikra, chokra), so it stays two syllables.
                if nc == val || "yv".contains(nc.first!) || (i == 0 && "rl".contains(nc.first!)) {
                    out += virama
                }
            case let .vowel(latin, sign, _)?:
                var sign = sign
                let last = i + 1 == u.count - 1
                // A final written "a" is a real long vowel (kanya -> કન્યા);
                // a bare final consonant would have no a at all. Final "ai"
                // is a + i (bhai -> ભાઈ), mid-word it is the diphthong (paisa).
                if last && latin == "a" { sign = "ા" }
                if last && latin == "ai" { sign = "ાઈ" }
                out += script + sign
                i += 1
            case nil:
                // word-final consonant
                if val == "n", i > 0, case let .vowel(latin, _, _) = u[i - 1], latin == "u" {
                    out += anusvara
                } else {
                    out += script
                }
            }
        }
        return out
    }
}
