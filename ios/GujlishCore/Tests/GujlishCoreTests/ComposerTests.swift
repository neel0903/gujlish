// Every typing behaviour of the keyboard, against a fake document.

import XCTest
import GujlishCore

final class FakeDocument: TextDocument {
    var textBefore = ""
    func insert(_ text: String) { textBefore += text }
    func deleteBackward() { if !textBefore.isEmpty { textBefore.removeLast() } }
}

final class ComposerTests: XCTestCase {
    private var doc: FakeDocument!
    private var composer: Composer!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let db = root.appendingPathComponent("gujlish.db").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: db), "gujlish.db missing: run python3 build_db.py lexicon.tsv")
        doc = FakeDocument()
        composer = Composer(engine: Engine(lexicon: try Lexicon(path: db)), document: doc)
    }

    // The app empties the field (a sent message) and says so, as iOS does.
    private func clearField() {
        doc.textBefore = ""
        composer.documentChanged()
    }

    private func type(_ s: String) {
        for c in s { c == " " ? composer.space() : composer.type(String(c)) }
    }

    func testPlainTypingIsUntouched() {
        type("kem cho ")
        XCTAssertEqual(doc.textBefore, "kem cho ")
    }

    func testSuggestionsFollowTheText() {
        var now = 0.0
        composer.clock = { now }
        type("kem ch")
        XCTAssertEqual(composer.suggestions().first, "cho")
        type("o ")
        XCTAssertFalse(composer.suggestions().isEmpty, "next-word prediction after a space")
        type("x")
        now += 0.3                       // the user reaches for "send"; the app empties the field
        clearField()
        XCTAssertFalse(composer.suggestions().contains("kimi"), "predictions for the old text are gone")
    }

    func testTakeReplacesTheHalfTypedWord() {
        type("kem ch")
        composer.take("cho")
        XCTAssertEqual(doc.textBefore, "kem cho ")
        composer.take("majama")
        XCTAssertEqual(doc.textBefore, "kem cho majama ")
    }

    func testTakeKeepsCapital() {
        type("Ke")
        composer.take("kem")
        XCTAssertEqual(doc.textBefore, "Kem ")
    }

    func testAutocorrectOnSpace() {
        type("Avi gaye ghara ")
        XCTAssertEqual(doc.textBefore, "Aavi gaya ghare ")
    }

    func testBackspaceUndoesAutocorrect() {
        type("gharey ")
        XCTAssertEqual(doc.textBefore, "ghare ")
        composer.backspace()
        XCTAssertEqual(doc.textBefore, "gharey")
        composer.space()
        XCTAssertEqual(doc.textBefore, "gharey ", "a restored word is kept as typed")
        composer.backspace()
        XCTAssertEqual(doc.textBefore, "gharey", "second backspace is a plain delete")
    }

    func testUndoOnlyRightAfterTheCorrection() {
        type("gharey a")
        composer.backspace()
        composer.backspace()
        XCTAssertEqual(doc.textBefore, "ghare")
    }

    func testRestoringTwiceTeachesTheWord() {
        for _ in 0..<2 {
            type("gharey ")
            composer.backspace()
            composer.space()
        }
        clearField()
        type("gharey ")
        XCTAssertEqual(doc.textBefore, "gharey ")
    }

    func testAutocorrectCanBeSwitchedOff() {
        composer.settings.autocorrect = false
        type("gharey ")
        XCTAssertEqual(doc.textBefore, "gharey ")
    }

    func testEnglishIsLeftAlone() {
        type("meeting che ")
        XCTAssertEqual(doc.textBefore, "meeting che ")
    }

    func testDoubleSpacePeriod() {
        type("kem cho  ")
        XCTAssertEqual(doc.textBefore, "kem cho. ")
        composer.space()
        XCTAssertEqual(doc.textBefore, "kem cho.  ", "no second period")
        clearField()
        type("  ")
        XCTAssertEqual(doc.textBefore, "  ")
    }

    func testSentenceStart() {
        XCTAssertTrue(Composer.isSentenceStart(""))
        XCTAssertTrue(Composer.isSentenceStart("  "))
        XCTAssertTrue(Composer.isSentenceStart("kem cho. "))
        XCTAssertTrue(Composer.isSentenceStart("kem cho?\n"))
        XCTAssertFalse(Composer.isSentenceStart("kem cho."))
        XCTAssertFalse(Composer.isSentenceStart("kem "))
        XCTAssertFalse(Composer.isSentenceStart("kem"))
    }

    func testGrammarFix() {
        type("tame kem che")
        XCTAssertEqual(composer.grammarFix()?.from, "che")
        XCTAssertEqual(composer.grammarFix()?.to, "cho")
        composer.applyGrammarFix()
        XCTAssertEqual(doc.textBefore, "tame kem cho")
        XCTAssertNil(composer.grammarFix())
    }

    func testGrammarFixKeepsWhatFollows() {
        type("tame kem che? ")
        composer.applyGrammarFix()
        XCTAssertEqual(doc.textBefore, "tame kem cho? ")
    }

    func testGrammarFixSkipsNonAsciiTail() {
        doc.textBefore = "tame kem che 👍"
        XCTAssertNil(composer.grammarFix())
        composer.applyGrammarFix()
        XCTAssertEqual(doc.textBefore, "tame kem che 👍")
        composer.settings.grammar = false
        doc.textBefore = "tame kem che"
        XCTAssertNil(composer.grammarFix())
    }

    func testScriptMode() {
        composer.settings.scriptMode = true
        type("kem ch")
        XCTAssertEqual(doc.textBefore, "કેમ ch")
        XCTAssertEqual(composer.suggestions().first, "cho", "context survives the script change")
        composer.take("cho")
        XCTAssertEqual(doc.textBefore, "કેમ છો ")
        type("because ")
        XCTAssertEqual(doc.textBefore, "કેમ છો because ", "English stays in Latin")
        composer.backspace()
        XCTAssertEqual(doc.textBefore, "કેમ છો because")
    }

    func testScriptModeCorrectsBeforeConverting() {
        composer.settings.scriptMode = true
        type("gharey ")
        let ghare = composer.script(for: "ghare")
        XCTAssertNotNil(ghare)
        XCTAssertEqual(doc.textBefore, ghare! + " ")
    }

    // ---------- learning ----------

    func testUnknownWordNeedsThreeOccasions() {
        type("neelbhai neelbhai ")
        clearField()
        type("neelb")
        XCTAssertFalse(composer.suggestions().contains("neelbhai"), "twice is not yet trusted")
        clearField()
        type("neelbhai ")
        clearField()
        type("neelb")
        XCTAssertEqual(composer.suggestions().first, "neelbhai")
    }

    func testATypoIsNotLearned() {
        composer.settings.autocorrect = false          // so the typo goes in as typed
        for _ in 0..<4 { type("ghaare ") }             // looks like a slip of ghare: needs six
        clearField()
        type("ghaa")
        XCTAssertFalse(composer.suggestions().contains("ghaare"))
    }

    func testDeletingAWordAtOnceWithdrawsIt() {
        for _ in 0..<5 {
            clearField()
            type("xqzwv ")
            composer.backspace()                       // the user thinks again, every time
        }
        XCTAssertNil(composer.personalData().words["xqzwv"])
        XCTAssertNil(composer.personalData().pending["xqzwv"])
    }

    func testAChosenWordCountsAtOnce() {
        type("maj")
        composer.take("majama")
        XCTAssertEqual(composer.personalData().words["majama"], 1)
    }

    func testKnownWordsAndPairsAreLearnedAtOnce() {
        type("kem cho ")
        let data = composer.personalData()
        XCTAssertEqual(data.words["cho"], 1)
        XCTAssertEqual(data.bigrams["kem cho"], 1)
        XCTAssertTrue(data.pending.isEmpty)
    }

    func testNoPairsWithUntrustedWords() {
        type("kem xqzwv cho ")
        let data = composer.personalData()
        XCTAssertNil(data.bigrams["kem xqzwv"])
        XCTAssertNil(data.bigrams["xqzwv cho"])
        XCTAssertEqual(data.pending["xqzwv"], 1)
    }

    // ---------- the bar while a correction is pending ----------

    func testBarOffersTheCorrectionAndTheWordAsTyped() {
        type("gharey")
        let s = composer.snapshot()
        XCTAssertEqual(s.correction, "ghare")
        XCTAssertEqual(s.typed, "gharey")
        type("kem")
        XCTAssertNil(composer.snapshot().correction)
    }

    func testKeepTyped() {
        type("gharey")
        composer.keepTyped()
        XCTAssertEqual(doc.textBefore, "gharey ")
        type("gharey")
        composer.keepTyped()                           // the second time teaches it
        clearField()
        type("gharey ")
        XCTAssertEqual(doc.textBefore, "gharey ")
    }

    func testBarIsNeverEmptyBetweenWords() {
        XCTAssertEqual(composer.suggestions().count, 3, "empty field")
        type("xqzwv ")
        XCTAssertEqual(composer.suggestions().count, 3, "after a word nothing is known about")
        type("kem ")
        XCTAssertEqual(composer.suggestions().first, "cho", "real predictions still come first")
    }

    func testReplaceLast() {
        type("kem q")
        composer.replaceLast(with: "1")
        XCTAssertEqual(doc.textBefore, "kem 1")
    }

    func testOldSettingsStillLoad() throws {
        let old = #"{"autocorrect":false,"grammar":true,"scriptMode":true,"english":false}"#
        let settings = try JSONDecoder().decode(KeyboardSettings.self, from: Data(old.utf8))
        XCTAssertFalse(settings.autocorrect)
        XCTAssertTrue(settings.scriptMode)
        XCTAssertFalse(settings.english)
        XCTAssertTrue(settings.fastKeys, "a key the old version did not know keeps its default")
        let again = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again, settings)
    }

    func testPersonalStoreRoundTrip() throws {
        type("kem neelbhai ")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gujlish-\(UUID().uuidString)/personal.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PersonalStore(url: url)
        XCTAssertNil(store.load())
        try store.save(composer.personalData())
        XCTAssertEqual(store.load(), composer.personalData())
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(store.load(), "a damaged file is ignored, not fatal")
    }
}

extension ComposerTests {
    // The bar refresh prepares the correction; the space key must give the
    // same result whether or not a refresh happened in between.
    func testPreparedCorrectionMatchesDirect() {
        for refresh in [true, false] {
            clearField()
            for c in "aavi gaye" {
                c == " " ? composer.space() : composer.type(String(c))
                if refresh { _ = composer.snapshot() }
            }
            composer.space()
            XCTAssertEqual(doc.textBefore, "aavi gaya ", "refresh: \(refresh)")
        }
    }

    func testStalePreparedCorrectionIsIgnored() {
        type("gharey")
        _ = composer.snapshot()
        doc.textBefore = "kem"          // the host moved the cursor
        composer.space()
        XCTAssertEqual(doc.textBefore, "kem ")
    }

    func testSnapshot() {
        type("tame kem che")
        let s = composer.snapshot()
        XCTAssertEqual(s.grammarFix?.to, "cho")
        XCTAssertFalse(s.suggestions.isEmpty)
    }

    func testGrammarLooksAtTheLastSentenceOnly() {
        type("tame kem che. hu majama chu")
        XCTAssertNil(composer.grammarFix())
        doc.textBefore = "👍 ok. tame kem che"
        composer.applyGrammarFix()
        XCTAssertEqual(doc.textBefore, "👍 ok. tame kem cho")
    }

    // The background refresh must agree with the immediate one, and an
    // answer for a text that has since changed must never arrive.
    func testBackgroundRefresh() {
        type("kem ch")
        let done = expectation(description: "refresh")
        composer.refresh { snapshot in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(snapshot.suggestions.first, "cho")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let stale = expectation(description: "stale refresh is dropped")
        stale.isInverted = true
        composer.refresh { _ in stale.fulfill() }
        composer.type("o")
        let fresh = expectation(description: "fresh refresh")
        composer.refresh { _ in fresh.fulfill() }
        wait(for: [stale, fresh], timeout: 2)
    }

    // Keys hammered while refreshes are in flight: nothing lost, nothing reordered.
    func testTypingWhileRefreshing() {
        for c in "tame kem cho majama chu " {
            c == " " ? composer.space() : composer.type(String(c))
            composer.refresh { _ in }
        }
        XCTAssertEqual(doc.textBefore, "tame kem cho majama chu ")
        let settled = expectation(description: "settled")
        composer.refresh { _ in settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }
}

// A host that deletes one code point at a time, as iOS does with Gujarati
// (measured with the keyboard's probe: ક્ષ takes three deletes).
private final class CodePointDocument: TextDocument {
    var textBefore = ""
    var deletes = 0
    func insert(_ text: String) { textBefore += text }
    func deleteBackward() {
        deletes += 1
        var scalars = textBefore.unicodeScalars
        if !scalars.isEmpty { scalars.removeLast() }
        textBefore = String(scalars)
    }
}

final class ScriptUndoTests: XCTestCase {
    private func makeComposer(_ doc: TextDocument) throws -> Composer {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let db = root.appendingPathComponent("gujlish.db").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: db), "gujlish.db missing")
        let composer = Composer(engine: Engine(lexicon: try Lexicon(path: db)), document: doc)
        composer.settings.scriptMode = true
        return composer
    }

    private func type(_ s: String, _ composer: Composer) {
        for c in s { c == " " ? composer.space() : composer.type(String(c)) }
    }

    // Both kinds of host must end with exactly the text before the
    // correction, plus the word as it was typed.
    func testUndoInScriptMode() throws {
        let byCluster = FakeDocument(), byCodePoint = CodePointDocument()
        for doc in [byCluster, byCodePoint] as [TextDocument] {
            let composer = try makeComposer(doc)
            type("kem gharey ", composer)
            let kem = try XCTUnwrap(composer.script(for: "kem")), ghare = try XCTUnwrap(composer.script(for: "ghare"))
            XCTAssertEqual(doc.textBefore, kem + " " + ghare + " ")
            composer.backspace()
            XCTAssertEqual(doc.textBefore, kem + " gharey")
            composer.space()
            let asTyped = try XCTUnwrap(composer.script(for: "gharey"))
            XCTAssertNotEqual(asTyped, ghare)
            XCTAssertEqual(doc.textBefore, kem + " " + asTyped + " ", "a restored word is converted as typed, not corrected again")
        }
        XCTAssertGreaterThan(byCodePoint.deletes, 0)
    }

    func testUndoNeverDeletesPastTheCorrection() throws {
        let doc = CodePointDocument()
        let composer = try makeComposer(doc)
        doc.textBefore = "ક્ષ "                      // text the user already had
        type("gharey ", composer)
        composer.backspace()
        XCTAssertEqual(doc.textBefore, "ક્ષ gharey")
    }

    func testPlainBackspaceInScriptModeIsOneDelete() throws {
        let doc = CodePointDocument()
        let composer = try makeComposer(doc)
        type("kem ", composer)                        // no correction happened
        doc.deletes = 0
        composer.backspace()
        XCTAssertEqual(doc.deletes, 1)
    }
}

// A host whose report of the text lags behind what was typed: every read
// returns the text as it was `lag` edits ago.
private final class LaggyDocument: TextDocument {
    private var states = [""]
    var lag = 0
    var real: String { states[states.count - 1] }
    var textBefore: String { states[max(0, states.count - 1 - lag)] }
    func insert(_ text: String) { states.append(real + text) }
    func deleteBackward() { states.append(String(real.dropLast())) }
    func hostSets(_ text: String) { states = [text] }
}

final class LaggyDocumentTests: XCTestCase {
    private var doc: LaggyDocument!
    private var composer: Composer!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let db = root.appendingPathComponent("gujlish.db").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: db), "gujlish.db missing")
        doc = LaggyDocument()
        composer = Composer(engine: Engine(lexicon: try Lexicon(path: db)), document: doc)
    }

    private func type(_ s: String) {
        for c in s { c == " " ? composer.space() : composer.type(String(c)) }
    }

    func testFastTypingWithALaggingHost() {
        for lag in [1, 2, 3] {
            doc.hostSets("")
            composer.documentChanged()
            doc.lag = lag
            type("kem cho gharey ")
            XCTAssertEqual(doc.real, "kem cho ghare ", "lag \(lag)")
        }
    }

    func testUndoWithALaggingHost() {
        doc.lag = 2
        type("gharey ")
        composer.backspace()
        XCTAssertEqual(doc.real, "gharey")
    }

    func testSuggestionTakenWithALaggingHost() {
        doc.lag = 2
        type("kem ch")
        composer.take("cho")
        XCTAssertEqual(doc.real, "kem cho ")
    }

    // After the lag window the host's text is believed again, whatever it is.
    func testOldHistoryExpires() {
        var now = 0.0
        composer.clock = { now }
        type("kem")
        now += 5
        doc.hostSets("ke")               // equals a state we passed through, but long ago
        type("m ")
        XCTAssertEqual(doc.real, "kem ")
    }

    func testHostChangeWins() {
        type("kem ch")
        doc.hostSets("tame ")            // the user tapped elsewhere in the text
        composer.documentChanged()
        type("kem ")
        XCTAssertEqual(doc.real, "tame kem ")
    }

    func testHostChangeWinsEvenUnannounced() {
        type("kem ch")
        doc.hostSets("hu ")              // no documentChanged(): the text alone must tell
        type("majama ")
        XCTAssertEqual(doc.real, "hu majama ")
    }
}
