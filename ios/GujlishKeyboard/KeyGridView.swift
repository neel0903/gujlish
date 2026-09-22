// The keys, drawn and touched with plain UIKit so that a key reacts in
// the same frame the finger lands. Which key a set of fingers means is
// decided by TouchTracker in GujlishCore, where fast and overlapping
// sequences are unit tested; this file draws, and turns the tracker's
// events into highlights, pop-ups, sounds and key actions. Nothing is
// computed on the touch path; the bar refreshes afterwards.
//
// Sizes are measured from the system keyboard (iOS 27, 402 pt wide):
// ten 39.5 pt columns inside a 3.6 pt margin, 6.2 pt between keys, 43 pt
// keys on a 54 pt row pitch, 8.5 pt corners, every key the same colour.

import UIKit
import GujlishCore

struct KeyboardMetrics {
    let landscape: Bool
    var rowHeight: CGFloat { landscape ? 40 : 54 }       // key plus the gap below it
    var keyInsetV: CGFloat { landscape ? 4 : 5.5 }
    var keyInsetH: CGFloat { 3.1 }
    var edge: CGFloat { 3.6 }
    var cornerRadius: CGFloat { landscape ? 7 : 8.5 }
    // iOS adds its own padding above a third-party keyboard, so this bar
    // is shorter than the system's to put the first row at the same height.
    var barHeight: CGFloat { landscape ? 34 : 42 }
    var lowercaseSize: CGFloat { landscape ? 22 : 25 }
    var uppercaseSize: CGFloat { landscape ? 20 : 22 }
    var gridHeight: CGFloat { 4 * rowHeight + 2 }
    var height: CGFloat { barHeight + gridHeight }
}

struct KeyboardColors {
    let dark: Bool
    var key: UIColor { dark ? UIColor(white: 0.36, alpha: 1) : .white }
    var pressedKey: UIColor { dark ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.78, alpha: 1) }
    var text: UIColor { dark ? .white : .black }
    var faint: UIColor { dark ? UIColor(white: 1, alpha: 0.35) : UIColor(white: 0, alpha: 0.3) }
    var accent: UIColor { UIColor(red: 0, green: 0.478, blue: 1, alpha: 1) }
}

enum KeyKind: Equatable {
    case character(String)
    case shift, backspace, globe, space, enter, script, settings
    case layer(KeyboardModel.Layer, String)
    /// Not a key on screen: what a long press types.
    case alternate(String, replacesTyped: Bool)
}

/// Everything that changes how the grid looks.
struct KeyGridState: Equatable {
    var layer: KeyboardModel.Layer = .letters
    var shift: KeyboardModel.Shift = .off
    var showsGlobe = true
    var dark = false
    var landscape = false
    var scriptMode = false
    var returnLabel = "return"
    var returnIsAction = false
    var fastKeys = true
    var size = CGSize.zero
}

final class KeyGridView: UIView {
    var state = KeyGridState() {
        didSet {
            if state == oldValue { return }
            // Only a new layout needs new key views. Shift, colours and the
            // return label are restyled in place, so that a finger already
            // down on the next key (fast typing after a capital) stays valid.
            var restyled = oldValue
            restyled.shift = state.shift
            restyled.dark = state.dark
            restyled.scriptMode = state.scriptMode
            restyled.returnLabel = state.returnLabel
            restyled.returnIsAction = state.returnIsAction
            if restyled == state && !keyViews.isEmpty { restyle() } else { rebuild() }
        }
    }
    var onKey: ((KeyKind) -> Void)?
    /// (seconds between the finger landing and this view hearing of it, cancelled?)
    var onTouch: ((_ delay: Double, _ event: TouchEvent) -> Void)?
    enum TouchEvent { case down, downAbove, up, cancelled }
    /// The globe is a real control so that the system can show its keyboard list on a long press.
    var configureGlobe: ((UIButton) -> Void)?

    private final class KeyView: UIView {
        let kind: KeyKind
        let label = UILabel()
        let icon = UIImageView()
        var restFill = UIColor.white
        var pressedFill = UIColor.white

        init(kind: KeyKind, frame: CGRect, cornerRadius: CGFloat) {
            self.kind = kind
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            label.frame = bounds
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.baselineAdjustment = .alignCenters
            addSubview(label)
            icon.frame = bounds
            icon.contentMode = .center
            addSubview(icon)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func setPressed(_ pressed: Bool) {
            backgroundColor = pressed ? pressedFill : restFill
        }
    }

    private let tracker = TouchTracker<KeyKind>()
    private var keyViews: [KeyView] = []
    private var popups: [ObjectIdentifier: UIView] = [:]
    private var globeButton: UIButton?
    private var repeatTimer: Timer?

    // What holding a key types. The top row gives the digits, as on many keyboards.
    static let alternates: [String: String] = {
        var map = [".": "…", "-": "—", "/": "\\", "?": "¿", "!": "¡", "'": "’", "\"": "”", "₹": "$", "&": "§"]
        for (letter, digit) in zip("qwertyuiop", "1234567890") { map[String(letter)] = String(digit) }
        return map
    }()
    private var holdTimers: [ObjectIdentifier: Timer] = [:]
    private static let holdTime = 0.4

    private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
    private static let numbers = [["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
                                  ["-", "/", ":", ";", "(", ")", "₹", "&", "@", "\""],
                                  [".", ",", "?", "!", "'"]]
    private static let symbols = [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                                  ["_", "\\", "|", "~", "<", ">", "€", "$", "£", "•"],
                                  [".", ",", "?", "!", "'"]]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if state.size != bounds.size { state.size = bounds.size }
    }

    // ---------- building ----------

    private func rebuild() {
        // Keys still held are committed first, with the views they belong to.
        handle(tracker.flush())
        stopRepeat()
        holdTimers.values.forEach { $0.invalidate() }
        holdTimers = [:]
        popups.values.forEach { $0.removeFromSuperview() }
        popups = [:]
        keyViews.forEach { $0.removeFromSuperview() }
        keyViews = []
        globeButton?.removeFromSuperview()
        globeButton = nil
        let width = state.size.width
        guard width > 0 else { _ = tracker.setKeys([]); return }

        let m = KeyboardMetrics(landscape: state.landscape)
        let unit = (width - 2 * m.edge) / 10
        let rows: [[String]]
        switch state.layer {
        case .letters: rows = Self.letters
        case .numbers: rows = Self.numbers
        case .symbols: rows = Self.symbols
        }
        var slots: [TouchTracker<KeyKind>.Key] = []

        // slot: what a touch hits (the slots tile the grid, no dead strips).
        // face: what is drawn. x positions are in points from the left edge.
        func add(_ kind: KeyKind, row: Int, slot: ClosedRange<CGFloat>, face: ClosedRange<CGFloat>) {
            let y = CGFloat(row) * m.rowHeight
            let frame = CGRect(x: face.lowerBound, y: y + m.keyInsetV,
                               width: face.upperBound - face.lowerBound, height: m.rowHeight - 2 * m.keyInsetV)
            let view = KeyView(kind: kind, frame: frame, cornerRadius: m.cornerRadius)
            addSubview(view)
            keyViews.append(view)
            var behavior: TouchTracker<KeyKind>.Behavior = kind == .backspace ? .repeating : kind == .shift ? .onPress : .onRelease
            var survives = false
            var alternate = false
            if case .character(let c) = kind {
                survives = true
                alternate = Self.alternates[c] != nil
                if state.fastKeys { behavior = .onPress }
            }
            slots.append(.init(kind: kind,
                               slot: CGRect(x: slot.lowerBound, y: y, width: slot.upperBound - slot.lowerBound,
                                            height: row == 3 ? m.rowHeight + 2 : m.rowHeight),
                               behavior: behavior, survivesCancel: survives, hasAlternate: alternate))
        }
        func column(_ i: CGFloat) -> CGFloat { m.edge + i * unit }
        func addLetters(_ keys: [String], row: Int, firstColumn: CGFloat, stretchEnds: Bool) {
            for (i, k) in keys.enumerated() {
                let x0 = column(firstColumn + CGFloat(i)), x1 = x0 + unit
                let s0 = stretchEnds && i == 0 ? 0 : x0, s1 = stretchEnds && i == keys.count - 1 ? width : x1
                add(.character(k), row: row, slot: s0...s1, face: (x0 + m.keyInsetH)...(x1 - m.keyInsetH))
            }
        }

        addLetters(rows[0], row: 0, firstColumn: 0, stretchEnds: true)
        addLetters(rows[1], row: 1, firstColumn: (10 - CGFloat(rows[1].count)) / 2, stretchEnds: true)

        // Row 3: shift (or #+=) and delete are 45 pt wide at the edges.
        let sideFace: CGFloat = 45 * width / 402
        let left: KeyKind = state.layer == .letters ? .shift
            : state.layer == .numbers ? .layer(.symbols, "#+=") : .layer(.numbers, "123")
        if state.layer == .letters {
            let first = (10 - CGFloat(rows[2].count)) / 2
            add(left, row: 2, slot: 0...column(first), face: (m.edge + m.keyInsetH)...(m.edge + m.keyInsetH + sideFace))
            addLetters(rows[2], row: 2, firstColumn: first, stretchEnds: false)
            add(.backspace, row: 2, slot: column(first + CGFloat(rows[2].count))...width,
                face: (width - m.edge - m.keyInsetH - sideFace)...(width - m.edge - m.keyInsetH))
        } else {
            // Five wide punctuation keys between the two side keys.
            let inner0 = m.edge + m.keyInsetH + sideFace + 2 * m.keyInsetH + 8
            let inner1 = width - inner0
            let w = (inner1 - inner0) / CGFloat(rows[2].count)
            add(left, row: 2, slot: 0...inner0, face: (m.edge + m.keyInsetH)...(m.edge + m.keyInsetH + sideFace))
            for (i, k) in rows[2].enumerated() {
                let x0 = inner0 + CGFloat(i) * w
                add(.character(k), row: 2, slot: x0...(x0 + w), face: (x0 + m.keyInsetH)...(x0 + w - m.keyInsetH))
            }
            add(.backspace, row: 2, slot: inner1...width,
                face: (width - m.edge - m.keyInsetH - sideFace)...(width - m.edge - m.keyInsetH))
        }

        // Row 4: 123, globe or script, space, return (52.8 / 49.4 / rest / 102.5 of 402).
        let a = 52.8 * width / 402, b = a + 49.4 * width / 402, c = width - 102.5 * width / 402
        add(state.layer == .letters ? .layer(.numbers, "123") : .layer(.letters, "ABC"), row: 3,
            slot: 0...a, face: (m.edge + m.keyInsetH)...(a - m.keyInsetH))
        // Where the system has its emoji key: the script toggle, and on the
        // 123 layer the settings, so that the bar is left to the suggestions.
        let second: KeyKind = state.showsGlobe ? .globe : state.layer == .letters ? .script : .settings
        add(second, row: 3, slot: a...b, face: (a + m.keyInsetH)...(b - m.keyInsetH))
        if state.showsGlobe, let globeKey = keyViews.last {
            let button = UIButton(type: .custom)
            button.frame = globeKey.frame.insetBy(dx: -m.keyInsetH, dy: -m.keyInsetV)
            configureGlobe?(button)
            addSubview(button)
            globeButton = button
        }
        add(.space, row: 3, slot: b...c, face: (b + m.keyInsetH)...(c - m.keyInsetH))
        add(.enter, row: 3, slot: c...width, face: (c + m.keyInsetH)...(width - m.edge - m.keyInsetH))

        _ = tracker.setKeys(slots)
        restyle()
    }

    private func restyle() {
        let colors = KeyboardColors(dark: state.dark)
        let m = KeyboardMetrics(landscape: state.landscape)
        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        for view in keyViews {
            view.label.textColor = colors.text
            view.icon.tintColor = colors.text
            view.restFill = colors.key
            view.pressedFill = colors.pressedKey
            view.label.frame = view.bounds
            switch view.kind {
            case .character(let c):
                let capital = state.layer == .letters && state.shift != .off
                view.label.text = capital ? c.uppercased() : c
                let lower = state.layer == .letters && !capital
                view.label.font = .systemFont(ofSize: lower ? m.lowercaseSize : m.uppercaseSize, weight: .regular)
                // Lower-case letters look low when centred on their box; the system lifts them.
                if lower { view.label.frame = view.bounds.offsetBy(dx: 0, dy: -1.5) }
            case .space:
                view.label.text = state.scriptMode ? "ગુજરાતી" : ""
                view.label.font = .systemFont(ofSize: 15)
                view.label.textColor = colors.faint
            case .enter:
                if state.returnIsAction {
                    view.icon.image = nil
                    view.label.text = state.returnLabel
                    view.label.font = .systemFont(ofSize: 16, weight: .medium)
                    view.label.textColor = .white
                    view.restFill = colors.accent
                } else {
                    view.label.text = nil
                    view.icon.image = UIImage(systemName: "return", withConfiguration: symbol)
                }
            case .layer(_, let title):
                view.label.text = title
                view.label.font = .systemFont(ofSize: 17)
            case .script:
                view.label.text = "ગુ"
                view.label.font = .systemFont(ofSize: 18, weight: .medium)
                view.label.textColor = state.scriptMode ? colors.accent : colors.text
            case .shift:
                let name = state.shift == .off ? "shift" : state.shift == .on ? "shift.fill" : "capslock.fill"
                view.icon.image = UIImage(systemName: name, withConfiguration: symbol)
            case .backspace:
                view.icon.image = UIImage(systemName: "delete.left", withConfiguration: symbol)
            case .globe:
                view.icon.image = UIImage(systemName: "globe", withConfiguration: symbol)
            case .settings:
                view.icon.image = UIImage(systemName: "gearshape", withConfiguration: symbol)
            case .alternate:
                break
            }
            view.setPressed(popups[ObjectIdentifier(view)] != nil)
        }
    }

    // ---------- touches ----------

    // Fast thumbs overshoot the top row. Like the system keyboard, the keys
    // take touches a little above where they are drawn (over the lower
    // edge of the suggestion strip); the tracker gives them to the nearest key.
    static let reachAbove: CGFloat = 5

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isHidden { return false }
        return bounds.inset(by: UIEdgeInsets(top: -Self.reachAbove, left: 0, bottom: 0, right: 0)).contains(point)
    }

    private func note(_ touches: Set<UITouch>, _ event: TouchEvent) {
        guard let onTouch = onTouch else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for touch in touches { onTouch(now - touch.timestamp, touch.location(in: self).y < 0 && event == .down ? .downAbove : event) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        note(touches, .down)
        for touch in touches {
            let id = ObjectIdentifier(touch)
            handle(tracker.began(id, at: touch.location(in: self), time: touch.timestamp))
            watchHold(id)
        }
    }

    // Long press: (re)started whenever the finger is on a new key.
    private var holdKeys: [ObjectIdentifier: Int] = [:]

    private func watchHold(_ id: ObjectIdentifier) {
        let index = tracker.heldKey(id)
        if index == holdKeys[id] && index != nil { return }
        holdTimers.removeValue(forKey: id)?.invalidate()
        holdKeys[id] = index
        guard let index = index, tracker.keys.indices.contains(index), tracker.keys[index].hasAlternate else { return }
        holdTimers[id] = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.holdTimers[id] = nil
            self.handle(self.tracker.held(id, on: index))
        }
    }

    private func unwatchHold(_ id: ObjectIdentifier) {
        holdTimers.removeValue(forKey: id)?.invalidate()
        holdKeys[id] = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            handle(tracker.moved(ObjectIdentifier(touch), to: touch.location(in: self)))
            watchHold(ObjectIdentifier(touch))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        note(touches, .up)
        for touch in touches {
            unwatchHold(ObjectIdentifier(touch))
            handle(tracker.ended(ObjectIdentifier(touch), at: touch.location(in: self)))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        note(touches, .cancelled)
        for touch in touches {
            unwatchHold(ObjectIdentifier(touch))
            handle(tracker.cancelled(ObjectIdentifier(touch), time: touch.timestamp))
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { handle(tracker.flush()) }
    }

    // A key action can change the layout (123, shift), which replaces the
    // key views. So the views are looked up before anything runs.
    private func handle(_ events: [TouchTracker<KeyKind>.Event]) {
        if events.isEmpty { return }
        let views = keyViews
        for event in events {
            switch event {
            case .press(let i):
                guard views.indices.contains(i) else { continue }
                UIDevice.current.playInputClick()
                views[i].setPressed(true)
                if case .character = views[i].kind, views[i].superview != nil { showPopup(for: views[i]) }
                else { popups[ObjectIdentifier(views[i])] = UIView() }   // marks it pressed for restyle()
            case .release(let i):
                guard views.indices.contains(i) else { continue }
                views[i].setPressed(false)
                popups.removeValue(forKey: ObjectIdentifier(views[i]))?.removeFromSuperview()
            case .commit(let i):
                guard views.indices.contains(i) else { continue }
                onKey?(views[i].kind)
            case .startRepeat(let i):
                guard views.indices.contains(i) else { continue }
                startRepeat(views[i].kind)
            case .stopRepeat:
                stopRepeat()
            case .alternate(let i, let replacesTyped):
                guard views.indices.contains(i), case .character(let c) = views[i].kind,
                      let alt = Self.alternates[c] else { continue }
                (popups[ObjectIdentifier(views[i])]?.subviews.first as? UILabel)?.text = alt
                onKey?(.alternate(alt, replacesTyped: replacesTyped))
            }
        }
    }

    // ---------- delete repeat: a pause, then ten a second ----------

    private func startRepeat(_ kind: KeyKind) {
        stopRepeat()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.onKey?(kind)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // ---------- pop-up ----------

    private func showPopup(for key: KeyView) {
        let colors = KeyboardColors(dark: state.dark)
        let m = KeyboardMetrics(landscape: state.landscape)
        var frame = key.frame.insetBy(dx: -9, dy: 0)
        frame.origin.y -= key.frame.height + 6
        frame.size.height = key.frame.height * 2 + 6
        frame.origin.x = min(max(frame.origin.x, 1), bounds.width - frame.width - 1)
        let popup = UIView(frame: frame)
        popup.isUserInteractionEnabled = false
        popup.backgroundColor = colors.key
        popup.layer.cornerRadius = m.cornerRadius + 3
        popup.layer.cornerCurve = .continuous
        popup.layer.shadowColor = UIColor.black.cgColor
        popup.layer.shadowOpacity = 0.25
        popup.layer.shadowRadius = 4
        popup.layer.shadowOffset = CGSize(width: 0, height: 1)
        popup.layer.shadowPath = UIBezierPath(roundedRect: popup.bounds, cornerRadius: m.cornerRadius + 3).cgPath
        let label = UILabel(frame: CGRect(x: 0, y: 2, width: frame.width, height: key.frame.height))
        label.text = key.label.text
        label.textAlignment = .center
        label.textColor = colors.text
        label.font = .systemFont(ofSize: m.lowercaseSize + 12)
        popup.addSubview(label)
        addSubview(popup)
        popups[ObjectIdentifier(key)]?.removeFromSuperview()
        popups[ObjectIdentifier(key)] = popup
    }
}
