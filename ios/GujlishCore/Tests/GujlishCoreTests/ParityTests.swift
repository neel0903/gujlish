// The Swift port against the Python reference and the JavaScript port.
// Reads web/expected.json (python3 build_site.py), web/golden.tsv and
// gujlish.db (python3 build_db.py lexicon.tsv) from the repo root.

import XCTest
@testable import GujlishCore

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

final class ParityTests: XCTestCase {
    static var expected: [String: Any] = [:]
    static var lexicon: Lexicon!

    override class func setUp() {
        let data = FileManager.default.contents(atPath: repoRoot.appendingPathComponent("web/expected.json").path)
        expected = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        lexicon = try? Lexicon(path: repoRoot.appendingPathComponent("gujlish.db").path)
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.expected.isEmpty, "web/expected.json missing: run python3 build_site.py")
        try XCTSkipIf(Self.lexicon == nil, "gujlish.db missing: run python3 build_db.py lexicon.tsv")
    }

    private func mixedEngine() -> Engine { Engine(lexicon: Self.lexicon) }

    private func referenceEngine() -> Engine {
        let e = Engine(lexicon: Self.lexicon)
        e.mode = .gujlish   // the Python reference has no English list
        return e
    }

    // Rows are [surface, strictPrefix, loosePrefix, strictWord, looseWord].
    func testPhoneticKeys() {
        let keys = (Self.expected["keys"] as? [[String]] ?? []) + (Self.expected["probeKeys"] as? [[String]] ?? [])
        XCTAssertGreaterThan(keys.count, 80_000)
        var bad: [String] = []
        for row in keys {
            let s = row[0]
            let got = [Phonetics.strictKey(s, prefix: true), Phonetics.looseKey(s, prefix: true),
                       Phonetics.strictKey(s), Phonetics.looseKey(s)]
            if got != Array(row[1...4]) { bad.append(s) }
        }
        XCTAssertTrue(bad.isEmpty, "\(bad.count) words key differently, e.g. \(bad.prefix(10))")
    }

    func testTrials() {
        let engine = referenceEngine()
        let trials = Self.expected["trials"] as? [[String: Any]] ?? []
        XCTAssertFalse(trials.isEmpty)
        for t in trials {
            let typed = t["typed"] as? String ?? "", prev = t["prev"] as? String, prev2 = t["prev2"] as? String
            let got = typed.isEmpty ? engine.nextWord(prev: prev, prev2: prev2) : engine.suggest(typed, prev: prev, prev2: prev2)
            XCTAssertEqual(got, t["result"] as? [String] ?? [], "[\(prev2 ?? "") \(prev ?? "")] \"\(typed)\"")
        }
    }

    func testCorrections() {
        let engine = referenceEngine()
        let corrections = Self.expected["corrections"] as? [[String: Any]] ?? []
        XCTAssertFalse(corrections.isEmpty)
        for c in corrections {
            let typed = c["typed"] as? String ?? ""
            let got = engine.correct(typed, prev: c["prev"] as? String, prev2: c["prev2"] as? String)
            XCTAssertEqual(got, c["result"] as? String, "\"\(typed)\"")
        }
    }

    // Beyond the Python reference, as in web/test_port.js.
    func testMixedModeAndPersonalWords() throws {
        let mixed = mixedEngine()
        XCTAssertTrue(mixed.suggestDetailed("kem").sources.values.allSatisfy { $0 != .english })
        let meet = mixed.suggestDetailed("meet")
        XCTAssertTrue(meet.surfaces.contains { meet.sources[$0] == .english }, "\(meet.surfaces)")
        mixed.mode = .gujlish
        XCTAssertTrue(mixed.suggestDetailed("meet").sources.values.allSatisfy { $0 != .english })
        mixed.mode = .mixed

        XCTAssertNil(Self.lexicon.word(surface: "neelbhai"))
        mixed.learnWord("neelbhai", count: 3)
        XCTAssertEqual(mixed.suggestDetailed("neelbh").sources["neelbhai"], .personal)
        mixed.learnBigram("kem", "neelbhai", count: 5)
        XCTAssertTrue(mixed.nextWord(prev: "kem").contains("neelbhai"))
        mixed.learnTrigram("kem", "cho", "neelbhai", count: 4)
        XCTAssertEqual(mixed.nextWord(prev: "cho", prev2: "kem").first, "neelbhai")
        XCTAssertFalse(mixed.nextWord(prev: "cho").contains("neelbhai"), "trigram needs both words")
        for _ in 0..<3 { mixed.accept("thashe", prev: "kem") }
        XCTAssertEqual(mixed.suggest("th", prev: "kem").first, "thashe")

        let snapshot = mixed.personal
        mixed.forgetPersonal()
        XCTAssertEqual(mixed.suggest("th", prev: "kem"), mixedEngine().suggest("th", prev: "kem"))
        XCTAssertNotEqual(mixed.nextWord(prev: "cho", prev2: "kem").first, "neelbhai")

        let back = try JSONDecoder().decode(PersonalData.self, from: JSONEncoder().encode(snapshot))
        mixed.loadPersonal(back)
        XCTAssertEqual(mixed.personal, snapshot)
        XCTAssertEqual(mixed.suggest("th", prev: "kem").first, "thashe")
    }

    // The user's own spec for autocorrect.
    func testAutocorrectSpec() {
        let mixed = mixedEngine()
        var prev: String?, prev2: String?, fixed: [String] = []
        for w in ["Avi", "gaye", "ghara"] {
            let f = mixed.correct(w, prev: prev, prev2: prev2) ?? w
            fixed.append(f); prev2 = prev; prev = f
        }
        XCTAssertEqual(fixed, ["aavi", "gaya", "ghare"])
        XCTAssertNil(mixed.correct("meeting"))
        XCTAssertNil(mixed.correct("gate"))
        XCTAssertNil(mixed.correct("kem"))
        XCTAssertNil(mixed.correct("cho", prev: "kem"))
        mixed.learnWord("bhabhiji", count: 2)
        XCTAssertNil(mixed.correct("bhabhiji"), "a taught word is never corrected")
    }

    func testGrammarRules() {
        let engine = mixedEngine()
        let rules = [
            ("hu ghare gayo cho", "cho>chu"), ("tame kem che", "che>cho"), ("ame majama chu", "chu>chie"),
            ("tu su kare cho", "cho>che"), ("e ghare che", ""), ("su karo cho", ""),
            ("hu ane tame majama cho", "cho>chie"), ("hu manu chu ke tame saras cho", ""),
            ("hu ghare gayo chu. tame kem cho?", ""), ("Hu ghare Cho", "Cho>Chu"),
            ("hu kale jashe", "jashe>jaish"), ("tame kale jaish", "jaish>jasho"),
            ("ame kale jashe", "jashe>jaishu"), ("te kale jaish", "jaish>jashe"),
            ("hu english finish karish", ""), ("ame kale gayo", "gayo>gaya"),
            ("tame kyare aavyo", "aavyo>aavya"), ("e kale gayo", ""), ("hu ghare hashe", "hashe>hoish"),
            ("tame kale hashe", "hashe>hasho"), ("tame majama chhu", "chhu>cho"),
            ("hu avyo tyare varsad che", ""), ("hu nano hato jyare e ahi che", ""),
            ("hu avu chu athva e ave che", ""), ("badha majama cho", "cho>che"),
            ("tame badha majama cho", ""), ("ame badha majama che", "che>chie"),
            ("ame tya hato", "hato>hata"), ("tame kya hato", "hato>hata"),
            ("e ghare hato", ""), ("hu ghare hati", ""),
        ]
        for (text, want) in rules {
            let got = Grammar.check(text, engine: engine).map { $0.from + ">" + $0.to }.joined(separator: ",")
            XCTAssertEqual(got, want, text)
        }
        let gaya = Grammar.check("hu kale gaya", engine: engine)
        XCTAssertEqual(gaya.count, 1)
        XCTAssertEqual(gaya.first?.to, "gayo")
        XCTAssertEqual(gaya.first?.alt, "gayi")
        let hata = Grammar.check("hu ghare hata", engine: engine)
        XCTAssertEqual(hata.first?.to, "hato")
        XCTAssertEqual(hata.first?.alt, "hati")
        XCTAssertEqual(Grammar.fixAll("hu ghare gayo cho ane tame kem che", engine: engine),
                       "hu ghare gayo chu ane tame kem cho")
    }

    func testReverse() {
        let cases = [("ghar", "ઘર"), ("kem", "કેમ"), ("chhun", "છું"), ("sambandh", "સંબંધ"), ("pravin", "પ્રવિન"),
                     ("neel", "નીલ"), ("aavjo", "આવજો"), ("thayu", "થયુ"), ("kanya", "કન્યા"), ("bhai", "ભાઈ"),
                     ("paisa", "પૈસા"), ("dikra", "દિકરા"), ("chokra", "ચોકરા")]
        for (w, want) in cases { XCTAssertEqual(Reverse.toGujarati(w), want, w) }
        XCTAssertNotNil(Self.lexicon.native(surface: "kem"))
    }

    // Golden sentences: the full commit pipeline (autocorrect each word,
    // then grammar), against web/golden.tsv.
    func testGoldenSentences() throws {
        let engine = mixedEngine()
        func pipeline(_ text: String) -> String {
            var out = "", prev: String?, prev2: String?
            var i = text.startIndex
            while i < text.endIndex {
                let start = i
                let space = text[i].isWhitespace
                while i < text.endIndex && text[i].isWhitespace == space { i = text.index(after: i) }
                let p = String(text[start..<i])
                let clean = Engine.cleanSurface(p)
                if space || clean.isEmpty { out += p; continue }
                let fix = engine.correct(p, prev: prev, prev2: prev2)
                if let fix = fix {
                    let head = p.prefix { $0.isASCII && $0.isLetter }
                    let capital = p.first.map { $0 >= "A" && $0 <= "Z" } ?? false
                    out += (capital ? fix.prefix(1).uppercased() + fix.dropFirst() : fix) + p.dropFirst(head.count)
                } else {
                    out += p
                }
                prev2 = prev; prev = fix ?? clean
            }
            return Grammar.fixAll(out, engine: engine)
        }
        let file = try String(contentsOf: repoRoot.appendingPathComponent("web/golden.tsv"), encoding: .utf8)
        let golden = file.split(whereSeparator: { $0.isNewline }).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }.filter { $0.count >= 2 }
        XCTAssertFalse(golden.isEmpty)
        for g in golden { XCTAssertEqual(pipeline(g[0]), g[1], g[0]) }
    }
}
