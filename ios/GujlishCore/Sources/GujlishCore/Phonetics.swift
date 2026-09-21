// Gujlish phonetic normalisation. Port of phonetics.py, which is the
// reference: every surface form maps to a coarse phonetic key, the
// lexicon is indexed on the key, and the canonical surface is shown.
//
//   strictKey  keeps aspiration (th / dh / kh / gh / bh / jh / ph)
//   looseKey   throws it away
//
// Prefix mode keeps the trailing nasal and h, because a half-typed
// "jam" must not collapse to "ja". Deliberately dull: no regex.

public enum Phonetics {
    // Aspirated consonants get a private uppercase symbol so later rules
    // can't touch them and so the loose key can undo them in one pass.
    // Order matters: "chh" before "ch", "shh" before "sh".
    private static let digraphs: [([Character], [Character])] = [
        ("chh", "C"), ("ch", "C"), ("shh", "s"), ("sh", "s"),
        ("th", "T"), ("dh", "D"), ("kh", "K"), ("gh", "G"),
        ("ph", "F"), ("bh", "B"), ("jh", "J"), ("zh", "J"),
    ].map { (Array($0.0), Array($0.1)) }

    private static let singles: [Character: Character] = ["z": "J", "w": "v", "q": "k", "f": "F"]

    private static let vowelRuns: [([Character], [Character])] = [
        ("aa", "a"), ("ee", "i"), ("ii", "i"),
        ("oo", "u"), ("uu", "u"), ("ei", "e"),
    ].map { (Array($0.0), Array($0.1)) }

    // strict symbol -> loose equivalent
    private static let deaspirate: [Character: Character] = [
        "T": "t", "D": "d", "K": "k", "G": "g",
        "F": "f", "B": "b", "J": "j", "C": "c",
    ]

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Phonetic key that preserves aspiration.
    public static func strictKey(_ word: String, prefix: Bool = false) -> String {
        String(core(word, prefix: prefix))
    }

    /// Phonetic key that also folds th->t, kh->k, chh->ch and so on.
    public static func looseKey(_ word: String, prefix: Bool = false) -> String {
        String(core(word, prefix: prefix).map { deaspirate[$0] ?? $0 })
    }

    // Left-to-right, non-overlapping, like Python's str.replace.
    private static func replace(_ w: [Character], _ src: [Character], _ dst: [Character]) -> [Character] {
        guard w.count >= src.count else { return w }
        var out: [Character] = []
        out.reserveCapacity(w.count)
        var i = 0
        let last = w.count - src.count
        while i < w.count {
            if i <= last && w[i] == src[0] && Array(w[i..<(i + src.count)]) == src {
                out.append(contentsOf: dst)
                i += src.count
            } else {
                out.append(w[i])
                i += 1
            }
        }
        return out
    }

    private static func core(_ word: String, prefix: Bool) -> [Character] {
        var w: [Character] = Array(word.lowercased()).filter { $0.isLetter }
        if w.isEmpty { return w }

        w = replace(w, ["x"], ["k", "s"])

        for (src, dst) in digraphs {
            w = replace(w, src, dst)
        }

        w = w.map { singles[$0] ?? $0 }

        // y is a vowel everywhere but word-initially: thayu/thaiu, chey/che,
        // kay/kai all need to land together.
        for i in w.indices.dropFirst() where w[i] == "y" {
            w[i] = "i"
        }

        for _ in 0..<3 {
            let before = w
            for (src, dst) in vowelRuns {
                w = replace(w, src, dst)
            }
            if w == before { break }
        }

        // Doubled consonants: sachchu / sacchu / sachu. Compare
        // case-insensitively so c+C collapses to the aspirated form.
        var out: [Character] = []
        out.reserveCapacity(w.count)
        for c in w {
            let lc = Character(c.lowercased())
            if let prev = out.last, Character(prev.lowercased()) == lc, !vowels.contains(lc) {
                if c.isUppercase { out[out.count - 1] = c }
                continue
            }
            out.append(c)
        }
        w = out

        if !prefix {
            // Whole words only. Nasalisation and a trailing bare h carry no
            // information: chhu/chhun/chun, ha/haan/han.
            while w.count > 2, w[w.count - 1] == "n" || w[w.count - 1] == "m", vowels.contains(w[w.count - 2]) {
                w.removeLast()
            }
            while w.count > 2, w[w.count - 1] == "h" {
                w.removeLast()
            }
        }

        return w
    }
}
