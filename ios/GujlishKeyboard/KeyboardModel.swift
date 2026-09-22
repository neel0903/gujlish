// Glue between the keys on screen and the Composer in GujlishCore, which
// holds the typing rules and is unit tested. This file only adds what
// needs UIKit: the text proxy, shift state, the return key's label,
// settings and the personal dictionary on disk.

import UIKit
import GujlishCore

private final class ProxyDocument: TextDocument {
    weak var controller: UIInputViewController?
    var textBefore: String { controller?.textDocumentProxy.documentContextBeforeInput ?? "" }
    func insert(_ text: String) { controller?.textDocumentProxy.insertText(text) }
    func deleteBackward() { controller?.textDocumentProxy.deleteBackward() }
}

final class KeyboardModel: ObservableObject {
    enum Layer { case letters, numbers, symbols }
    enum Shift { case off, on, locked }

    @Published var suggestions: [String] = []
    @Published var grammarFix: Composer.GrammarFix?
    /// What space will turn the current word into, and the word as typed.
    @Published var correction: String?
    @Published var typedWord = ""
    @Published var shift: Shift = .off
    @Published var layer: Layer = .letters
    @Published var showsGlobe = true
    @Published var showsSettings = false
    @Published var dark = false
    @Published var landscape = false
    @Published var returnLabel = "return"
    @Published var returnIsAction = false
    @Published var settings = KeyboardSettings() {
        didSet {
            guard settings != oldValue else { return }
            composer?.settings = settings
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
            shiftDecidedFor = nil
            refresh()
        }
    }

    private static let settingsKey = "settings"
    private let document: ProxyDocument
    private let composer: Composer?
    private let store: PersonalStore?
    private var unsaved = 0
    private var lastShiftTap = Date.distantPast
    private weak var controller: UIInputViewController?

    init(controller: UIInputViewController) {
        self.controller = controller
        let document = ProxyDocument()
        document.controller = controller
        self.document = document
        // The database stays on disk; see the memory note in Lexicon.swift.
        let path = Bundle(for: KeyboardModel.self).path(forResource: "gujlish", ofType: "db")
        let engine = path.flatMap { try? Lexicon(path: $0) }.map(Engine.init(lexicon:))
        composer = engine.map { Composer(engine: $0, document: document) }
        store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { PersonalStore(url: $0.appendingPathComponent("personal.json")) }
        if let personal = store?.load() { composer?.loadPersonal(personal) }
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(KeyboardSettings.self, from: data) {
            settings = saved
            composer?.settings = saved
        }
    }

    // ---------- state from the host app ----------

    // Refreshing reads the host's text and asks the engine, so it never
    // runs on the touch path: keys call scheduleRefresh(), and one refresh
    // runs when the main queue is next free, however many keys came in.
    private var refreshScheduled = false

    func scheduleRefresh() {
        if refreshScheduled { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func publish<T: Equatable>(_ path: ReferenceWritableKeyPath<KeyboardModel, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    // Shift follows the text only when the text changes. A refresh for
    // any other reason (dark mode, a late system callback) must not undo a
    // shift the user has just tapped.
    private var shiftDecidedFor: String?

    func refresh() {
        guard let controller = controller else { return }
        let proxy = controller.textDocumentProxy
        publish(\.showsGlobe, controller.needsInputModeSwitchKey)
        publish(\.dark, proxy.keyboardAppearance == .dark || controller.traitCollection.userInterfaceStyle == .dark)
        let (label, isAction) = Self.returnKey(proxy.returnKeyType ?? .default)
        publish(\.returnLabel, label)
        publish(\.returnIsAction, isAction)

        guard let composer = composer else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let before = composer.refresh { [weak self] snapshot in
            guard let self = self else { return }
            self.publish(\.suggestions, snapshot.suggestions)
            self.publish(\.grammarFix, snapshot.grammarFix)
            self.publish(\.correction, snapshot.correction)
            self.publish(\.typedWord, snapshot.typed)
            self.engineMs = max(self.engineMs * 0.8, snapshot.milliseconds)
            self.barMs = max(self.barMs * 0.8, Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        }
        if before != shiftDecidedFor {
            shiftDecidedFor = before
            if shift != .locked { publish(\.shift, Self.wantsCapital(proxy.autocapitalizationType ?? .sentences, before) && !settings.scriptMode ? .on : .off) }
        }
    }

    // iOS may also report our own edits as a selection change; only a
    // change with no key just before it is the user moving the cursor.
    private var lastKeyTime = 0.0

    func documentChanged() {
        if ProcessInfo.processInfo.systemUptime - lastKeyTime < 0.4 { return }
        composer?.documentChanged()
        scheduleRefresh()
    }

    /// Called when the keyboard comes up, possibly in another text field.
    func appeared() {
        composer?.documentChanged()
        shiftDecidedFor = nil
        refresh()
    }

    private static func wantsCapital(_ type: UITextAutocapitalizationType, _ before: String) -> Bool {
        switch type {
        case .none: return false
        case .allCharacters: return true
        case .words: return before.last.map { $0 == " " || $0.isNewline } ?? true
        default: return Composer.isSentenceStart(before)
        }
    }

    // Diagnostics, shown in the settings panel: recent worst times in ms.
    // keyMs: a key press, touch to text inserted (this is what typing feels).
    // engineMs: suggestions + correction + grammar, in the background.
    // barMs: key press to suggestions on screen.
    private(set) var keyMs = 0.0
    private(set) var engineMs = 0.0
    private(set) var barMs = 0.0
    // Touches: how many landed, lifted and were cancelled by the system,
    // how many keys were typed, and how late iOS delivered a touch.
    private var downs = 0, ups = 0, cancels = 0, typedKeys = 0, above = 0
    private var delayMs = 0.0, worstDelayMs = 0.0

    func noteTouch(delay: Double, event: KeyGridView.TouchEvent) {
        switch event {
        case .down, .downAbove:
            downs += 1
            if event == .downAbove { above += 1 }
            delayMs = delayMs * 0.9 + delay * 1000 * 0.1
            worstDelayMs = max(worstDelayMs, delay * 1000)
        case .up: ups += 1
        case .cancelled: cancels += 1
        }
    }

    // What iOS counts against the keyboard; extensions are killed near 60 MB.
    private static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    // One quiet line in the settings panel, for the field test.
    var diagnostics: String {
        String(format: "mem %.0f MB · key %.1f ms · engine %.0f ms · touches %d, cancelled %d",
               Self.memoryMB(), keyMs, engineMs, downs, cancels)
    }

    private static func returnKey(_ type: UIReturnKeyType) -> (String, Bool) {
        switch type {
        case .go: return ("go", true)
        case .google, .search, .yahoo: return ("search", true)
        case .join: return ("join", true)
        case .next: return ("next", true)
        case .route: return ("route", true)
        case .send: return ("send", true)
        case .done: return ("done", true)
        case .continue: return ("continue", true)
        case .emergencyCall: return ("call", true)
        default: return ("return", false)
        }
    }

    // ---------- keys ----------

    private func after(commits: Int = 0) {
        scheduleRefresh()
        unsaved += commits
        if unsaved >= 10 { save() }
    }

    func key(_ kind: KeyKind) {
        typedKeys += 1
        lastKeyTime = ProcessInfo.processInfo.systemUptime
        let started = DispatchTime.now().uptimeNanoseconds
        defer { keyMs = max(keyMs * 0.8, Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6) }
        switch kind {
        case .character(let c):
            composer?.type(layer == .letters && shift != .off ? c.uppercased() : c)
            if shift == .on { shift = .off }
            after()
        case .space:
            composer?.space()
            if layer != .letters { layer = .letters }
            after(commits: 1)
        case .enter:
            composer?.newline()
            after()
        case .backspace:
            composer?.backspace()
            after()
        case .shift:
            shiftTapped()
        case .layer(let next, _):
            layer = next
        case .globe:
            controller?.advanceToNextInputMode()
        case .script:
            settings.scriptMode.toggle()
        case .settings:
            showsSettings = true
        case .alternate(let text, let replacesTyped):
            if replacesTyped { composer?.replaceLast(with: text) } else { composer?.type(text) }
            after()
        }
    }

    func take(_ suggestion: String) {
        lastKeyTime = ProcessInfo.processInfo.systemUptime
        UIDevice.current.playInputClick()
        composer?.take(suggestion)
        after(commits: 1)
    }

    func keepTyped() {
        lastKeyTime = ProcessInfo.processInfo.systemUptime
        UIDevice.current.playInputClick()
        composer?.keepTyped()
        after(commits: 1)
    }

    func applyGrammarFix() {
        lastKeyTime = ProcessInfo.processInfo.systemUptime
        UIDevice.current.playInputClick()
        composer?.applyGrammarFix()
        after()
    }

    // One tap: a capital for the next letter. Two quick taps: caps lock.
    func shiftTapped() {
        let now = Date()
        if shift == .locked {
            shift = .off
        } else if now.timeIntervalSince(lastShiftTap) < 0.35 {
            shift = .locked
        } else {
            shift = shift == .on ? .off : .on
        }
        lastShiftTap = now
    }

    func save() {
        guard unsaved > 0, let composer = composer else { return }
        if (try? store?.save(composer.personalData())) != nil { unsaved = 0 }
    }

    func forgetPersonal() {
        composer?.forgetPersonal()
        unsaved = 1
        save()
        refresh()
    }
}
