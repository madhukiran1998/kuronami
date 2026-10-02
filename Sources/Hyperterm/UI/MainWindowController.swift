import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SessionStore
    private let terminalArea = TerminalAreaView()
    private var sheetWindow: NSWindow?
    private lazy var toolbarController = ToolbarController(store: store, actions: actions)

    private var inspectorItem: NSSplitViewItem?

    init(store: SessionStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Hyperterm"
        window.toolbarStyle = .unified
        // Glass window: the desktop blurs through the chrome and canvas (system vibrancy), and
        // terminals float on it as rounded panes. Chrome follows the system appearance.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 440)
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
            dispatch: { [weak self] task, kind, cwd in self?.dispatch(task, kind: kind, cwd: cwd) })
    }

    // MARK: - Layout

    /// Native three-pane layout: translucent sidebar, terminals, and an inspector for review,
    /// activity, and session info.
    private func makeSplitController() -> NSSplitViewController {
        let split = NSSplitViewController()
        // Hosting controllers must not drive the window size from SwiftUI's ideal size.
        let sidebarHost = NSHostingController(rootView: SidebarView(store: store, actions: actions))
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 280
        sidebarItem.maximumThickness = 460
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        split.addSplitViewItem(sidebarItem)

        let detail = NSViewController()
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState
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
        let inspector = NSSplitViewItem(inspectorWithViewController: Self.glass(inspectorHost, material: .sidebar))
        inspector.minimumThickness = 340
        inspector.maximumThickness = 640
        inspector.canCollapse = true
        inspector.isCollapsed = true
        split.addSplitViewItem(inspector)
        inspectorItem = inspector
        split.splitView.autosaveName = "HypertermSplit3"
        // The inspector opens on demand (review chip, ⌥⌘R); don't restore it open and empty.
        DispatchQueue.main.async { inspector.isCollapsed = true }
        return split
    }

    /// Wraps a view controller's view in a behind-window vibrancy material.
    private static func glass(_ child: NSViewController, material: NSVisualEffectView.Material) -> NSViewController {
        let wrapper = NSViewController()
        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
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
        inspectorItem.animator().isCollapsed.toggle()
    }

    func showInspector(for session: TerminalSession) {
        store.select(session)
        store.inspectorTab = .changes
        if inspectorItem?.isCollapsed == true { inspectorItem?.animator().isCollapsed = false }
    }

    /// Quick dispatch: a task typed in the sidebar becomes a new, auto-named agent in its own
    /// worktree (when the folder is a git repo) with the task already sent.
    private func dispatch(_ task: String, kind: SessionKind, cwd: String) {
        let isRepo = GitInspector.query(expandTilde(cwd)) != nil
        let spec = LaunchSpec(label: "", kind: kind, cwd: cwd)
        store.create(spec, worktree: isRepo, task: task)
        if let error = store.lastError {
            store.lastError = nil
            NSSound.beep()
            NSLog("hyperterm: %@", error)
        }
    }

    private func bindStore() {
        let strip = NSHostingView(rootView: ServerStrip(store: store))
        strip.sizingOptions = []
        terminalArea.serverStrip = strip
        store.onSurfaceChange = { [weak self] session in self?.terminalArea.mount(session) }
        store.onRemove = { [weak self] session in self?.terminalArea.unmount(session) }
        store.onArrangementChange = { [weak self] in self?.arrange() }
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
        store.onSearchUpdate = { [weak self] session, total, selected, start in
            if start { self?.terminalArea.showSearch(for: session.id) }
            self?.terminalArea.searchResults(for: session.id, total: total, selected: selected)
        }
    }

    private func arrange() {
        terminalArea.apply(mode: store.layout, visible: store.visibleIDs, focused: store.selectedID)
        terminalArea.showsServerStrip = store.layout != .focus && store.sessions.contains { $0.kind == .server && !$0.pinnedToGrid }
        terminalArea.refreshAttention()
        if let session = store.selected {
            window?.title = session.label
            window?.subtitle = [session.git?.project, session.git?.branch].compactMap { $0 }.joined(separator: " · ")
        } else {
            window?.title = "Hyperterm"
            window?.subtitle = store.windowSubtitle
        }
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
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        let view = QuickSwitcherView(store: store, quickCreate: { [weak self] in self?.quickCreate($0) },
                                     dismiss: { [weak panel] in panel?.close() })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        let frame = window.frame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - 280, y: frame.maxY - 110))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        switcher = panel
    }

    // MARK: - Sheets

    func presentNewSession(kind: SessionKind? = nil) {
        guard let window, sheetWindow == nil else { return }
        var draft = NewSessionDraft()
        if let current = store.selected { draft.cwd = current.spec.cwd }
        if let kind { draft.kind = kind }
        // Default to a worktree when another agent already works in this repo.
        let repo = GitInspector.query(expandTilde(draft.cwd))?.project
        draft.worktree = repo != nil && store.sessions.contains { $0.kind.isAgent && $0.git?.project == repo }
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
        let spec = LaunchSpec(label: draft.label, kind: draft.kind, cwd: draft.cwd, command: draft.command)
        store.create(spec, worktree: draft.worktree)
        if let error = store.lastError {
            store.lastError = nil
            let alert = NSAlert()
            alert.messageText = "Started without a worktree"
            alert.informativeText = error
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    /// One-keystroke creation in the current session's folder.
    func quickCreate(_ kind: SessionKind) {
        let cwd = store.selected?.spec.cwd ?? NSHomeDirectory()
        store.create(LaunchSpec(label: "", kind: kind, cwd: cwd))
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
        let running = session.state == .working || session.state == .running || session.state.needsAttention
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let session = store.selected { window?.makeFirstResponder(session.surface) }
    }
}

