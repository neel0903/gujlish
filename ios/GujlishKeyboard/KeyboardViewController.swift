import Combine
import SwiftUI
import UIKit

// Lets UIDevice.playInputClick() make the system key sound.
extension UIInputView: @retroactive UIInputViewAudioFeedback {
    public var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(controller: self)
    private let grid = KeyGridView()
    private var settingsHost: UIViewController?
    private var barHeight: NSLayoutConstraint!
    private var gridHeight: NSLayoutConstraint!
    private var watching: AnyCancellable?

    override func viewDidLoad() {
        super.viewDidLoad()
        let bar = UIHostingController(rootView: BarView(model: model))
        let settings = UIHostingController(rootView: SettingsPanel(model: model))
        settingsHost = settings
        for host in [bar, settings] {
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        // The grid goes in last: its key pop-ups rise over the bar.
        view.addSubview(bar.view)
        view.addSubview(settings.view)
        view.addSubview(grid)
        bar.didMove(toParent: self)
        settings.didMove(toParent: self)

        let m = KeyboardMetrics(landscape: false)
        barHeight = bar.view.heightAnchor.constraint(equalToConstant: m.barHeight)
        gridHeight = grid.heightAnchor.constraint(equalToConstant: m.gridHeight)
        let bottom = grid.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        bottom.priority = .init(999)   // the system sizes the view first; never fight it
        NSLayoutConstraint.activate([
            bar.view.topAnchor.constraint(equalTo: view.topAnchor),
            bar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barHeight,
            grid.topAnchor.constraint(equalTo: bar.view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridHeight,
            bottom,
            settings.view.topAnchor.constraint(equalTo: grid.topAnchor),
            settings.view.bottomAnchor.constraint(equalTo: grid.bottomAnchor),
            settings.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settings.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        grid.onKey = { [weak self] kind in
            self?.model.key(kind)
            self?.push()   // shift and layer changes show in the same frame
        }
        grid.onTouch = { [weak self] delay, event in self?.model.noteTouch(delay: delay, event: event) }
        grid.configureGlobe = { [weak self] button in
            guard let self = self else { return }
            button.addTarget(self, action: #selector(self.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        // Everything else the model changes (dark mode, return label, settings) arrives here.
        watching = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.push() }
        }
        push()
    }

    // Model -> grid. Cheap when nothing changed: the grid compares states.
    private func push() {
        var state = grid.state
        state.layer = model.layer
        state.shift = model.shift
        state.showsGlobe = model.showsGlobe
        state.dark = model.dark
        state.landscape = model.landscape
        state.scriptMode = model.settings.scriptMode
        state.returnLabel = model.returnLabel
        state.returnIsAction = model.returnIsAction
        state.fastKeys = model.settings.fastKeys
        grid.state = state
        grid.isHidden = model.showsSettings
        settingsHost?.view.isHidden = !model.showsSettings
        let m = KeyboardMetrics(landscape: model.landscape)
        if barHeight.constant != m.barHeight { barHeight.constant = m.barHeight }
        if gridHeight.constant != m.gridHeight { gridHeight.constant = m.gridHeight }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appeared()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // iOS holds back touches near the screen edges while it decides
        // whether they start a system swipe; on a keyboard that makes q, a,
        // p and the bottom row feel late.
        relaxSystemGestures()
    }

    private func relaxSystemGestures() {
        var node: UIView? = view
        while let v = node {
            v.gestureRecognizers?.forEach {
                $0.delaysTouchesBegan = false
                $0.delaysTouchesEnded = false
                $0.cancelsTouchesInView = false
            }
            node = v.superview
        }
    }

    // The user moved the cursor: what the composer assumed about the text is void.
    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        model.documentChanged()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        relaxSystemGestures()
        let screen = view.window?.windowScene?.screen.bounds.size ?? view.bounds.size
        let landscape = screen.width > screen.height
        if model.landscape != landscape { model.landscape = landscape }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.save()
    }

    // The host app moved the cursor or changed the text under us (this
    // also fires for our own keys, hence the coalescing).
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.scheduleRefresh()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        model.scheduleRefresh()
    }
}
