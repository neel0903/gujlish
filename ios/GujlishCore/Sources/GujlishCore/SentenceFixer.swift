// Lane 2: whole-sentence correction with the small character model from
// lane2/ (PyTorch -> Core ML). The keyboard offers the fixed sentence as
// a chip after each word; the container app has a Fix button.
//
// Every change goes through FixGate, the Swift twin of lane2/gate.py and
// the gate in lane2/web/index.html: a changed word is accepted only when
// the output is a word the model was trained on, the change is
// phonetically plausible, and the input is neither a mid-sentence
// Capitalised name nor an English word that outranks its Gujlish reading.

import Foundation
#if canImport(CoreML)
import CoreML
#endif

public protocol SentenceFixing: AnyObject {
    /// The message with its Gujlish words corrected. Punctuation, digits,
    /// emoji and anything the gate refuses are returned as they were.
    func fix(_ text: String) -> String
}

public final class FixGate {
    public static let segmentCap = 0.4
    private let ok: Set<String>
    private let lexicon: Lexicon

    /// `vocabulary`: the words the model may output (ios/Assets/fix_vocab.txt).
    public init(vocabulary: Set<String>, lexicon: Lexicon) {
        self.ok = vocabulary
        self.lexicon = lexicon
    }

    public convenience init(vocabularyFile: URL, lexicon: Lexicon) throws {
        let text = try String(contentsOf: vocabularyFile, encoding: .utf8)
        self.init(vocabulary: Set(text.split(whereSeparator: { $0.isNewline }).map(String.init)), lexicon: lexicon)
    }

    /// Optimal string alignment distance: an adjacent transposition counts as one edit.
    static func osa(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let n = a.count, m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[n][m]
    }

    static func osa(_ a: String, _ b: String) -> Int { osa(Array(a.utf8), Array(b.utf8)) }

    /// An English word that outranks its Gujlish reading ("john", "good").
    func keeps(_ word: String) -> Bool {
        guard word.utf8.count >= 3, let e = lexicon.englishFreq(word) else { return false }
        return e > (lexicon.word(surface: word)?.freq ?? 0)
    }

    func plausible(_ src: String, _ out: String) -> Bool {
        FixGate.osa(Phonetics.looseKey(src), Phonetics.looseKey(out)) <= 1 || FixGate.osa(src, out) <= 2
    }

    func wordOk(_ src: String, _ out: String) -> Bool {
        if src == out { return true }
        if !ok.contains(out) || !plausible(src, out) { return false }
        if keeps(src) && Phonetics.looseKey(src) != Phonetics.looseKey(out) { return false }
        return true
    }

    // Diff blocks on words, as the web page computes them (LCS).
    private static func opcodes(_ a: [String], _ b: [String]) -> [(equal: Bool, i1: Int, i2: Int, j1: Int, j2: Int)] {
        let n = a.count, m = b.count
        var L = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    L[i][j] = a[i] == b[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
                }
            }
        }
        var ops: [(equal: Bool, i1: Int, i2: Int, j1: Int, j2: Int)] = []
        var i = 0, j = 0, si = 0, sj = 0
        func flush() { if si < i || sj < j { ops.append((false, si, i, sj, j)) } }
        while i < n || j < m {
            if i < n && j < m && a[i] == b[j] {
                flush()
                ops.append((true, i, i + 1, j, j + 1))
                i += 1; j += 1; si = i; sj = j
            } else if j < m && (i >= n || L[i][j + 1] >= L[i + 1][j]) {
                j += 1
            } else {
                i += 1
            }
        }
        flush()
        return ops
    }

    private static func startsUpper(_ w: String) -> Bool {
        guard let f = w.unicodeScalars.first else { return false }
        return f >= "A" && f <= "Z"
    }

    /// `srcRaw` keeps the user's capitalisation; `out` is the model's
    /// lowercase output. Returns the gated lowercase segment.
    public func apply(_ srcRaw: String, _ out: String) -> String {
        let src = srcRaw.lowercased()
        if out.isEmpty { return src }
        let sw = src.split(separator: " ").map(String.init)
        let ow = out.split(separator: " ").map(String.init)
        let rw = srcRaw.split(separator: " ").map(String.init)
        if sw.isEmpty || ow.isEmpty { return src }
        var res: [String] = []
        for op in FixGate.opcodes(sw, ow) {
            let sb = Array(sw[op.i1..<op.i2]), ob = Array(ow[op.j1..<op.j2])
            if op.equal { res += sb; continue }
            if sb.count == ob.count {
                for (k, s) in sb.enumerated() {
                    let raw = op.i1 + k < rw.count ? rw[op.i1 + k] : ""
                    let named = FixGate.startsUpper(raw) && op.i1 + k > 0
                    res.append(!named && wordOk(s, ob[k]) ? ob[k] : s)
                }
                continue
            }
            let namedIn = (max(op.i1, 1)..<op.i2).contains { $0 < rw.count && FixGate.startsUpper(rw[$0]) }
            if !ob.isEmpty && ob.allSatisfy({ ok.contains($0) }) && !namedIn && !sb.contains(where: keeps)
                && FixGate.osa(Phonetics.looseKey(sb.joined()), Phonetics.looseKey(ob.joined())) <= 2 {
                res += ob
            } else {
                res += sb
            }
        }
        let gated = res.joined(separator: " ")
        return Double(FixGate.osa(src, gated)) > FixGate.segmentCap * Double(max(1, src.utf8.count)) ? src : gated
    }
}

/// Splits a message into runs of letters and spaces, fixes each run
/// through `model`, gates, and restores a leading capital. Shared by the
/// Core ML fixer and the tests' stand-in model.
public final class SegmentFixer: SentenceFixing {
    public static let maxChars = 64
    public typealias Model = (String) -> String?   // lowercase run -> lowercase output, nil on failure
    private let model: Model
    private let gate: FixGate
    private static let runs = try! NSRegularExpression(pattern: "[A-Za-z]+(?: +[A-Za-z]+)*")

    public init(gate: FixGate, model: @escaping Model) {
        self.gate = gate
        self.model = model
    }

    static func chunks(_ run: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for w in run.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if cur.isEmpty { cur = w }
            else if cur.utf8.count + 1 + w.utf8.count <= maxChars { cur += " " + w }
            else { out.append(cur); cur = w }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func fixRun(_ run: String) -> String {
        var pieces: [String] = []
        for ch in SegmentFixer.chunks(run) {
            let src = ch.lowercased()
            pieces.append(gate.apply(ch, model(src) ?? src))
        }
        var out = pieces.joined(separator: " ")
        if let f = run.unicodeScalars.first, f >= "A" && f <= "Z" {
            out = out.prefix(1).uppercased() + out.dropFirst()
        }
        if run.utf8.count > 1 && run == run.uppercased() { out = out.uppercased() }
        return out
    }

    public func fix(_ text: String) -> String {
        let ns = text as NSString
        var res = ""
        var last = 0
        for m in SegmentFixer.runs.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            res += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            res += fixRun(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return res + ns.substring(from: last)
    }
}

#if canImport(CoreML)
/// Greedy decoding through the two Core ML graphs.
public final class CoreMLFixer {
    public static let pad: Int32 = 0, bos: Int32 = 1, eos: Int32 = 2
    public static let maxPositions = 66
    private static let vocab: [Character] = Array("abcdefghijklmnopqrstuvwxyz ")
    private static let index: [Character: Int32] = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($1, Int32($0 + 3)) })
    private let encoder: MLModel
    private let decoder: MLModel
    /// The last Core ML failure, for diagnostics.
    public private(set) var lastError: Error?

    /// `encoder`/`decoder`: compiled model folders (.mlmodelc).
    public init(encoder: URL, decoder: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        self.encoder = try MLModel(contentsOf: encoder, configuration: cfg)
        self.decoder = try MLModel(contentsOf: decoder, configuration: cfg)
    }

    public func fixer(gate: FixGate) -> SegmentFixer {
        SegmentFixer(gate: gate) { [weak self] in self?.decode($0) }
    }

    private static func array(_ ids: [Int32]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (i, v) in ids.enumerated() { a[i] = NSNumber(value: v) }
        return a
    }

    /// Lowercase letters and spaces in, lowercase out; nil if Core ML fails.
    public func decode(_ text: String) -> String? {
        let ids = text.compactMap { CoreMLFixer.index[$0] }.prefix(CoreMLFixer.maxPositions - 2)
        if ids.isEmpty { return text }
        do {
            let src = try CoreMLFixer.array(Array(ids))
            let enc = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["src": MLFeatureValue(multiArray: src)]))
            guard let memory = enc.featureValue(for: "memory")?.multiArrayValue else { return nil }
            var ys: [Int32] = [CoreMLFixer.bos]
            var out = ""
            for _ in 1..<CoreMLFixer.maxPositions {
                let tgt = try CoreMLFixer.array(ys)
                let dec = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "tgt": MLFeatureValue(multiArray: tgt), "memory": MLFeatureValue(multiArray: memory)]))
                guard let logits = dec.featureValue(for: "logits")?.multiArrayValue else { return nil }
                var best = 0
                var bestValue = logits[0].doubleValue
                for i in 1..<logits.count {
                    let v = logits[i].doubleValue
                    if v > bestValue { bestValue = v; best = i }
                }
                if best == Int(CoreMLFixer.eos) { break }
                ys.append(Int32(best))
                if best >= 3 && best - 3 < CoreMLFixer.vocab.count { out.append(CoreMLFixer.vocab[best - 3]) }
            }
            return out
        } catch {
            lastError = error
            return nil
        }
    }
}
#endif
