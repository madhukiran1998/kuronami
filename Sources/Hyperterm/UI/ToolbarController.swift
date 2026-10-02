import AppKit
import SwiftUI

/// Native unified toolbar: sidebar toggle, title/subtitle (set by the window controller), layout
/// switcher, new terminal, and the inspector toggle.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "HypertermToolbar.v2")
    private let store: SessionStore
    private let actions: SessionActions
    private let layoutControl = NSSegmentedControl()

    private static let layout = NSToolbarItem.Identifier("layout")
    private static let newTerminal = NSToolbarItem.Identifier("new")
    private static let waiting = NSToolbarItem.Identifier("waiting")

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
        layoutControl.selectedSegment = LayoutMode.allCases.firstIndex(of: store.layout) ?? 0

    }

    private weak var waitingItem: NSToolbarItem?

    private func configureLayoutControl() {
        layoutControl.segmentCount = LayoutMode.allCases.count
        layoutControl.trackingMode = .selectOne
        for (index, mode) in LayoutMode.allCases.enumerated() {
            layoutControl.setImage(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title), forSegment: index)
            layoutControl.setToolTip("\(mode.title) (⌘⌥\(index + 1))", forSegment: index)
        }
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged(_:))
        refresh()
    }

    @objc private func layoutChanged(_ sender: NSSegmentedControl) {
        store.setLayout(LayoutMode.allCases[sender.selectedSegment])
    }

    @objc private func newTerminal(_ sender: Any?) { actions.newSession() }
    @objc private func jumpToWaiting(_ sender: Any?) { store.selectNextNeedingAttention() }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.waiting, .flexibleSpace, Self.layout, Self.newTerminal,
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
            return item
        case Self.newTerminal:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Terminal")
            item.label = "New"
            item.toolTip = "New terminal (⌘N)"
            item.target = self
            item.action = #selector(newTerminal(_:))
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
