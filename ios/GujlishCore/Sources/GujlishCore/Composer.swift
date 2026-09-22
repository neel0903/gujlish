// What each key does to the text. The keyboard extension is a thin shell
// around this class, so that every typing behaviour can be unit tested
// against a fake document: commit on space, autocorrect and its undo,
// taking a suggestion, script mode, the grammar fix, double-space period.

import Foundation

/// The host app's text, as far as a keyboard can see it.
public protocol TextDocument: AnyObject {
    var textBefore: String { get }
    func insert(_ text: String)
    func deleteBackward()
}

public struct KeyboardSettings: Codable, Equatable {
    public var autocorrect = true
    public var grammar = true
    public var scriptMode = false
    public var english = true
    /// Letters are typed when the finger lands, not when it lifts.
    public var fastKeys = true
    public init() {}

    // Settings saved by an older version lack the newer keys; they keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autocorrect = try c.decodeIfPresent(Bool.self, forKey: .autocorrect) ?? autocorrect
        grammar = try c.decodeIfPresent(Bool.self, forKey: .grammar) ?? grammar
        scriptMode = try c.decodeIfPresent(Bool.self, forKey: .scriptMode) ?? scriptMode
        english = try c.decodeIfPresent(Bool.self, forKey: .english) ?? english
        fastKeys = try c.decodeIfPresent(Bool.self, forKey: .fastKeys) ?? fastKeys
    }
}

public final class Composer {
    public struct GrammarFix: Equatable {
        public let from: String
        public let to: String
    }

    /// Everything the bar shows for one state of the text.
    public struct Snapshot {
        public let suggestions: [String]
        public let grammarFix: GrammarFix?
        /// What the space key will turn the current word into, if anything,
        /// and the word as typed: the bar offers both, as the system bar does.
        public let correction: String?
        public let typed: String
        /// How long the engine worked on it, for the diagnostics readout.
        public let milliseconds: Double
    }

    // Threads. The keys and the document belong to the main thread. The
    // engine (SQLite, ranking, the correction scan, grammar) is slow enough
    // to be felt, so it is only ever touched on `queue`: refresh() works
    // there and reports back, and the few answers a key needs at once are
    // fetched with queue.sync, which is short because refresh() has usually
    // prepared them already.
    private let engine: Engine
    private let queue = DispatchQueue(label: "gujlish.engine", qos: .userInitiated)
    private unowned let document: TextDocument

    public var settings = KeyboardSettings() {
        didSet {
            let mode: Engine.Mode = settings.english ? .mixed : .gujlish
            queue.sync { engine.mode = mode }
            lastCorrection = nil
            trail = nil
            prepared = nil
            generation += 1
        }
    }

    // Set by an autocorrect, cleared by the next key: a backspace right
    // after it puts the original back.
    private var lastCorrection: (original: String, corrected: String)?
    // A restored word is committed as typed the next time.
    private var protectedWord: String?
    private var restoreCounts: [String: Int] = [:]
    // Script mode leaves Gujarati before the cursor, so the Latin words
    // behind it are remembered here, valid while the text still ends in `tail`.
    private var trail: (tail: String, words: [String])?
    // The correction for the word being typed, worked out by refresh() so
    // that the space key has nothing left to compute.
    private var prepared: (before: String, fix: String?)?
    // A hand-typed word committed by the last key; deleting it at once
    // withdraws it from learning.
    private var justTyped: (word: String, inserted: String)?
    // Counts refreshes; an answer for an older text is dropped.
    private var generation = 0

    public init(engine: Engine, document: TextDocument) {
        self.engine = engine
        self.document = document
    }

    // ---------- the document, as we know it ----------

    // The host reports the text before the cursor through the system, and
    // right after fast typing that report can still be an older state. Our
    // own edits are therefore mirrored in `shadow`. When the host's text is
    // one of the states we passed through a moment ago, it is lagging and
    // the shadow is right; when it is anything else, the host changed the
    // text itself (cursor move, undo, paste) and the host is right.
    private var shadow: String?
    private var passed: [(text: String, time: Double)] = []
    /// Seconds, monotonic. Replaceable in tests.
    public var clock: () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    // Lag after fast typing lasts tens of milliseconds. Keep this short: a
    // chat app emptying the field on "send" also looks like an older state.
    // (On an iPhone the report was measured to be immediate, so this is a
    // safety net, not the normal path.)
    private static let lagWindow = 0.1

    private func currentText() -> String {
        let remote = document.textBefore
        guard let local = shadow else {
            shadow = remote
            return remote
        }
        // Equal proves nothing either way (a lagging report can match by
        // chance while we delete), so history only ever expires by age.
        if remote == local { return local }
        let now = clock()
        passed.removeAll { now - $0.time >= Composer.lagWindow }
        if passed.contains(where: { $0.text == remote }) { return local }
        shadow = remote
        passed.removeAll()
        return remote
    }

    private func remember(_ text: String) {
        passed.append((text, clock()))
        if passed.count > 64 { passed.removeFirst(passed.count - 64) }
    }

    private func insert(_ text: String) {
        let local = currentText()
        remember(local)
        shadow = local + text
        document.insert(text)
    }

    private func deleteBackward() {
        let local = currentText()
        if local.isEmpty {
            // Text we cannot see may be deleted; look again next time.
            shadow = nil
            passed.removeAll()
        } else {
            remember(local)
            shadow = String(local.dropLast())
        }
        document.deleteBackward()
    }

    // Removes exactly `text` from before the cursor when it is not plain
    // ASCII. How much one deleteBackward removes is the host's business:
    // measured on iOS 27 it is one code point of a Gujarati cluster, other
    // hosts may take the whole cluster. So: read after every delete, stop
    // as soon as the text is back to its length, never delete more times
    // than there are code points, and stop if a delete changed nothing.
    private func deleteExactly(_ text: String) {
        let before = document.textBefore
        guard before.hasSuffix(text) else { return }
        let target = before.unicodeScalars.count - text.unicodeScalars.count
        var last = before.unicodeScalars.count
        for _ in 0..<text.unicodeScalars.count {
            if last <= target { break }
            document.deleteBackward()
            let now = document.textBefore.unicodeScalars.count
            if now >= last { break }
            last = now
        }
        shadow = nil
        passed.removeAll()
    }

    /// The user moved the cursor or the field changed: forget what we assumed.
    public func documentChanged() {
        shadow = nil
        passed.removeAll()
        lastCorrection = nil
        prepared = nil
    }

    // ---------- reading ----------

    /// Works out the bar for the current text in the background and calls
    /// back on the main thread, unless the text has moved on by then.
    /// Returns the text it read, so the caller needs no second read.
    @discardableResult
    public func refresh(_ completion: @escaping (Snapshot) -> Void) -> String {
        let before = currentText()
        let job = makeJob(before)
        generation += 1
        let mine = generation
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = job()
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                self.prepared = result.prepared
                completion(result.snapshot)
            }
        }
        return before
    }

    /// The same, at once. For tests and for callers that must wait.
    public func snapshot() -> Snapshot {
        let job = makeJob(currentText())
        let result = queue.sync(execute: job)
        prepared = result.prepared
        return result.snapshot
    }

    public func suggestions() -> [String] { snapshot().suggestions }

    public func grammarFix() -> GrammarFix? { snapshot().grammarFix }

    // Captures what the engine work needs on the main thread; the returned
    // closure runs on the engine queue.
    private func makeJob(_ before: String) -> () -> (snapshot: Snapshot, prepared: (before: String, fix: String?)?) {
        let c = context(before)
        let settings = self.settings
        let protected = protectedWord
        let engine = self.engine
        return {
            let start = DispatchTime.now().uptimeNanoseconds
            var words = c.typed.isEmpty ? engine.nextWord(prev: c.prev, prev2: c.prev2)
                                        : engine.suggest(c.typed, prev: c.prev, prev2: c.prev2)
            if c.typed.isEmpty && words.count < 3 {
                // Nothing (or little) follows from the context: never an empty bar.
                for w in engine.commonWords() where !words.contains(w) && words.count < 3 { words.append(w) }
            }
            let fix = Composer.correction(for: c, engine: engine, settings: settings, protected: protected)
            let issue = Composer.grammarIssue(before, engine: engine, settings: settings)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            return (Snapshot(suggestions: words,
                             grammarFix: issue.map { GrammarFix(from: $0.issue.from, to: $0.issue.to) },
                             correction: fix, typed: c.typed,
                             milliseconds: ms),
                    c.typed.isEmpty ? nil : (before, fix))
        }
    }

    private func context(_ before: String) -> TypingContext {
        let ctx = TypingContext(before: before)
        if settings.scriptMode, let t = trail, before.dropLast(ctx.typed.count).hasSuffix(t.tail) {
            return TypingContext(typed: ctx.typed, prev: t.words.last, prev2: t.words.count > 1 ? t.words[0] : nil)
        }
        return ctx
    }

    // Engine queue only.
    private static func correction(for c: TypingContext, engine: Engine, settings: KeyboardSettings,
                                   protected: String?) -> String? {
        if !settings.autocorrect || c.typed.isEmpty || c.typed == protected { return nil }
        return engine.correct(c.typed, prev: c.prev, prev2: c.prev2).map { matchCase(c.typed, $0) }
    }

    /// True where a sentence starts, so the keyboard can raise shift.
    public static func isSentenceStart(_ before: String) -> Bool {
        guard let last = before.last(where: { $0 != " " }) else { return true }
        if last.isNewline { return true }
        return ".!?".contains(last) && before.last == " "
    }

    // Engine queue only. The last agreement problem in the sentence before
    // the cursor, if fixing it only touches plain ASCII (one deleteBackward
    // per character is only certain there). `tail` is the text from the
    // problem word on.
    private static func grammarIssue(_ before: String, engine: Engine,
                                     settings: KeyboardSettings) -> (issue: Grammar.Issue, tail: String)? {
        if !settings.grammar || settings.scriptMode { return nil }
        // Rules never look past sentence punctuation, so neither do we. The
        // sentence is the one holding the last word, even when the cursor
        // already sits after its "? ".
        guard let lastLetter = before.lastIndex(where: { $0.isLetter }) else { return nil }
        let start = before[..<lastLetter].lastIndex(where: { ".!?".contains($0) || $0.isNewline })
            .map { before.index(after: $0) }
        let sentence = String(before[(start ?? before.startIndex)...])
        guard let issue = Grammar.check(sentence, engine: engine).last else { return nil }
        let tail = String(sentence[issue.range.lowerBound...])
        return tail.allSatisfy({ $0.isASCII }) ? (issue, tail) : nil
    }

    // ---------- keys ----------

    public func type(_ text: String) {
        lastCorrection = nil
        justTyped = nil
        insert(text)
    }

    /// Long press with fast keys: the letter just typed becomes its alternate.
    public func replaceLast(with text: String) {
        lastCorrection = nil
        deleteBackward()
        insert(text)
    }

    public func newline() {
        lastCorrection = nil
        justTyped = nil
        insert("\n")
    }

    public func space() {
        let before = currentText()
        let c = context(before)
        lastCorrection = nil
        if c.typed.isEmpty {
            // Double space: ". " after a word, as the system keyboard does.
            let chars = Array(before.suffix(2))
            if chars.count == 2, chars[1] == " ", chars[0].isLetter || chars[0].isNumber {
                deleteBackward()
                insert(". ")
            } else {
                insert(" ")
            }
            return
        }
        let fix: String?
        if let ready = prepared, ready.before == before {
            fix = ready.fix
        } else {
            let (engine, settings, protected) = (self.engine, self.settings, protectedWord)
            fix = queue.sync { Composer.correction(for: c, engine: engine, settings: settings, protected: protected) }
        }
        prepared = nil
        protectedWord = nil
        let inserted = commit(fix ?? c.typed, replacing: c, force: fix != nil)
        if fix != nil { lastCorrection = (c.typed, inserted) }
    }

    public func backspace() {
        if let last = lastCorrection, currentText().hasSuffix(last.corrected + " ") {
            if last.corrected.allSatisfy({ $0.isASCII }) {
                for _ in 0..<(last.corrected.count + 1) { deleteBackward() }
            } else {
                deleteExactly(last.corrected + " ")
            }
            insert(last.original)
            protectedWord = last.original
            // Restoring the same word twice teaches it; it is then never corrected.
            teachOnSecondRestore(last.original)
            lastCorrection = nil
            return
        }
        lastCorrection = nil
        if let typed = justTyped, currentText().hasSuffix(typed.inserted) {
            let engine = self.engine
            queue.async { engine.unobserve(typed.word) }
        }
        justTyped = nil
        deleteBackward()
    }

    /// The bar's left slot while a correction is pending: keep the word
    /// exactly as typed. Counts like restoring it after a correction, so
    /// doing it twice teaches the word.
    public func keepTyped() {
        let c = context(currentText())
        if c.typed.isEmpty { return }
        lastCorrection = nil
        prepared = nil
        protectedWord = nil
        _ = commit(c.typed, replacing: c, force: false)
        teachOnSecondRestore(c.typed)
    }

    private func teachOnSecondRestore(_ word: String) {
        let key = Engine.cleanSurface(word)
        restoreCounts[key, default: 0] += 1
        if restoreCounts[key] == 2 {
            let engine = self.engine
            queue.async { engine.learnWord(key, count: 2) }
        }
    }

    /// The user tapped a word on the suggestion bar.
    public func take(_ suggestion: String) {
        let c = context(currentText())
        lastCorrection = nil
        protectedWord = nil
        _ = commit(Composer.matchCase(c.typed, suggestion), replacing: c, force: true, chosen: true)
    }

    public func applyGrammarFix() {
        let (engine, settings, before) = (self.engine, self.settings, currentText())
        guard let (issue, tail) = queue.sync(execute: { Composer.grammarIssue(before, engine: engine, settings: settings) })
        else { return }
        lastCorrection = nil
        for _ in 0..<tail.count { deleteBackward() }
        insert(issue.to + tail.dropFirst(issue.from.count))
    }

    // ---------- personal dictionary ----------

    public func personalData() -> PersonalData {
        queue.sync { engine.personal }
    }

    public func loadPersonal(_ data: PersonalData) {
        queue.sync { engine.loadPersonal(data) }
    }

    public func forgetPersonal() {
        queue.sync { engine.forgetPersonal() }
        restoreCounts = [:]
        generation += 1
    }

    /// Gujarati-script form of a word, as script mode would insert it.
    public func script(for word: String) -> String? {
        queue.sync { engine.script(for: word) }
    }

    // ---------- helpers ----------

    // Puts `word` and a space where the half-typed word is. The typed
    // letters are ASCII, so deleting them one by one is exact.
    // Returns the word as it went into the document (script form in script mode).
    private func commit(_ word: String, replacing c: TypingContext, force: Bool, chosen: Bool = false) -> String {
        let script = settings.scriptMode ? script(for: word) : nil
        let out = script ?? word
        if force || script != nil {
            for _ in 0..<c.typed.count { deleteBackward() }
            insert(out + " ")
        } else {
            insert(" ")
        }
        let engine = self.engine
        queue.async { engine.observe(word, prev: c.prev, prev2: c.prev2, chosen: chosen) }   // learning can wait
        justTyped = chosen || force ? nil : (word, out + " ")
        if settings.scriptMode {
            let clean = Engine.cleanSurface(word)
            trail = (out + " ", Array(([c.prev2, c.prev].compactMap { $0 } + [clean]).suffix(2)))
        }
        return out
    }

    static func matchCase(_ typed: String, _ word: String) -> String {
        guard let first = typed.first, first.isUppercase else { return word }
        if typed.count > 1 && typed == typed.uppercased() { return word.uppercased() }
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}
