// The strip above the keys (script toggle, grammar chip, suggestions,
// settings) and the settings panel. The keys themselves are KeyGridView.

import SwiftUI

struct KeyboardPalette {
    let dark: Bool
    var text: Color { dark ? .white : Color(white: 0.2) }
    var accent: Color { Color(red: 0, green: 0.478, blue: 1) }
}

struct BarView: View {
    @ObservedObject var model: KeyboardModel

    private var palette: KeyboardPalette { KeyboardPalette(dark: model.dark) }
    private var height: CGFloat { KeyboardMetrics(landscape: model.landscape).barHeight }

    var body: some View {
        HStack(spacing: 0) {
            // Phones that need a globe key have no room for the script and
            // settings keys in the bottom row; they live here instead.
            // Otherwise the bar is three equal thirds, like the system's.
            if model.showsGlobe {
                barButton("ગુ", active: model.settings.scriptMode) { model.settings.scriptMode.toggle() }
            }
            let fix = model.grammarFix
            if let correction = model.correction {
                // Autocorrect is about to act. Left: the word as typed, in
                // quotes, to keep it. Middle: what space will insert.
                chip("“\(model.typedWord)”", tint: palette.text) { model.keepTyped() }
                divider
                chip(correction, tint: palette.accent) { model.take(correction) }
                if let other = model.suggestions.first(where: { $0 != correction && $0 != model.typedWord.lowercased() }) {
                    divider
                    chip(other, tint: palette.text) { model.take(other) }
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }
            } else {
                let words = Array(model.suggestions.prefix(fix == nil ? 3 : 2))
                if let fix = fix {
                    chip("\(fix.from) → \(fix.to)", tint: palette.accent) { model.applyGrammarFix() }
                }
                ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                    if i > 0 || fix != nil { divider }
                    chip(word, tint: palette.text) { model.take(word) }
                }
                // Fewer than three: keep the thirds, so a word never jumps or stretches.
                ForEach(0..<max(0, 3 - words.count - (fix == nil ? 0 : 1)), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            if model.showsGlobe {
                Button { model.showsSettings.toggle() } label: {
                    Image(systemName: model.showsSettings ? "keyboard" : "gearshape")
                        .font(.system(size: 17))
                        .frame(width: 40, height: height)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(palette.text.opacity(0.7))
            }
        }
        .frame(height: height)
        .environment(\.colorScheme, model.dark ? .dark : .light)
    }

    private var divider: some View {
        Rectangle().fill(palette.text.opacity(0.15)).frame(width: 1, height: height * 0.5)
    }

    private func chip(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChipStyle())
        .foregroundStyle(tint)
    }

    private func barButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: height)
                .contentShape(Rectangle())
        }
        .foregroundStyle(active ? palette.accent : palette.text.opacity(0.7))
    }
}

// A grey flash on touch-down, like the system bar; no fade animation.
private struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.gray.opacity(0.3) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SettingsPanel: View {
    @ObservedObject var model: KeyboardModel
    @State private var confirmForget = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text("Gujlish settings").font(.system(size: 13)).opacity(0.6)
                    Spacer()
                    Button("Done") { model.showsSettings = false }.font(.system(size: 16, weight: .semibold))
                }
                .padding(.vertical, 6)
                Toggle("Autocorrect on space", isOn: $model.settings.autocorrect).padding(.vertical, 6)
                Toggle("Grammar suggestions", isOn: $model.settings.grammar).padding(.vertical, 6)
                Toggle("Type in Gujarati script", isOn: $model.settings.scriptMode).padding(.vertical, 6)
                Toggle("Suggest English words too", isOn: $model.settings.english).padding(.vertical, 6)
                Toggle("Fast keys (type on touch)", isOn: $model.settings.fastKeys).padding(.vertical, 6)
                Button(confirmForget ? "Tap again to forget everything learned" : "Forget learned words") {
                    if confirmForget { model.forgetPersonal() }
                    confirmForget.toggle()
                }
                .foregroundStyle(.red)
                .padding(.vertical, 10)
                Text(model.diagnostics)
                    .font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .opacity(0.6)
            }
            .font(.system(size: 16))
            .foregroundStyle(KeyboardPalette(dark: model.dark).text)
            .padding(.horizontal, 16)
        }
        .environment(\.colorScheme, model.dark ? .dark : .light)
    }
}
