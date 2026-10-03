import AppKit

enum LayoutMode: String, CaseIterable, Codable {
    case focus, split, grid

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .split: return "Split"
        case .grid: return "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .focus: return "square"
        case .split: return "rectangle.split.2x1"
        case .grid: return "square.grid.2x2"
        }
    }
}

/// Arranges session tiles. Every session owns one persistent tile; layouts only change which
/// tiles are visible and where, so switching layouts never restarts a process.
@MainActor
final class TerminalAreaView: NSView {
    private var tiles: [UUID: TileView] = [:]
    private var visibleOrder: [UUID] = []
    private var focusedID: UUID?
    private var lastFocused: UUID?
    private var mode: LayoutMode = .focus
    private let emptyState = NSHostingViewFactory.emptyState()

    var onSelectTile: ((UUID) -> Void)?
    var onMinimizeTile: ((UUID) -> Void)?
    var onCloseTile: ((UUID) -> Void)?
    /// The user dragged tiles into a new order (the on-screen order).
    var onReorder: (([UUID]) -> Void)?
    /// The tile being dragged and where it started.
    private var drag: (id: UUID, origin: NSRect)?
    /// Where tiles go: the bounds minus the server/shelf strip.
    private var tileArea: NSRect = .zero
    /// Servers strip along the bottom in split and grid layouts.
    var serverStrip: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let serverStrip { addSubview(serverStrip) }
        }
    }
    var showsServerStrip = false { didSet { serverStrip?.isHidden = !showsServerStrip; needsLayout = true } }
    private static let stripHeight: CGFloat = 32
    var onZoomTile: ((UUID) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(emptyState)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func mount(_ session: TerminalSession) {
        if let tile = tiles[session.id] {
            tile.attachSurface()
            return
        }
        let id = session.id
        let tile = TileView(session: session, actions: TileActions(
            select: { [weak self] in self?.onSelectTile?(id) },
            zoom: { [weak self] in self?.onZoomTile?(id) },
            minimize: { [weak self] in self?.onMinimizeTile?(id) },
            close: { [weak self] in self?.onCloseTile?(id) },
            drag: { [weak self] translation in self?.dragTile(id, by: translation) },
            dragEnded: { [weak self] in self?.endDrag(id) }))
        tile.isHidden = true
        tiles[id] = tile
        addSubview(tile)
    }

    func unmount(_ session: TerminalSession) {
        tiles[session.id]?.removeFromSuperview()
        tiles[session.id] = nil
        visibleOrder.removeAll { $0 == session.id }
    }

    /// Shows `visible` in `mode`, focusing `focused`. `takeFocus` moves keyboard focus into the
    /// focused terminal; status-driven refreshes pass false so they never steal it from a field.
    func apply(mode: LayoutMode, visible: [UUID], focused: UUID?, takeFocus: Bool = true) {
        let changed = mode != self.mode || visible != visibleOrder
        self.mode = mode
        visibleOrder = visible.filter { tiles[$0] != nil }
        focusedID = focused
        let visibleSet = Set(visibleOrder)
        for (id, tile) in tiles {
            let isVisible = visibleSet.contains(id)
            // Tiles arriving on screen fade in rather than pop.
            if isVisible && tile.isHidden {
                tile.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    tile.animator().alphaValue = 1
                }
            }
            tile.isHidden = !isVisible
            tile.session.surface.setOccluded(!isVisible)
            // One tile gets the whole area without chrome, whatever the layout.
            tile.showsHeader = mode != .focus && visibleSet.count > 1
            tile.isFocusedTile = id == focused
        }
        emptyState.isHidden = !tiles.isEmpty
        if changed { needsLayout = true; layoutSubtreeIfNeeded() }
        if takeFocus || focused != lastFocused, let focused, let surface = tiles[focused]?.session.surface,
           window?.firstResponder !== surface {
            window?.makeFirstResponder(surface)
            if focused != lastFocused { tiles[focused]?.showRecapIfNeeded() }
        }
        lastFocused = focused
    }

    func showSearch(for id: UUID?) {
        guard let id else { return }
        tiles[id]?.showSearch()
    }

    func searchResults(for id: UUID, total: Int?, selected: Int?) {
        if let total { tiles[id]?.search.total = total }
        if let selected { tiles[id]?.search.selected = selected }
    }

    func refreshAttention() {
        tiles.values.forEach { $0.refreshAttention() }
    }

    override func layout() {
        super.layout()
        emptyState.frame = bounds
        var area = bounds
        if showsServerStrip, let serverStrip {
            serverStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.stripHeight)
            area = NSRect(x: 0, y: Self.stripHeight, width: bounds.width, height: bounds.height - Self.stripHeight)
        }
        tileArea = area
        let frames = Self.frames(count: visibleOrder.count, in: area, mode: mode)
        for (id, frame) in zip(visibleOrder, frames) where id != drag?.id {
            tiles[id]?.frame = frame.integral
        }
    }

    // MARK: - Drag to rearrange

    /// The tile follows the pointer; when its center is nearest another slot, it takes that
    /// slot and the others slide over.
    private func dragTile(_ id: UUID, by translation: CGSize) {
        guard mode != .focus, visibleOrder.count > 1, let tile = tiles[id] else { return }
        if drag == nil {
            drag = (id, tile.frame)
            tile.setLifted(true)
        }
        guard let origin = drag?.origin else { return }
        // SwiftUI's global space grows downward; this view's grows upward.
        tile.frame.origin = CGPoint(x: origin.minX + translation.width, y: origin.minY - translation.height)
        let slots = Self.frames(count: visibleOrder.count, in: tileArea, mode: mode)
        let center = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
        func distance(_ rect: NSRect) -> CGFloat { hypot(rect.midX - center.x, rect.midY - center.y) }
        guard let target = slots.indices.min(by: { distance(slots[$0]) < distance(slots[$1]) }),
              let current = visibleOrder.firstIndex(of: id), target != current else { return }
        visibleOrder.remove(at: current)
        visibleOrder.insert(id, at: target)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (other, frame) in zip(visibleOrder, slots) where other != id {
                tiles[other]?.animator().frame = frame.integral
            }
        }
    }

    private func endDrag(_ id: UUID) {
        guard drag?.id == id, let tile = tiles[id] else { return }
        drag = nil
        let slots = Self.frames(count: visibleOrder.count, in: tileArea, mode: mode)
        if let index = visibleOrder.firstIndex(of: id), slots.indices.contains(index) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                tile.animator().frame = slots[index].integral
            } completionHandler: {
                MainActor.assumeIsolated { tile.setLifted(false) }
            }
        } else {
            tile.setLifted(false)
        }
        onReorder?(visibleOrder)
    }

    // MARK: - Geometry

    nonisolated static func frames(count: Int, in bounds: NSRect, mode: LayoutMode) -> [NSRect] {
        guard count > 0 else { return [] }
        // Panes always float inset from the window edges, like content panes in Apple's apps.
        let gap: CGFloat = 10
        if mode == .focus || count == 1 { return [bounds.insetBy(dx: gap, dy: gap)] }
        let area = bounds.insetBy(dx: gap, dy: gap)
        let (columns, rows) = gridShape(count: count, aspect: area.width / max(area.height, 1))
        let cellHeight = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        var frames: [NSRect] = []
        for row in 0..<rows {
            let start = row * columns
            let itemsInRow = min(columns, count - start)
            guard itemsInRow > 0 else { break }
            // The last row stretches so there are no empty holes.
            let cellWidth = (area.width - gap * CGFloat(itemsInRow - 1)) / CGFloat(itemsInRow)
            let y = area.maxY - CGFloat(row + 1) * cellHeight - CGFloat(row) * gap
            for column in 0..<itemsInRow {
                let x = area.minX + CGFloat(column) * (cellWidth + gap)
                frames.append(NSRect(x: x, y: y, width: cellWidth, height: cellHeight))
            }
        }
        return frames
    }

    /// Picks the column count whose cells are closest to a comfortable terminal shape. Slightly
    /// wide of square: agent TUIs want height, and side-by-side reads better than stacked.
    nonisolated static func gridShape(count: Int, aspect: CGFloat) -> (columns: Int, rows: Int) {
        let target: CGFloat = 1.1
        var best = (columns: 1, rows: count)
        var bestScore = CGFloat.greatestFiniteMagnitude
        for columns in 1...count {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let cellAspect = aspect * CGFloat(rows) / CGFloat(columns)
            let empty = CGFloat(columns * rows - count) * 0.35
            let score = abs(log(cellAspect / target)) + empty
            if score < bestScore {
                bestScore = score
                best = (columns, rows)
            }
        }
        return best
    }
}
