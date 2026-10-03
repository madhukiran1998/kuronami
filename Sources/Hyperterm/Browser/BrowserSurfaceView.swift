import AppKit
import CefSwiftUI
import Observation
import SwiftUI

/// A browser session's tile content: the address bar and its own Chromium page. Every browser
/// shares one profile, so logins carry across them.
@MainActor
final class BrowserSurfaceView: NSView, SessionSurface {
    weak var events: TerminalSurfaceEvents?
    let model: CefWebViewModel
    /// The session's label: tags the page so agents' tools can tell browsers apart.
    var label: String {
        didSet {
            host?.rootView = BrowserPane(browser: AgentBrowser.shared, model: model, label: label, store: store)
            mark()
        }
    }
    private let store: SessionStore
    /// Called with the page's address and title as they change, to persist and show them.
    var onNavigate: ((URL?, String) -> Void)?
    private var host: NSHostingView<BrowserPane>?
    private var destroyed = false
    private var lastSearch = ""

    init(url: URL?, label: String, store: SessionStore) {
        self.model = CefWebViewModel(url: url ?? URL(string: "about:blank"))
        self.label = label
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        AgentBrowser.shared.start()
        let pane = NSHostingView(rootView: BrowserPane(browser: AgentBrowser.shared, model: model, label: label, store: store))
        pane.sizingOptions = []
        pane.autoresizingMask = [.width, .height]
        pane.frame = bounds
        addSubview(pane)
        host = pane
        observeModel()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Chromium creates the page once its view is in a window. Hidden tiles (other layouts)
    /// don't lay out on their own, so force it: agents can use a browser nobody is looking at.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { host?.layoutSubtreeIfNeeded() }
    }

    // MARK: Page tag

    /// Agents' tools find "their" page by this tag, so it's set again after every load.
    func mark() {
        model.executeJavaScript("window.__hyperterm = '\(label)'")
    }

    private func observeModel() {
        withObservationTracking {
            _ = (model.url, model.title, model.isLoading)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.destroyed else { return }
                    self.onNavigate?(self.model.url, self.model.title)
                    if !self.model.isLoading { self.mark() }
                    self.observeModel()
                }
            }
        }
    }

    // MARK: SessionSurface

    func destroy() {
        destroyed = true
        model.browser?.close(force: true)
    }

    /// Typing into a page goes through the agent's browser tools, not the terminal channel.
    func sendText(_ text: String) {}
    func sendReturn() {}
    func pressKey(named raw: String) -> Bool { false }

    func readViewport() -> String {
        [model.title, model.url?.absoluteString ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func readText(lastLines lines: Int) -> String { readViewport() }

    func performBinding(_ action: String) {
        if action.hasPrefix("search:") {
            lastSearch = String(action.dropFirst("search:".count))
            if !lastSearch.isEmpty { model.browser?.find(lastSearch, forward: true, matchCase: false) }
        } else if action.hasPrefix("navigate_search:"), !lastSearch.isEmpty {
            model.browser?.find(lastSearch, forward: action.hasSuffix("next"), matchCase: false)
        }
    }

    func setOccluded(_ occluded: Bool) {}
}
