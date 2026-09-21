// Gujlish grammar: agreement checks that catch what actually goes wrong
// in chat Gujarati. Port of web/grammar.js. Rules, not a model, so every
// finding has a reason.
//
//   1. The present copula must match the subject pronoun:
//        hu chu · tu che · tame cho · ame chie · e/te che
//   2. Future verbs carry person:   hu jaish · tame jasho · ame jaishu · te jashe
//      and the future copula:       hu hoish · tame hasho · te hashe
//   3. A past verb in -yo after a plural subject wants -ya:  ame gaya
//      and after hu, -ya wants -yo or -yi (gender is the writer's call).
//
// The subject is the nearest pronoun to the left inside the clause;
// a conjunction (ane, pan, ke, etle, to, ...) or sentence punctuation
// ends the clause. "hu ane tame" counts as first person plural.
//
// Verb stems are verified against the lexicon (stem + vu/va must be a
// known word) so that "english" or "finish" never look like futures.

public enum Grammar {
    public struct Issue {
        public let range: Range<String.Index>
        public let from: String
        public let to: String
        public let alt: String?
        public let why: String
    }

    struct Token {
        let text: String
        let range: Range<String.Index>
        let word: Bool
    }

    // Prefix-mode keys: the whole-word key strips a final nasal, which
    // would make "kem" look like the conjunction "ke". Nasal variants
    // (hun, chhun) are listed explicitly instead.
    private static func lk(_ w: String) -> String { Phonetics.looseKey(w, prefix: true) }

    // Tables are kept word for word with grammar.js so the two agree.
    private static let subject: [String: String] = [
        "hu": "1sg", "hun": "1sg", "tu": "2sg", "tun": "2sg", "tame": "2pl", "ap": "2pl",
        "ame": "1pl", "apne": "1pl", "e": "3sg", "te": "3sg", "a": "3sg",
        "pelo": "3sg", "peli": "3sg", "pelu": "3sg", "teo": "3pl", "pela": "3pl", "badha": "3pl", "loko": "3pl",
    ]
    private static let stops: Set<String> = ["ane", "pan", "ke", "etle", "to", "karan", "karanke",
                                             "jo", "tyare", "jyare", "athva", "matlab", "bas"]

    // loose key -> persons this form agrees with
    private static let copula = ["cu": "1sg", "cun": "1sg", "ce": "2sg 3sg 3pl", "co": "2pl", "cie": "1pl"]
    private static let copulaFor = ["1sg": "chu", "2sg": "che", "2pl": "cho", "1pl": "chie", "3sg": "che", "3pl": "che"]
    private static let futCopula = ["hois": "1sg 2sg", "hoisu": "1pl", "haso": "2pl", "hase": "3sg 3pl"]
    private static let futCopulaFor = ["1sg": "hoish", "2sg": "hoish", "2pl": "hasho", "1pl": "hoishu", "3sg": "hashe", "3pl": "hashe"]
    // future endings, longest first
    private static let future = [("ishu", "1pl"), ("shu", "1pl"), ("ish", "1sg 2sg"), ("sho", "2pl"), ("she", "3sg 3pl")]
    private static let futureFor = ["1sg": "ish", "2sg": "ish", "2pl": "sho", "1pl": "ishu", "3sg": "she", "3pl": "she"]
    // stems whose infinitive is irregular or absent from the lexicon
    private static let irregularStems: Set<String> = ["ga", "ja", "tha", "aav", "av", "kar", "le", "de", "la", "kah", "rah", "jo", "ho"]

    private static func agrees(_ persons: String, _ subj: String) -> Bool {
        persons.split(separator: " ").contains(Substring(subj))
    }

    private static func isAsciiLetter(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    private static func matchCase(_ typed: String, _ fix: String) -> String {
        if typed.count > 1 && typed == typed.uppercased() && typed.contains(where: { $0 >= "A" && $0 <= "Z" }) {
            return fix.uppercased()
        }
        if let f = typed.first, f >= "A" && f <= "Z" { return fix.prefix(1).uppercased() + fix.dropFirst() }
        return fix
    }

    // Words, newlines, and runs of anything else that is not white space.
    static func tokenize(_ text: String) -> [Token] {
        var out: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let start = i
            if isAsciiLetter(c) {
                while i < text.endIndex && isAsciiLetter(text[i]) { i = text.index(after: i) }
                out.append(Token(text: String(text[start..<i]), range: start..<i, word: true))
            } else if c.isNewline {
                i = text.index(after: i)
                out.append(Token(text: "\n", range: start..<i, word: false))
            } else if c.isWhitespace {
                i = text.index(after: i)
            } else {
                while i < text.endIndex && !isAsciiLetter(text[i]) && !text[i].isWhitespace { i = text.index(after: i) }
                out.append(Token(text: String(text[start..<i]), range: start..<i, word: false))
            }
        }
        return out
    }

    private static func isVerbStem(_ stem: String, _ engine: Engine?) -> Bool {
        if stem.count < 2 { return false }
        if irregularStems.contains(stem) { return true }
        guard let engine = engine else { return false }
        return [stem + "vu", stem + "vun", stem + "va"].contains { engine.knows(looseKey: lk($0)) }
    }

    // Nearest subject pronoun to the left, inside the clause.
    private static func subjectFor(_ tokens: [Token], _ i: Int) -> (person: String, word: String)? {
        var found: [(person: String, word: String)] = []
        var j = i - 1
        while j >= 0 {
            defer { j -= 1 }
            let t = tokens[j]
            if !t.word {
                if t.text.contains(where: { ".!?\n".contains($0) }) { break }
                continue
            }
            let k = lk(t.text)
            if stops.contains(k) { break }
            if let person = subject[k] {
                found.append((person, t.text))
                if j >= 2, tokens[j - 1].word, lk(tokens[j - 1].text) == "ane",
                   tokens[j - 2].word, let other = subject[lk(tokens[j - 2].text)] {
                    found.append((other, tokens[j - 2].text))
                }
                break
            }
        }
        guard let first = found.first else { return nil }
        if found.count == 1 { return first }
        let persons = found.map { $0.person.prefix(1) }
        let word = found[1].word + " ane " + found[0].word
        if persons.contains("1") { return ("1pl", word) }
        if persons.contains("2") { return ("2pl", word) }
        return ("3pl", word)
    }

    private static func issue(_ t: Token, _ fix: String, _ why: String, alt: String? = nil) -> Issue {
        Issue(range: t.range, from: t.text, to: matchCase(t.text, fix), alt: alt.map { matchCase(t.text, $0) }, why: why)
    }

    public static func check(_ text: String, engine: Engine?) -> [Issue] {
        let tokens = tokenize(text)
        var issues: [Issue] = []
        for (i, t) in tokens.enumerated() where t.word {
            let lower = t.text.lowercased(), key = lk(lower)

            if let persons = copula[key] {
                if let subj = subjectFor(tokens, i), !agrees(persons, subj.person), let fix = copulaFor[subj.person] {
                    issues.append(issue(t, fix, "after \(subj.word) it is \(fix)"))
                }
                continue
            }
            if let persons = futCopula[key] {
                if let subj = subjectFor(tokens, i), !agrees(persons, subj.person), let fix = futCopulaFor[subj.person] {
                    issues.append(issue(t, fix, "after \(subj.word) it is \(fix)"))
                }
                continue
            }

            var handled = false
            for (ending, persons) in future where !handled {
                guard lower.count > ending.count + 1, lower.hasSuffix(ending) else { continue }
                let stem = String(lower.dropLast(ending.count))
                if !isVerbStem(stem, engine) { continue }
                handled = true
                if let subj = subjectFor(tokens, i), !agrees(persons, subj.person), let end = futureFor[subj.person] {
                    issues.append(issue(t, stem + end, "after \(subj.word) the verb ends in -\(end)"))
                }
            }
            if handled { continue }

            if lower.count > 3 && lower.hasSuffix("yo") {
                let stem = String(lower.dropLast(2))
                if isVerbStem(stem, engine), let subj = subjectFor(tokens, i), subj.person.hasSuffix("pl") {
                    issues.append(issue(t, stem + "ya", "after \(subj.word) the verb ends in -ya"))
                }
                continue
            }
            if lower.count > 3 && lower.hasSuffix("ya") {
                let stem = String(lower.dropLast(2))
                if isVerbStem(stem, engine), let subj = subjectFor(tokens, i), subj.person == "1sg" {
                    issues.append(issue(t, stem + "yo", "after hu the verb ends in -yo or -yi", alt: stem + "yi"))
                }
            }
        }
        return issues
    }

    public static func apply(_ text: String, _ issue: Issue, useAlt: Bool = false) -> String {
        var out = text
        out.replaceSubrange(issue.range, with: useAlt ? issue.alt ?? issue.to : issue.to)
        return out
    }

    // Apply every issue, first option. Built from slices of the original
    // text, so the issue ranges stay valid throughout.
    public static func fixAll(_ text: String, engine: Engine?) -> String {
        var out = ""
        var at = text.startIndex
        for iss in check(text, engine: engine) {
            out += text[at..<iss.range.lowerBound] + iss.to
            at = iss.range.upperBound
        }
        return out + text[at...]
    }
}
