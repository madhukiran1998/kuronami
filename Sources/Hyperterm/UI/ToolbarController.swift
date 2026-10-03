import AppKit
import SwiftUI

/// Native unified toolbar: sidebar toggle, title/subtitle (set by the window controller), layout
/// switcher, new terminal, and the inspector toggle.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    let toolbar = NSToolbar(identifier: "KuronamiToolbar.v4")
    private let store: SessionStore
    private let actions: SessionActions
    private let layoutControl = NSSegmentedControl()

    private static let layout = NSToolbarItem.Identifier("layout")
    private static let newTerminal = NSToolbarItem.Identifier("new")
    private static let waiting = NSToolbarItem.Identifier("waiting")
    private static let browser = NSToolbarItem.Identifier("browser")
    private static let commands = NSToolbarItem.Identifier("commands")
    private static let projectActions = NSToolbarItem.Identifier("actions")
    private static let editor = NSToolbarItem.Identifier("editor")
    private let actionsMenu = NSMenu(title: "Actions")

    init(store: SessionStore, actions: SessionActions) {
        self.store = store
        self.actions = actions
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        actionsMenu.delegate = self
        configureLayoutControl()
    }

    func refresh() {
        let selected = LayoutMode.allCases.firstIndex(of: store.layout) ?? 0
        if layoutControl.selectedSegment != selected { layoutControl.selectedSegment = selected }
    }

    private weak var waitingItem: NSToolbarItem?

    private func configureLayoutControl() {
        layoutControl.segmentCount = LayoutMode.allCases.count
        layoutControl.trackingMode = .selectOne
        layoutControl.segmentStyle = .separated
        layoutControl.controlSize = .regular
        layoutControl.setAccessibilityLabel("Terminal layout")
        for (index, mode) in LayoutMode.allCases.enumerated() {
            layoutControl.setImage(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title), forSegment: index)
            layoutControl.setLabel(mode.title, forSegment: index)
            layoutControl.setWidth(Space.xxl + Space.s, forSegment: index)
            layoutControl.setToolTip("\(mode.title) (⌘⌥\(index + 1))", forSegment: index)
        }
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged(_:))
        refresh()
    }

    @objc private func layoutChanged(_ sender: NSSegmentedControl) {
        guard LayoutMode.allCases.indices.contains(sender.selectedSegment) else { return }
        store.setLayout(LayoutMode.allCases[sender.selectedSegment])
    }

    @objc private func newTerminal(_ sender: Any?) { actions.newSession() }
    @objc private func jumpToWaiting(_ sender: Any?) { store.selectNextNeedingAttention() }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.waiting, .flexibleSpace, Self.commands, Self.projectActions, Self.editor,
         Self.layout, Self.newTerminal, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    // MARK: - Project actions

    /// Rebuilt each time it opens, for whichever session is selected.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let actions = store.projectActions(for: store.selected)
        if actions.isEmpty {
            let empty = NSMenuItem(title: store.selected == nil ? "Select a session first" : "No actions for this project", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, action) in actions.enumerated() {
            let item = NSMenuItem(title: action.name, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.toolTip = action.command
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let help = NSMenuItem(title: "Add actions in .hyperterm.json", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let session = store.selected else { return }
        let actions = store.projectActions(for: session)
        guard actions.indices.contains(sender.tag) else { return }
        store.run(actions[sender.tag], for: session)
    }

    @objc private func openEditor(_ sender: Any?) {
        guard let session = store.selected else { return }
        Editors.open(session.spec.workPath)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.layout:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = layoutControl
            item.label = "Layout"
            item.visibilityPriority = .high
            return item
        case Self.commands:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Command Palette")
            item.label = "Commands"
            item.toolTip = "Search sessions and run commands (⌘P)"
            item.action = #selector(AppDelegate.showSwitcher(_:))
            item.isBordered = true
            item.visibilityPriority = .low
            return item
        case Self.newTerminal:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Terminal")
            item.label = "New"
            item.toolTip = "New terminal (⌘N)"
            item.target = self
            item.action = #selector(newTerminal(_:))
            item.isBordered = true
            item.visibilityPriority = .low
            return item
        case Self.projectActions:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "play", accessibilityDescription: "Project Actions")
            item.label = "Actions"
            item.toolTip = "Run a project action: tests, dev server, build"
            item.menu = actionsMenu
            item.showsIndicator = false
            return item
        case Self.editor:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Open in Editor")
            item.label = "Editor"
            item.toolTip = "Open in \(Editors.preferred?.name ?? "your editor") (⌥⌘O)"
            item.target = self
            item.action = #selector(openEditor(_:))
            item.isBordered = true
            return item
        case Self.browser:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Browser")
            item.label = "New Browser"
            item.toolTip = "New browser (⇧⌘B)"
            item.action = #selector(AppDelegate.newBrowser(_:))
            item.isBordered = true
            return item
        case Self.waiting:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let host = NSHostingView(rootView: AttentionQueue(store: store))
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            item.label = "Needs You"
            item.visibilityPriority = .high
            waitingItem = item
            return item
        default:
            return nil
        }
    }
}
