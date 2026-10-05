// Container app: how to switch the keyboard on, and a field to try it in
// with the Gujarati-script preview underneath.

import SwiftUI
import GujlishCore

struct ContentView: View {
    @State private var text = ""
    @State private var fixMs: Int?
    private let lexicon = Bundle.main.path(forResource: "gujlish", ofType: "db").flatMap { try? Lexicon(path: $0) }
    // The Lane 2 sentence model, opened on first use.
    private static let fixer: SentenceFixing? = {
        guard let lexicon = Bundle.main.path(forResource: "gujlish", ofType: "db").flatMap({ try? Lexicon(path: $0) }),
              let enc = Bundle.main.url(forResource: "GujlishEncoder", withExtension: "mlmodelc"),
              let dec = Bundle.main.url(forResource: "GujlishDecoder", withExtension: "mlmodelc"),
              let vocab = Bundle.main.url(forResource: "fix_vocab", withExtension: "txt"),
              let gate = try? FixGate(vocabularyFile: vocab, lexicon: lexicon),
              let core = try? CoreMLFixer(encoder: enc, decoder: dec) else { return nil }
        return core.fixer(gate: gate)
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Turn the keyboard on") {
                    Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → Gujlish")
                    Text("Full Access is not needed. Everything stays on this phone; nothing is sent anywhere.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Try it") {
                    TextField("kem cho", text: $text, axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(3...6)
                    if !text.isEmpty {
                        Text(script(text))
                    }
                    HStack {
                        Button("Fix sentence") {
                            let start = Date()
                            if let fixer = Self.fixer { text = fixer.fix(text) }
                            fixMs = Int(Date().timeIntervalSince(start) * 1000)
                        }
                        .disabled(text.isEmpty || Self.fixer == nil)
                        Spacer()
                        if let ms = fixMs {
                            Text("\(ms) ms").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Gujlish")
        }
    }

    // Lexicon words use their real script form; anything else falls back
    // to the rule-based converter.
    private func script(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { part -> String in
            let clean = Engine.cleanSurface(String(part))
            if clean.isEmpty { return String(part) }
            return lexicon?.native(surface: clean) ?? Reverse.toGujarati(clean)
        }.joined(separator: " ")
    }
}
