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
        let tile = TileView(session: session,
                            onSelect: { [weak self] in self?.onSelectTile?(id) },
                            onZoom: { [weak self] in self?.onZoomTile?(id) })
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
        let frames = Self.frames(count: visibleOrder.count, in: area, mode: mode)
        for (id, frame) in zip(visibleOrder, frames) {
            tiles[id]?.frame = frame.integral
        }
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
