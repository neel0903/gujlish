// Stand-in test runner until Xcode is installed (`swift test` does not
// work with the Command Line Tools alone). Run from the repo root:
//
//   ios/GujlishCore/DevTests/run.sh
//
// Checks the Swift port against web/expected.json, the same file that
// pins the JavaScript port. These checks move into XCTest in Step 1.

import Foundation

var failed = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "ok  " : "FAIL") \(name)")
    if !ok { failed += 1 }
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "web/expected.json"
guard let data = FileManager.default.contents(atPath: path),
      let expected = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    print("cannot read \(path); run python3 build_site.py first")
    exit(2)
}

// 1. Phonetic keys: every lexicon word plus the probe list, prefix and
//    whole-word mode. Rows are [surface, strictP, looseP, strictW, looseW].
let keys = (expected["keys"] as? [[String]] ?? []) + (expected["probeKeys"] as? [[String]] ?? [])
var keyBad = 0
for row in keys {
    let s = row[0]
    let got = [
        Phonetics.strictKey(s, prefix: true), Phonetics.looseKey(s, prefix: true),
        Phonetics.strictKey(s), Phonetics.looseKey(s),
    ]
    if got != Array(row[1...4]) {
        keyBad += 1
        if keyBad <= 10 { print("    \(s): got \(got) want \(Array(row[1...4]))") }
    }
}
check("phonetic keys identical for \(keys.count) words (\(keyBad) mismatches)", !keys.isEmpty && keyBad == 0)

// 2. Engine trials and corrections, against the Python reference
//    (Gujlish only, nothing learned).
let dbPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "gujlish.db"
let lexicon: Lexicon
do { lexicon = try Lexicon(path: dbPath) } catch { print("\(error); run python3 build_db.py lexicon.tsv first"); exit(2) }
let engine = Engine(lexicon: lexicon)
engine.mode = .gujlish

let trials = expected["trials"] as? [[String: Any]] ?? []
var trialBad = 0
for t in trials {
    let typed = t["typed"] as? String ?? "", prev = t["prev"] as? String, prev2 = t["prev2"] as? String
    let want = t["result"] as? [String] ?? []
    let got = typed.isEmpty ? engine.nextWord(prev: prev, prev2: prev2) : engine.suggest(typed, prev: prev, prev2: prev2)
    if got != want {
        trialBad += 1
        print("    [\(prev2 ?? "") \(prev ?? "")] \"\(typed)\": swift \(got)  py \(want)")
    }
}
check("\(trials.count - trialBad)/\(trials.count) trials identical", !trials.isEmpty && trialBad == 0)

let corrections = expected["corrections"] as? [[String: Any]] ?? []
var corrBad = 0
for c in corrections {
    let typed = c["typed"] as? String ?? "", want = c["result"] as? String
    let got = engine.correct(typed, prev: c["prev"] as? String, prev2: c["prev2"] as? String)
    if got != want {
        corrBad += 1
        print("    \"\(typed)\": swift \(got ?? "keep")  py \(want ?? "keep")")
    }
}
check("\(corrections.count - corrBad)/\(corrections.count) corrections match Python", !corrections.isEmpty && corrBad == 0)

// 3. Beyond the Python reference, as in web/test_port.js: English mixed
//    mode and personal words.
let mixed = Engine(lexicon: lexicon)
check("mixed: 'kem' shows no English", mixed.suggestDetailed("kem").sources.values.allSatisfy { $0 != .english })
let meet = mixed.suggestDetailed("meet")
check("mixed: 'meet' -> English \(meet.surfaces)", meet.surfaces.contains { meet.sources[$0] == .english })
mixed.mode = .gujlish
check("gujlish only: 'meet' has no English", mixed.suggestDetailed("meet").sources.values.allSatisfy { $0 != .english })
mixed.mode = .mixed
check("'neelbhai' is not a corpus word", lexicon.word(surface: "neelbhai") == nil)
mixed.learnWord("neelbhai", count: 3)
let nb = mixed.suggestDetailed("neelbh")
check("personal word appears \(nb.surfaces)", nb.sources["neelbhai"] == .personal)
mixed.learnBigram("kem", "neelbhai", count: 5)
check("personal bigram predicts \(mixed.nextWord(prev: "kem"))", mixed.nextWord(prev: "kem").contains("neelbhai"))
mixed.learnTrigram("kem", "cho", "neelbhai", count: 4)
check("personal trigram predicts \(mixed.nextWord(prev: "cho", prev2: "kem"))", mixed.nextWord(prev: "cho", prev2: "kem").first == "neelbhai")
check("trigram needs both words", !mixed.nextWord(prev: "cho").contains("neelbhai"))
for _ in 0..<3 { mixed.accept("thashe", prev: "kem") }
check("accepting thashe after kem puts it first \(mixed.suggest("th", prev: "kem"))", mixed.suggest("th", prev: "kem").first == "thashe")
let snapshot = mixed.personal
mixed.forgetPersonal()
engine.mode = .mixed
check("forget restores", mixed.suggest("th", prev: "kem") == engine.suggest("th", prev: "kem")
      && mixed.nextWord(prev: "cho", prev2: "kem").first != "neelbhai")
if let json = try? JSONEncoder().encode(snapshot), let back = try? JSONDecoder().decode(PersonalData.self, from: json) {
    mixed.loadPersonal(back)
    check("personal data survives a JSON round trip", mixed.personal == snapshot && mixed.suggest("th", prev: "kem").first == "thashe")
    mixed.forgetPersonal()
} else {
    check("personal data survives a JSON round trip", false)
}

// The user's own spec for autocorrect.
var prev: String?, prev2: String?, fixed: [String] = []
for w in ["Avi", "gaye", "ghara"] {
    let f = mixed.correct(w, prev: prev, prev2: prev2) ?? w
    fixed.append(f); prev2 = prev; prev = f
}
check("'Avi gaye ghara' -> aavi gaya ghare (\(fixed.joined(separator: " ")))", fixed == ["aavi", "gaya", "ghare"])
check("mixed: 'meeting' is not corrected", mixed.correct("meeting") == nil)
check("mixed: 'gate' (English) is not corrected", mixed.correct("gate") == nil)
check("'kem cho' untouched", mixed.correct("kem") == nil && mixed.correct("cho", prev: "kem") == nil)
mixed.learnWord("bhabhiji", count: 2)
check("a taught word is never corrected", mixed.correct("bhabhiji") == nil)
mixed.forgetPersonal()

// 5. Grammar rules in isolation, as in web/test_grammar.js.
func fixes(_ text: String) -> String {
    Grammar.check(text, engine: mixed).map { $0.from + ">" + $0.to }.joined(separator: ",")
}
let rules: [(String, String, String)] = [
    ("hu ... cho -> chu", "hu ghare gayo cho", "cho>chu"),
    ("tame ... che -> cho", "tame kem che", "che>cho"),
    ("ame ... chu -> chie", "ame majama chu", "chu>chie"),
    ("tu ... cho -> che", "tu su kare cho", "cho>che"),
    ("e ... che is fine", "e ghare che", ""),
    ("no subject, no check", "su karo cho", ""),
    ("hu ane tame ... cho -> chie", "hu ane tame majama cho", "cho>chie"),
    ("clause boundary: ke", "hu manu chu ke tame saras cho", ""),
    ("sentence boundary", "hu ghare gayo chu. tame kem cho?", ""),
    ("capital kept", "Hu ghare Cho", "Cho>Chu"),
    ("hu ... jashe -> jaish", "hu kale jashe", "jashe>jaish"),
    ("tame ... jaish -> jasho", "tame kale jaish", "jaish>jasho"),
    ("ame ... jashe -> jaishu", "ame kale jashe", "jashe>jaishu"),
    ("te ... jaish -> jashe", "te kale jaish", "jaish>jashe"),
    ("english -ish words are not verbs", "hu english finish karish", ""),
    ("ame ... gayo -> gaya", "ame kale gayo", "gayo>gaya"),
    ("tame ... aavyo -> aavya", "tame kyare aavyo", "aavyo>aavya"),
    ("e ... gayo is fine", "e kale gayo", ""),
    ("hu ... hashe -> hoish", "hu ghare hashe", "hashe>hoish"),
    ("tame ... hashe -> hasho", "tame kale hashe", "hashe>hasho"),
    ("chhu/chhe variants recognised", "tame majama chhu", "chhu>cho"),
]
for (label, text, want) in rules { check(label, fixes(text) == want) }
let gaya = Grammar.check("hu kale gaya", engine: mixed)
check("hu ... gaya -> gayo / gayi", gaya.count == 1 && gaya[0].to == "gayo" && gaya[0].alt == "gayi")
check("apply keeps offsets", Grammar.fixAll("hu ghare gayo cho ane tame kem che", engine: mixed) == "hu ghare gayo chu ane tame kem cho")

// 6. Script fallback for words outside the lexicon.
let rev = [("ghar", "ઘર"), ("kem", "કેમ"), ("chhun", "છું"), ("sambandh", "સંબંધ"), ("pravin", "પ્રવિન"),
           ("neel", "નીલ"), ("aavjo", "આવજો"), ("thayu", "થયુ"), ("kanya", "કન્યા"), ("bhai", "ભાઈ"),
           ("paisa", "પૈસા"), ("dikra", "દિકરા"), ("chokra", "ચોકરા")]
var revBad = 0
for (w, want) in rev where Reverse.toGujarati(w) != want {
    revBad += 1
    print("    reverse \(w): got \(Reverse.toGujarati(w)), want \(want)")
}
check("reverse transliteration (\(rev.count - revBad)/\(rev.count))", revBad == 0)
check("lexicon script form: kem -> \(lexicon.native(surface: "kem") ?? "nil")", lexicon.native(surface: "kem") != nil)

// 7. Golden sentences: the full commit pipeline (autocorrect each word,
//    then grammar), against web/golden.tsv.
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
        let fix = mixed.correct(p, prev: prev, prev2: prev2)
        if let fix = fix {
            let head = p.prefix { $0.isASCII && $0.isLetter }
            let cased = (p.first.map { $0 >= "A" && $0 <= "Z" } ?? false) ? fix.prefix(1).uppercased() + fix.dropFirst() : fix
            out += cased + p.dropFirst(head.count)
        } else {
            out += p
        }
        prev2 = prev; prev = fix ?? clean
    }
    return Grammar.fixAll(out, engine: mixed)
}
let goldenPath = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "web/golden.tsv"
let golden = ((try? String(contentsOfFile: goldenPath, encoding: .utf8)) ?? "")
    .split(whereSeparator: { $0.isNewline }).map(String.init)
    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
    .map { $0.components(separatedBy: "\t") }.filter { $0.count >= 2 }
var goldBad = 0
for g in golden {
    let got = pipeline(g[0])
    if got != g[1] { goldBad += 1; print("    GOLD \"\(g[0])\" -> \"\(got)\", want \"\(g[1])\"") }
}
check("golden sentences (\(golden.count - goldBad)/\(golden.count))", !golden.isEmpty && goldBad == 0)

// 4. Latency on the Mac (the phone is measured in Step 2's device test).
func ms(_ body: () -> Void) -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}
var worst = 0.0, worstCorrect = 0.0
for _ in 0..<3 {
    for p in ["c", "ch", "che", "tha", "thay", "kem", "majam", "mjama", "sarkar", "gujar", "k", "a"] {
        worst = max(worst, ms { _ = mixed.suggest(p, prev: "tame", prev2: "aaje") })
    }
}
for p in ["ghara", "gaye", "thayoo", "sarkr", "meeting"] {
    worstCorrect = max(worstCorrect, ms { _ = mixed.correct(p, prev: "gaya", prev2: "aavi") })
}
print(String(format: "worst suggest latency %.1f ms, worst correct latency %.1f ms", worst, worstCorrect))

print(failed == 0 ? "\nall checks passed" : "\n\(failed) check(s) failed")
exit(failed == 0 ? 0 : 1)
