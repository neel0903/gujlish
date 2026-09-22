// Container app: how to switch the keyboard on, and a field to try it in
// with the Gujarati-script preview underneath.

import SwiftUI
import GujlishCore

struct ContentView: View {
    @State private var text = ""
    private let lexicon = Bundle.main.path(forResource: "gujlish", ofType: "db").flatMap { try? Lexicon(path: $0) }

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
