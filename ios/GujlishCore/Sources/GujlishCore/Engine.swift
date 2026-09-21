// The suggestion engine. Ported from engine.py (the reference) with the
// extras of web/gujlish.js: a personal dictionary whose words become
// real candidates, and English mixed mode. Pinned to both by
// web/expected.json.
//
// Ranking, in order of influence:
//   1. context: trigram weight for the two previous words, then bigram
//      weight for the previous word           (strongest signal)
//   2. user dictionary count                  (learns your spellings)
//   3. corpus frequency
//   4. shorter completions before longer ones
//
// Structural difference from the JS: the corpus stays in SQLite, and
// only what the user has taught lives in memory. Personal words are
// merged into each lookup in the same (freq desc, surface) order.

import Foundation

/// What the user has taught the keyboard. Same JSON as the web app's
/// export, so learned data can move between web and phone.
public struct PersonalData: Codable, Equatable {
    public var words: [String: Int] = [:]      // surface -> count
    public var bigrams: [String: Int] = [:]    // "a b" -> count
    public var trigrams: [String: Int] = [:]   // "a b c" -> count
    public init() {}
}

public final class Engine {
    public enum Mode { case mixed, gujlish, english }
    public enum Source { case gujlish, english, personal }

    public struct Suggestions {
        public var surfaces: [String] = []
        public var sources: [String: Source] = [:]
        public var strictKey = ""
        public var looseKey = ""
        public var tiers = (strict: 0, loose: 0, fuzzy: 0, english: 0)
    }

    public static let maxSuggestions = 5
    static let englishPenalty = 15.0
    static let correctMargin = 20.0

    public var mode: Mode = .mixed

    private struct Entry {
        let id: Int
        let surface: String
        let sk: String
        let lk: String
        var freq: Int
        let personal: Bool
    }

    private struct IdPair: Hashable { let a: Int; let b: Int }

    private let lexicon: Lexicon

    // Personal words get ids far above any row id in the database.
    private static let personalBase = 1_000_000_000
    private var personalWords: [Entry] = []
    private var personalIndex: [String: Int] = [:]          // surface -> index
    private var followers: [Int: [Int: Int]] = [:]          // prevId -> nextId -> weight
    private var tri: [IdPair: [Int: Int]] = [:]             // (prev2Id, prev1Id) -> nextId -> weight
    public private(set) var personal = PersonalData()

    public init(lexicon: Lexicon) {
        self.lexicon = lexicon
    }

    // ---------- scoring helpers ----------

    // How much a word you have accepted or typed moves up. Three
    // acceptances put a word firmly ahead of the corpus; beyond that it
    // grows slowly, so a chat export with a word used 800 times does not
    // drown everything else.
    static func userBoost(_ count: Int) -> Double {
        count > 0 ? Double(25 * min(count, 3)) + 10 * log1p(Double(count)) : 0
    }

    // Corpus-scale frequency (1..100) for a word the corpus never had.
    static func personalFreq(_ count: Int) -> Int {
        min(100, Int((30 + 12 * log1p(Double(count))).rounded()))
    }

    // Bigram/trigram weight (1..100) for a pair learned from you.
    static func personalWeight(_ count: Int) -> Int {
        min(100, Int((Double(20 * min(count, 3)) + 10 * log1p(Double(count))).rounded()))
    }

    static func withinOneEdit<A: RandomAccessCollection, B: RandomAccessCollection>(_ x: A, _ y: B) -> Bool
    where A.Element == UInt8, B.Element == UInt8, A.Index == Int, B.Index == Int {
        if abs(x.count - y.count) > 1 { return false }
        if x.count > y.count { return withinOneEdit(y, x) }
        var i = x.startIndex, j = y.startIndex
        var edited = false
        while i < x.endIndex && j < y.endIndex {
            if x[i] == y[j] { i += 1; j += 1; continue }
            if edited { return false }
            edited = true
            if x.count == y.count { i += 1 }
            j += 1
        }
        return true
    }

    // "gaye" vs "gaya": one vowel differs. The matra is where typing
    // goes wrong most, so a vowel-only slip is the most likely error and
    // gets a bonus over consonant edits.
    static func isVowelSwap(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a.count != b.count { return false }
        var diff = -1
        for i in 0..<a.count where a[i] != b[i] {
            if diff >= 0 { return false }
            diff = i
        }
        return diff >= 0 && isVowel(a[diff]) && isVowel(b[diff])
    }

    private static func isVowel(_ c: UInt8) -> Bool {
        c == 97 || c == 101 || c == 105 || c == 111 || c == 117   // a e i o u
    }

    public static func cleanSurface(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { $0 >= "a" && $0 <= "z" }))
    }

    // ---------- lookup: database plus personal words ----------

    private func entry(_ w: Lexicon.Word) -> Entry {
        Entry(id: w.id, surface: w.surface, sk: w.strictK, lk: w.looseK, freq: w.freq, personal: false)
    }

    private static func inScanOrder(_ a: Entry, _ b: Entry) -> Bool {
        a.freq != b.freq ? a.freq > b.freq : a.surface < b.surface
    }

    private func merged(_ rows: [Lexicon.Word], limit: Int, _ matches: (Entry) -> Bool) -> [Entry] {
        var out = rows.map(entry)
        let mine = personalWords.filter(matches)
        if mine.isEmpty { return out }
        out.append(contentsOf: mine)
        out.sort(by: Engine.inScanOrder)
        return Array(out.prefix(limit))
    }

    private func byPrefix(_ key: String, _ column: Lexicon.KeyColumn, limit: Int = 60) -> [Entry] {
        merged(lexicon.byPrefix(key, column: column, limit: limit), limit: limit) {
            (column == .strict ? $0.sk : $0.lk).hasPrefix(key)
        }
    }

    // Fallback for dropped or inserted vowels: mjama -> majama. Compares
    // against keys of a similar length only, so it stays cheap.
    private func fuzzy(_ key: String, limit: Int = 40) -> [Entry] {
        let lo = max(1, key.utf8.count - 1), hi = key.utf8.count + 2
        let pool = merged(lexicon.fuzzyPool(minLength: lo, maxLength: hi), limit: 400) {
            $0.lk.utf8.count >= lo && $0.lk.utf8.count <= hi
        }
        let k = Array(key.utf8)
        var out: [Entry] = []
        for w in pool where Engine.withinOneEdit(k, Array(w.lk.utf8)) {
            out.append(w)
            if out.count >= limit { break }
        }
        return out
    }

    private func lookup(surface: String) -> Entry? {
        if let w = lexicon.word(surface: surface) { return entry(w) }
        return personalIndex[surface].map { personalWords[$0] }
    }

    private func ids(looseKey: String) -> [Int] {
        lexicon.words(looseKey: looseKey).map { $0.id } + personalWords.filter { $0.lk == looseKey }.map { $0.id }
    }

    /// Is there any word, corpus or personal, with this prefix-mode loose key?
    public func knows(looseKey: String) -> Bool {
        !lexicon.words(looseKey: looseKey).isEmpty || personalWords.contains { $0.lk == looseKey }
    }

    private func surface(id: Int) -> String? {
        id >= Engine.personalBase ? personalWords[id - Engine.personalBase].surface : lexicon.surface(id: id)
    }

    // ---------- context ----------

    private static func keepMax(_ weights: inout [Int: Int], _ id: Int, _ w: Int) {
        if let old = weights[id], old >= w { return }
        weights[id] = w
    }

    func bigramWeights(_ prev1: String?) -> [Int: Int] {
        var weights: [Int: Int] = [:]
        guard let prev1 = prev1, !prev1.isEmpty else { return weights }
        let key = Phonetics.looseKey(prev1, prefix: true)
        for (id, w) in lexicon.bigramRows(prevLooseKey: key) { Engine.keepMax(&weights, id, w) }
        if !followers.isEmpty {
            for p in ids(looseKey: key) {
                for (id, w) in followers[p] ?? [:] { Engine.keepMax(&weights, id, w) }
            }
        }
        return weights
    }

    func trigramWeights(_ prev2: String?, _ prev1: String?) -> [Int: Int] {
        var weights: [Int: Int] = [:]
        guard let prev1 = prev1, let prev2 = prev2, !prev1.isEmpty, !prev2.isEmpty else { return weights }
        let k2 = Phonetics.looseKey(prev2, prefix: true), k1 = Phonetics.looseKey(prev1, prefix: true)
        for (id, w) in lexicon.trigramRows(prev2LooseKey: k2, prev1LooseKey: k1) { Engine.keepMax(&weights, id, w) }
        if !tri.isEmpty {
            let ids1 = ids(looseKey: k1)
            for a in ids(looseKey: k2) {
                for b in ids1 {
                    for (id, w) in tri[IdPair(a: a, b: b)] ?? [:] { Engine.keepMax(&weights, id, w) }
                }
            }
        }
        return weights
    }

    // id -> score contribution from the words before.
    private func context(_ prev1: String?, _ prev2: String?) -> [Int: Double] {
        var ctx: [Int: Double] = [:]
        for (id, w) in bigramWeights(prev1) { ctx[id, default: 0] += Double(w) * 4 }
        for (id, w) in trigramWeights(prev2, prev1) { ctx[id, default: 0] += Double(w) * 6 }
        return ctx
    }

    // ---------- public API ----------

    /// Candidates for a partially typed word.
    public func suggest(_ typed: String, prev: String? = nil, prev2: String? = nil) -> [String] {
        suggestDetailed(typed, prev: prev, prev2: prev2).surfaces
    }

    public func suggestDetailed(_ typed: String, prev prev1: String? = nil, prev2: String? = nil) -> Suggestions {
        var result = Suggestions()
        let typedClean = Engine.cleanSurface(typed)
        let sk = Phonetics.strictKey(typed, prefix: true), lk = Phonetics.looseKey(typed, prefix: true)
        if sk.isEmpty {
            result.surfaces = nextWord(prev: prev1, prev2: prev2)
            return result
        }
        result.strictKey = sk
        result.looseKey = lk

        var scored: [(score: Double, surface: String)] = []
        var src: [String: Source] = [:]

        if mode != .english {
            // Tier 1: aspiration-preserving match. Tier 2: aspiration folded,
            // scored down. Tier 3: one edit away, only for longer input.
            // Words are indexed un-stripped, so also try the nasal-stripped
            // form: typing "chhun" must still reach "chu".
            let skAlt = Phonetics.strictKey(typed), lkAlt = Phonetics.looseKey(typed)

            var strictRows = byPrefix(sk, .strict)
            if skAlt != sk && strictRows.count < 3 {
                let have = Set(strictRows.map { $0.id })
                strictRows += byPrefix(skAlt, .strict).filter { !have.contains($0.id) }
            }
            var seen = Set(strictRows.map { $0.id })
            var looseRows = byPrefix(lk, .loose).filter { !seen.contains($0.id) }
            if lkAlt != lk && strictRows.count + looseRows.count < 3 {
                let have = seen.union(looseRows.map { $0.id })
                looseRows += byPrefix(lkAlt, .loose).filter { !have.contains($0.id) }
            }
            seen.formUnion(looseRows.map { $0.id })
            var tiers: [(rows: [Entry], penalty: Double)] = [(strictRows, 0), (looseRows, 30)]
            var fuzzyRows: [Entry] = []
            if strictRows.count + looseRows.count < 3 && lk.utf8.count >= 4 {
                fuzzyRows = fuzzy(lk).filter { !seen.contains($0.id) }
                tiers.append((fuzzyRows, 60))
            }
            result.tiers.strict = strictRows.count
            result.tiers.loose = looseRows.count
            result.tiers.fuzzy = fuzzyRows.count

            let ctx = context(prev1, prev2)
            for (rows, penalty) in tiers {
                for r in rows {
                    var score = Double(r.freq) - penalty
                    score += ctx[r.id] ?? 0
                    score += Engine.userBoost(personal.words[r.surface] ?? 0)
                    score -= Double(r.lk.utf8.count - lk.utf8.count) * 3
                    if r.sk == sk { score += 40 }
                    scored.append((score, r.surface))
                    if src[r.surface] == nil { src[r.surface] = r.personal ? .personal : .gujlish }
                }
            }
        }

        if mode != .gujlish && !typedClean.isEmpty {
            let rows = lexicon.englishByPrefix(typedClean)
            result.tiers.english = rows.count
            for e in rows {
                var score = Double(e.freq) - Engine.englishPenalty
                score += Engine.userBoost(personal.words[e.word] ?? 0)
                score -= Double(e.word.utf8.count - typedClean.utf8.count) * 3
                if e.word == typedClean { score += 40 }
                scored.append((score, e.word))
                if src[e.word] == nil { src[e.word] = .english }
            }
        }

        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.surface.utf8.count != $1.surface.utf8.count { return $0.surface.utf8.count < $1.surface.utf8.count }
            return $0.surface < $1.surface
        }
        var used = Set<String>()
        for (_, s) in scored where used.insert(s).inserted {
            result.surfaces.append(s)
            result.sources[s] = src[s]
            if result.surfaces.count >= Engine.maxSuggestions { break }
        }
        return result
    }

    /// Candidates when nothing is typed yet — pure prediction.
    public func nextWord(prev prev1: String?, prev2: String? = nil) -> [String] {
        guard let prev1 = prev1, !prev1.isEmpty else { return [] }
        var scores: [Int: Double] = [:]
        for (id, w) in bigramWeights(prev1) { scores[id, default: 0] += Double(w) }
        for (id, w) in trigramWeights(prev2, prev1) { scores[id, default: 0] += Double(w) * 1.5 }
        var cands: [(score: Double, surface: String)] = []
        for (id, s) in scores {
            if let surface = surface(id: id) { cands.append((s, surface)) }
        }
        cands.sort { $0.score != $1.score ? $0.score > $1.score : $0.surface < $1.surface }
        return cands.prefix(Engine.maxSuggestions).map { $0.surface }
    }

    // ---------- autocorrect ----------

    /// What the committed word should have been, or nil to leave it.
    /// Candidates are words with the same phonetic key (gharey -> ghare,
    /// thayoo -> thayu) and words one letter away (gaye -> gaya, ghara ->
    /// ghare), scored like suggestions plus a closeness bonus, against a
    /// bias to keep what was typed. Words you have taught it (accepted or
    /// restored twice) are never corrected; common known words are never
    /// corrected. In mixed mode an English word defends itself with its
    /// own frequency, so "meeting" and "gate" stay but "avi" (a video
    /// format) still becomes aavi.
    public func correct(_ typed: String, prev prev1: String? = nil, prev2: String? = nil) -> String? {
        let clean = Engine.cleanSurface(typed)
        let cleanBytes = Array(clean.utf8)
        if cleanBytes.count < 3 { return nil }
        let uc = personal.words[clean] ?? 0
        if uc >= 2 { return nil }
        let known = lexicon.word(surface: clean)
        if let known = known, known.freq >= 60 { return nil }

        let ctx = context(prev1, prev2)
        var keep = 30.0
        if let known = known {
            keep = Double(known.freq) + (ctx[known.id] ?? 0) + Engine.userBoost(uc) + 25
        }
        if mode != .gujlish, let eng = lexicon.englishFreq(clean) {
            keep = max(keep, Double(eng) - Engine.englishPenalty + Engine.userBoost(uc) + 25)
        }

        struct Cand { let surface: String; let freq: Int; let bonus: Double; let personal: Bool }
        var cands: [Int: Cand] = [:]
        for key in [Phonetics.looseKey(clean, prefix: true), Phonetics.looseKey(clean)] {
            for w in lexicon.words(looseKey: key) {
                cands[w.id] = Cand(surface: w.surface, freq: w.freq, bonus: 30, personal: false)
            }
            for w in personalWords where w.lk == key {
                cands[w.id] = Cand(surface: w.surface, freq: w.freq, bonus: 30, personal: true)
            }
        }
        func consider(_ id: Int, _ bytes: [UInt8], _ freq: Int, personal: Bool) {
            let bonus: Double = Engine.isVowelSwap(cleanBytes, bytes) ? 10 : 0
            cands[id] = Cand(surface: String(decoding: bytes, as: UTF8.self), freq: freq, bonus: bonus, personal: personal)
        }
        lexicon.scanSurfaces(minLength: cleanBytes.count - 1, maxLength: cleanBytes.count + 1) { id, surface, freq in
            if Engine.withinOneEdit(cleanBytes, surface) && cands[id] == nil {
                consider(id, Array(surface), freq, personal: false)
            }
        }
        for w in personalWords where cands[w.id] == nil {
            let bytes = Array(w.surface.utf8)
            if Engine.withinOneEdit(cleanBytes, bytes) { consider(w.id, bytes, w.freq, personal: true) }
        }

        var best: (score: Double, surface: String)?
        for (id, c) in cands {
            if c.surface == clean { continue }
            if c.personal && (personal.words[c.surface] ?? 0) < 2 { continue }
            let s = Double(c.freq) + (ctx[id] ?? 0) + Engine.userBoost(personal.words[c.surface] ?? 0) + c.bonus
            if best == nil || s > best!.score || (s == best!.score && c.surface < best!.surface) {
                best = (s, c.surface)
            }
        }
        guard let b = best, b.score - keep >= Engine.correctMargin else { return nil }
        return b.surface
    }

    // ---------- personal dictionary ----------

    public func learnWord(_ word: String, count: Int = 1) {
        let surface = Engine.cleanSurface(word)
        if surface.isEmpty { return }
        let total = (personal.words[surface] ?? 0) + count
        personal.words[surface] = total
        if let i = personalIndex[surface] {
            personalWords[i].freq = Engine.personalFreq(total)
        } else if lexicon.word(surface: surface) == nil {
            personalIndex[surface] = personalWords.count
            personalWords.append(Entry(id: Engine.personalBase + personalWords.count, surface: surface,
                                       sk: Phonetics.strictKey(surface, prefix: true),
                                       lk: Phonetics.looseKey(surface, prefix: true),
                                       freq: Engine.personalFreq(total), personal: true))
        }
    }

    public func learnBigram(_ prev: String, _ next: String, count: Int = 1) {
        let prev = Engine.cleanSurface(prev), next = Engine.cleanSurface(next)
        guard let p = lookup(surface: prev), let n = lookup(surface: next), p.id != n.id else { return }
        let total = (personal.bigrams[prev + " " + next] ?? 0) + count
        personal.bigrams[prev + " " + next] = total
        Engine.keepMax(&followers[p.id, default: [:]], n.id, Engine.personalWeight(total))
    }

    public func learnTrigram(_ prev2: String, _ prev1: String, _ next: String, count: Int = 1) {
        let prev2 = Engine.cleanSurface(prev2), prev1 = Engine.cleanSurface(prev1), next = Engine.cleanSurface(next)
        guard let a = lookup(surface: prev2), let b = lookup(surface: prev1), let n = lookup(surface: next) else { return }
        let key = prev2 + " " + prev1 + " " + next
        let total = (personal.trigrams[key] ?? 0) + count
        personal.trigrams[key] = total
        Engine.keepMax(&tri[IdPair(a: a.id, b: b.id), default: [:]], n.id, Engine.personalWeight(total))
    }

    /// Called when the user takes a suggestion or commits a typed word.
    public func accept(_ surface: String, prev: String? = nil, prev2: String? = nil) {
        learnWord(surface)
        if let prev = prev, !prev.isEmpty {
            learnBigram(prev, surface)
            if let prev2 = prev2, !prev2.isEmpty { learnTrigram(prev2, prev, surface) }
        }
    }

    public func loadPersonal(_ data: PersonalData) {
        for (k, c) in data.words { learnWord(k, count: c) }
        for (k, c) in data.bigrams {
            let p = k.split(separator: " ").map(String.init)
            if p.count == 2 { learnBigram(p[0], p[1], count: c) }
        }
        for (k, c) in data.trigrams {
            let p = k.split(separator: " ").map(String.init)
            if p.count == 3 { learnTrigram(p[0], p[1], p[2], count: c) }
        }
    }

    public func forgetPersonal() {
        personal = PersonalData()
        personalWords = []
        personalIndex = [:]
        followers = [:]
        tri = [:]
    }
}
