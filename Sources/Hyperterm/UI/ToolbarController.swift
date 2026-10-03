import AppKit
import SwiftUI

/// Native unified toolbar: sidebar toggle, title/subtitle (set by the window controller), layout
/// switcher, new terminal, and the inspector toggle.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "KuronamiToolbar.v3")
    private let store: SessionStore
    private let actions: SessionActions
    private let layoutControl = NSSegmentedControl()

    private static let layout = NSToolbarItem.Identifier("layout")
    private static let newTerminal = NSToolbarItem.Identifier("new")
    private static let waiting = NSToolbarItem.Identifier("waiting")
    private static let browser = NSToolbarItem.Identifier("browser")
    private static let commands = NSToolbarItem.Identifier("commands")

    init(store: SessionStore, actions: SessionActions) {
        self.store = store
        self.actions = actions
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
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
            layoutControl.setWidth(68, forSegment: index)
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
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.waiting, .flexibleSpace, Self.commands, Self.layout, Self.newTerminal, Self.browser,
         .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
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
            item.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Command Palette")
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
