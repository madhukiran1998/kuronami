import AppKit
import Combine
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SessionStore
    private let terminalArea = TerminalAreaView()
    private var sheetWindow: NSWindow?
    private lazy var toolbarController = ToolbarController(store: store, actions: actions)

    private var inspectorItem: NSSplitViewItem?
    private var subscriptions: Set<AnyCancellable> = []

    init(store: SessionStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Kuronami"
        window.toolbarStyle = .unifiedCompact
        // Graphite: one opaque surface that terminals float on as rounded panes. Always dark,
        // and no live blur behind every tile.
        window.isOpaque = true
        window.backgroundColor = Ink.floor
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        // The sidebar and inspector already say what's selected; the toolbar stays uncluttered.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 780, height: 520)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentViewController = makeSplitController()
        window.toolbar = toolbarController.toolbar
        // A restored frame can be stale (screen changes); never come back smaller than usable.
        if !window.setFrameUsingName("HypertermMain") || window.frame.height < 500 || window.frame.width < 900 {
            window.setContentSize(NSSize(width: 1360, height: 840))
            window.center()
        }
        window.setFrameAutosaveName("HypertermMain")
        bindStore()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var actions: SessionActions {
        SessionActions(
            newSession: { [weak self] in self?.presentNewSession() },
            rename: { [weak self] in self?.presentRename($0) },
            releaseLabel: { [weak self] in self?.store.releaseLabel($0) },
            restart: { [weak self] in self?.confirmRestart($0) },
            close: { [weak self] in self?.confirmClose($0) },
            review: { [weak self] in self?.showInspector(for: $0) },
            dispatch: { [weak self] task, kinds, cwd, options in self?.store.dispatch(task, kinds: kinds, cwd: cwd, options: options) },
            showPlan: { [weak self] in self?.showInspector(for: $0, tab: .plan) },
            pickWinner: { [weak self] in self?.confirmPickWinner($0) })
    }

    // MARK: - Layout

    /// Native three-pane layout: opaque sidebar, terminals, and an inspector for review,
    /// activity, and session info.
    private func makeSplitController() -> NSSplitViewController {
        let split = NSSplitViewController()
        // Hosting controllers must not drive the window size from SwiftUI's ideal size.
        let sidebarHost = NSHostingController(rootView: SidebarView(store: store, actions: actions))
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: Self.solid(sidebarHost, color: Ink.deep))
        sidebarItem.minimumThickness = 280
        sidebarItem.maximumThickness = 460
        sidebarItem.preferredThicknessFraction = 0.24
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        split.addSplitViewItem(sidebarItem)

        let detail = NSViewController()
        let container = InkCanvas()
        terminalArea.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalArea)
        NSLayoutConstraint.activate([
            terminalArea.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            terminalArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        detail.view = container
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 420
        split.addSplitViewItem(detailItem)

        let inspectorHost = NSHostingController(rootView: InspectorView(store: store, actions: actions))
        inspectorHost.sizingOptions = []
        let inspector = NSSplitViewItem(inspectorWithViewController: Self.solid(inspectorHost, color: Ink.deep))
        inspector.minimumThickness = 340
        inspector.maximumThickness = 640
        inspector.canCollapse = true
        inspector.isCollapsed = true
        split.addSplitViewItem(inspector)
        inspectorItem = inspector
        split.splitView.autosaveName = "KuronamiWorkspace.v3"
        // The inspector opens on demand (review chip, ⌥⌘R); don't restore it open and empty.
        DispatchQueue.main.async { inspector.isCollapsed = true }
        return split
    }

    /// Wraps a view controller's view in a solid backing color.
    private static func solid(_ child: NSViewController, color: NSColor) -> NSViewController {
        let wrapper = NSViewController()
        let effect = NSView()
        effect.wantsLayer = true
        effect.layer?.backgroundColor = color.cgColor
        wrapper.addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: effect.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        wrapper.view = effect
        return wrapper
    }

    func toggleInspector() {
        guard let inspectorItem else { return }
        if Motion.reduced { inspectorItem.isCollapsed.toggle() }
        else { inspectorItem.animator().isCollapsed.toggle() }
    }

    func showInspector(for session: TerminalSession, tab: InspectorTab = .changes) {
        store.select(session)
        store.inspectorTab = tab
        if inspectorItem?.isCollapsed == true {
            if Motion.reduced { inspectorItem?.isCollapsed = false }
            else { inspectorItem?.animator().isCollapsed = false }
        }
    }

    func evenOutTiles() { terminalArea.evenOutTiles() }

    private func bindStore() {
        let strip = NSHostingView(rootView: ServerStrip(store: store))
        strip.sizingOptions = []
        terminalArea.serverStrip = strip
        store.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in MainActor.assumeIsolated { self?.reportLaunchError(error) } }
            .store(in: &subscriptions)
        store.onSurfaceChange = { [weak self] session in self?.terminalArea.mount(session) }
        store.onRemove = { [weak self] session in self?.terminalArea.unmount(session) }
        store.onArrangementChange = { [weak self] in self?.arrange(takeFocus: true) }
        store.onStatusChange = { [weak self] in self?.arrange(takeFocus: false) }
        store.confirmHandler = { [weak self] title, message, completion in
            guard let window = self?.window else { completion(false); return }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            NSApp.activate(ignoringOtherApps: true)
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        }
        terminalArea.onSelectTile = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.store.select(session)
        }
        terminalArea.onZoomTile = { [weak self] id in self?.store.toggleZoom(id) }
        terminalArea.onMinimizeTile = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.store.setMinimized(session, true)
        }
        terminalArea.onCloseTile = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.confirmClose(session)
        }
        terminalArea.onReorder = { [weak self] order in self?.store.setTileOrder(order) }
        store.onSearchUpdate = { [weak self] session, total, selected, start in
            if start { self?.terminalArea.showSearch(for: session.id) }
            self?.terminalArea.searchResults(for: session.id, total: total, selected: selected)
        }
    }

    private func arrange(takeFocus: Bool) {
        terminalArea.apply(mode: store.layout, visible: store.visibleIDs, focused: store.selectedID, takeFocus: takeFocus)
        let showsStrip = store.layout != .focus
            && store.sessions.contains { ($0.kind == .server && !$0.pinnedToGrid) || $0.isMinimized }
        if terminalArea.showsServerStrip != showsStrip { terminalArea.showsServerStrip = showsStrip }
        terminalArea.refreshAttention()
        let title: String, subtitle: String
        if let session = store.selected {
            title = "@" + session.label
            subtitle = [session.git?.project, session.git?.branch].compactMap { $0 }.joined(separator: " · ")
        } else {
            title = "Kuronami"
            subtitle = store.windowSubtitle
        }
        // Setting these relayouts the titlebar even when unchanged.
        if window?.title != title { window?.title = title }
        if window?.subtitle != subtitle { window?.subtitle = subtitle }
        toolbarController.refresh()
    }

    func showSearch() { terminalArea.showSearch(for: store.selectedID) }

    func presentWorktreeCleanup() {
        guard let window, sheetWindow == nil else { return }
        let roots = store.sessions.compactMap { $0.git.map(GitInfo.mainRoot) }
        let inUse = Set(store.sessions.map(\.spec.workPath))
        let view = WorktreeCleanupView(repoRoots: roots, inUse: inUse) { [weak self] in self?.dismissSheet() }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheetWindow = sheet
        window.beginSheet(sheet)
    }

    // MARK: - Quick switcher

    private var switcher: SwitcherPanel?

    func toggleSwitcher() {
        if let switcher, switcher.isVisible { switcher.close(); return }
        guard let window else { return }
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        let view = QuickSwitcherView(store: store, quickCreate: { [weak self] in self?.quickCreate($0) },
                                     dismiss: { [weak panel] in panel?.close() })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        let frame = window.frame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - host.fittingSize.width / 2, y: frame.maxY - 110))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        switcher = panel
    }

    // MARK: - Quick Ask

    private var quickAsk: SwitcherPanel?

    /// The floating task field from ⌃⌥Space. It takes keystrokes without bringing the main window
    /// forward, so the app you were in stays where it was.
    func toggleQuickAsk() {
        if let quickAsk, quickAsk.isVisible { quickAsk.close(); return }
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 140),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: QuickAskView(store: store, dismiss: { [weak panel] in panel?.close() }))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - host.fittingSize.width / 2, y: visible.maxY - visible.height * 0.22))
        }
        panel.makeKeyAndOrderFront(nil)
        quickAsk = panel
    }

    // MARK: - Sheets

    func presentNewSession(kind: SessionKind? = nil) {
        guard let window, sheetWindow == nil else { return }
        var draft = NewSessionDraft()
        if let current = store.selected { draft.cwd = current.spec.cwd }
        if let kind { draft.kind = kind }
        // Default to a worktree when another agent already works in this repo.
        let currentRoot = store.selected?.git.map(GitInfo.mainRoot)
        draft.worktree = currentRoot != nil && store.sessions.contains {
            $0.kind.isAgent && $0.git.map(GitInfo.mainRoot) == currentRoot
        }
        let recents = Array(NSOrderedSet(array: store.sessions.map(\.spec.cwd).reversed()).array as? [String] ?? [])
        let view = NewSessionView(draft: draft, recentDirectories: recents,
            onCreate: { [weak self] draft in
                self?.dismissSheet()
                self?.createSession(from: draft)
            },
            onCancel: { [weak self] in self?.dismissSheet() })
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheetWindow = sheet
        window.beginSheet(sheet)
    }

    private func dismissSheet() {
        guard let sheet = sheetWindow else { return }
        window?.endSheet(sheet)
        sheetWindow = nil
    }

    private func createSession(from draft: NewSessionDraft) {
        var spec = LaunchSpec(label: draft.label, kind: draft.kind, cwd: draft.cwd, command: draft.command)
        if draft.kind.isAgent, let account = draft.account { spec.account = account }
        if draft.kind.isAgent, !draft.options.isEmpty { spec.options = draft.options }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await store.launch(spec, worktree: draft.worktree)
        }
    }

    /// Launch problems (a worktree that couldn't be made) are shown once, from any launch path.
    private func reportLaunchError(_ error: String) {
        store.lastError = nil
        // The first sentence is the headline; the rest explains.
        let alert = NSAlert()
        let parts = error.components(separatedBy: ". ")
        alert.messageText = parts[0].hasSuffix(".") ? parts[0] : parts[0] + "."
        alert.informativeText = parts.dropFirst().joined(separator: ". ")
        if let window { alert.beginSheetModal(for: window) }
    }

    /// One-keystroke creation in the current session's folder.
    func quickCreate(_ kind: SessionKind) {
        let cwd = store.selected?.spec.cwd ?? NSHomeDirectory()
        let spec = LaunchSpec(label: "", kind: kind, cwd: cwd)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await store.launch(spec)
        }
    }

    func presentRename(_ session: TerminalSession) {
        let alert = NSAlert()
        alert.messageText = "Rename @\(session.label)"
        alert.informativeText = session.kind.isAgent
            ? "Once you name it, the agent won't rename it. The old name keeps working as an alias."
            : "Agents use this label to address the terminal. The old name keeps working as an alias."
        let field = NSTextField(string: session.label)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.rename(session, to: field.stringValue)
        }
    }

    func confirmClose(_ session: TerminalSession) {
        // A browser has no process to lose; closing it just closes the page.
        let running = session.kind != .browser
            && (session.state == .working || session.state == .running || session.state.needsAttention)
        guard running, let window else { store.close(session); return }
        let alert = NSAlert()
        alert.messageText = "Close @\(session.label)?"
        alert.informativeText = "Its process is still running and will be stopped."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.store.close(session) }
        }
    }

    func confirmPickWinner(_ session: TerminalSession) {
        guard let window else { return }
        let others = store.raceSiblings(of: session)
        let alert = NSAlert()
        alert.messageText = "Keep \(session.label)'s work?"
        alert.informativeText = "Its changes are committed and merged into \(session.spec.baseBranch ?? "the base branch"). "
            + "\(others.map(\.label).joined(separator: ", ")) will be closed and their worktrees archived; their branches stay."
        alert.addButton(withTitle: "Merge and Close Others")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.store.pickWinner(session) { [weak self] result in
                guard let self, let window = self.window else { return }
                let done = NSAlert()
                switch result {
                case .success(let text): done.messageText = text
                case .failure(let error):
                    done.messageText = "Couldn't merge \(session.label)"
                    done.informativeText = error.description
                }
                done.beginSheetModal(for: window)
            }
        }
    }

    func confirmRestart(_ session: TerminalSession) {
        guard session.state == .working || session.state.needsAttention, let window else { session.restart(); return }
        let alert = NSAlert()
        alert.messageText = "Restart @\(session.label)?"
        alert.informativeText = session.kind.isAgent
            ? "The agent is mid-turn. It will be stopped and resumed from its last saved conversation."
            : "The running process will be stopped and started again."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { session.restart() }
        }
    }

    // MARK: - NSWindowDelegate

    /// The red button hides the window like any Mac app; sessions keep running, the Dock icon
    /// brings it back, and ⌘Q quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window, window.firstResponder == nil || window.firstResponder === window else { return }
        if let session = store.selected { window.makeFirstResponder(session.surface) }
    }
}
