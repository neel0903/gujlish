// The sentence fixer: the gate against the cases in lane2/gate.py, and
// the Core ML graphs (compiled here from lane2/models) against the
// sentences correct.py was checked with.

import XCTest
@testable import GujlishCore
#if canImport(CoreML)
import CoreML
#endif

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

final class SentenceFixerTests: XCTestCase {
    private var gate: FixGate!

    override func setUpWithError() throws {
        let db = repoRoot.appendingPathComponent("gujlish.db").path
        let vocab = repoRoot.appendingPathComponent("ios/Assets/fix_vocab.txt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: db), "gujlish.db missing")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: vocab.path), "run python3 build_ios_assets.py")
        gate = try FixGate(vocabularyFile: vocab, lexicon: try Lexicon(path: db))
    }

    func testOSA() {
        XCTAssertEqual(FixGate.osa("thyau", "thayu"), 1)
        XCTAssertEqual(FixGate.osa("kem", "kem"), 0)
        XCTAssertEqual(FixGate.osa("john", "jo"), 2)
    }

    // Same table as `python3 lane2/gate.py`.
    func testGate() {
        let cases: [(String, String, String)] = [
            ("kem cho majama su thyu", "kem cho majama su thayu", "kem cho majama su thayu"),
            ("john ne kaho", "jo nemakaho", "john ne kaho"),
            ("good night thanks", "gud nighat thani", "good night thanks"),
            ("kemcho majama", "kem cho majama", "kem cho majama"),
            ("hu ghrejau chu", "hu ghare jau chu", "hu ghare jau chu"),
            ("sun thyu", "su thayu", "su thayu"),
            ("Neel ne kaho", "nel ne kaho", "neel ne kaho"),
            ("tamne kabar nathee", "tamne khabar nathi", "tamne khabar nathi"),
        ]
        for (src, model, want) in cases {
            XCTAssertEqual(gate.apply(src, model), want, src)
        }
    }

    func testSegmentsKeepPunctuationAndCase() {
        let fixer = SegmentFixer(gate: gate) { run in
            ["hu ghare jau chhu": "hu ghare jau chu", "kale malsu": "kale malsu",
             "john ne kaho good night": "jo nemakaho gud nighat"][run] ?? run
        }
        XCTAssertEqual(fixer.fix("Hu ghare jau chhu, kale malsu. John ne kaho good night"),
                       "Hu ghare jau chu, kale malsu. John ne kaho good night")
        XCTAssertEqual(fixer.fix("123 😀"), "123 😀")
    }

    #if canImport(CoreML)
    func testCoreMLMatchesTheCLI() throws {
        let models = repoRoot.appendingPathComponent("lane2/models")
        let encPkg = models.appendingPathComponent("GujlishEncoder.mlpackage")
        let decPkg = models.appendingPathComponent("GujlishDecoder.mlpackage")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: encPkg.path), "run python3 lane2/convert_coreml.py")
        let enc = try MLModel.compileModel(at: encPkg)
        let dec = try MLModel.compileModel(at: decPkg)
        let core = try CoreMLFixer(encoder: enc, decoder: dec, computeUnits: .cpuOnly)
        let raw = core.decode("kem cho majama su thyu")
        XCTAssertEqual(raw, "kem cho majama su thayu", "raw decode; error: \(String(describing: core.lastError))")
        let fixer = core.fixer(gate: gate)
        let cases = [
            ("kem cho majama su thyu", "kem cho majama su thayu"),
            ("Hu ghare jau chhu, kale malsu. John ne kaho good night", "Hu ghare jau chu, kale malsu. John ne kaho good night"),
            ("tamne kabar nathee ke su thyu", "tamne khabar nathi ke su thayu"),
            ("mjama chu tame kem cho", "majama chu tame kem cho"),
            ("thayoo che", "thayu che"),
            ("majaama chhu", "majama chu"),
            ("hu pan avu chu", "hu pan aavu chu"),
            ("aaje office ma kaam bahu che", "aaje office ma kaam bahu che"),
        ]
        let start = Date()
        for (src, want) in cases { XCTAssertEqual(fixer.fix(src), want, src) }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(cases.count)
        print("Core ML fixer: \(Int(ms)) ms per message on this Mac (CPU only)")
    }
    #endif
}
