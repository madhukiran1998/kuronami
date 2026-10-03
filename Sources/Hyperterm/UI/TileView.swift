import AppKit
import Combine
import SwiftUI

/// A session's terminal plus, in split/grid layouts, a slim header naming it. The surface is
/// reparented into whichever tile shows it; the process keeps running regardless.
///
/// Focus and attention have separate, static indicators. Idle chrome does no animation work.
@MainActor
final class TileView: NSView {
    let session: TerminalSession
    private let content = NSView()
    private let header: NSHostingView<TileHeader>
    private let model: TileHeaderModel
    private let border = CALayer()
    private let headerRule = CALayer()
    private let attentionMarker = CALayer()
    private var recapHost: NSHostingView<RecapBanner>?
    private var searchHost: NSHostingView<SearchBar>?
    let search = SearchModel()

    private static let headerHeight: CGFloat = 34
    private static let radius: CGFloat = 10
    private var isVisible = false
    private var lifted = false

    var showsHeader = false {
        didSet {
            guard showsHeader != oldValue else { return }
            header.isHidden = !showsHeader
            model.setVisible(isVisible && showsHeader, session: session)
            needsLayout = true
            updateChrome()
        }
    }
    var isFocusedTile = false {
        didSet {
            guard isFocusedTile != oldValue else { return }
            model.focused = isFocusedTile
            updateChrome()
        }
    }
    /// The chrome last drawn, so status refreshes that change nothing visible cost nothing.
    private var drawnChrome: Chrome?

    private struct Chrome: Equatable {
        let header: Bool
        let focused: Bool
        let attention: Bool
    }

    init(session: TerminalSession, actions: TileActions) {
        self.session = session
        self.model = TileHeaderModel(session: session)
        self.header = NSHostingView(rootView: TileHeader(model: model, actions: actions))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        header.sizingOptions = []
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.terminalBackground.cgColor
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        addSubview(content)

        border.borderWidth = 1
        border.cornerCurve = .continuous
        border.zPosition = 20
        headerRule.backgroundColor = Ink.hairline.cgColor
        headerRule.zPosition = 9
        attentionMarker.backgroundColor = NSColor(Palette.attention).cgColor
        attentionMarker.cornerRadius = 1
        attentionMarker.zPosition = 21
        attentionMarker.isHidden = true
        content.layer?.addSublayer(headerRule)
        layer?.addSublayer(border)
        layer?.addSublayer(attentionMarker)

        content.addSubview(header)
        header.isHidden = true
        attachSurface()
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Called after a restart swaps the session's surface.
    func attachSurface() {
        content.subviews.filter { $0 is any SessionSurface && $0 !== session.surface }.forEach { $0.removeFromSuperview() }
        if session.surface.superview !== content {
            session.surface.removeFromSuperview()
            content.addSubview(session.surface, positioned: .below, relativeTo: header)
            session.surface.setOccluded(!isVisible)
            needsLayout = true
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        isHidden = !visible
        session.surface.setOccluded(!visible)
        model.setVisible(visible && showsHeader, session: session)
        if visible { updateChrome() }
    }

    func refreshAttention() {
        model.refresh(session)
        updateChrome()
    }

    /// Picked up by its header: drawn above the other tiles with a deeper shadow.
    func setLifted(_ lifted: Bool) {
        self.lifted = lifted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.zPosition = lifted ? 100 : 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowRadius = lifted ? 20 : 0
        layer?.shadowOpacity = lifted ? 0.45 : 0
        layer?.shadowPath = lifted ? CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil) : nil
        CATransaction.commit()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        if content.frame != bounds { content.frame = bounds }
        let headerHeight = showsHeader ? Self.headerHeight : 0
        let headerFrame = NSRect(x: 0, y: max(0, bounds.height - headerHeight), width: bounds.width, height: headerHeight)
        if header.frame != headerFrame { header.frame = headerFrame }
        let surfaceFrame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
        if session.surface.frame != surfaceFrame { session.surface.frame = surfaceFrame }
        if let recapHost {
            let width = max(0, min(bounds.width - 24, 560))
            let height = recapHost.fittingSize.height
            recapHost.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - headerHeight - height - 12, width: width, height: height)
        }
        if let searchHost {
            let size = searchHost.fittingSize
            searchHost.frame = NSRect(x: bounds.width - size.width - 12, y: bounds.height - headerHeight - size.height - 10,
                                      width: size.width, height: size.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        headerRule.frame = NSRect(x: 0, y: bounds.height - headerHeight - 1, width: bounds.width, height: 1)
        headerRule.isHidden = !showsHeader
        attentionMarker.frame = NSRect(x: 0, y: 12, width: 2, height: max(0, bounds.height - 24))
        CATransaction.commit()
    }

    // MARK: - Chrome

    private func updateChrome() {
        let chrome = Chrome(header: showsHeader, focused: isFocusedTile,
                            attention: session.state.needsAttention)
        guard chrome != drawnChrome else { return }
        drawnChrome = chrome
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layer?.cornerRadius = Self.radius
        border.cornerRadius = Self.radius
        if isFocusedTile {
            border.borderColor = Ink.accent.withAlphaComponent(showsHeader ? 0.7 : 0.35).cgColor
            border.borderWidth = 1
        } else {
            border.borderColor = Ink.hairline.cgColor
            border.borderWidth = 1
        }
        attentionMarker.isHidden = !chrome.attention
        headerRule.backgroundColor = Ink.hairline.withAlphaComponent(0.7).cgColor
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard frame.size != newSize else { return }
        super.setFrameSize(newSize)
        if lifted {
            layer?.shadowPath = CGPath(roundedRect: NSRect(origin: .zero, size: newSize), cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        }
    }

    // MARK: - Overlays

    /// "Since you left 14m ago: 6 edits, tests passed, finished: …" when returning to an agent.
    func showRecapIfNeeded() {
        let events = session.timeline.filter { $0.date > session.lastViewedAt }
        guard session.kind.isAgent, !events.isEmpty, Date().timeIntervalSince(session.lastViewedAt) > 120 else { return }
        recapHost?.removeFromSuperview()
        let host = NSHostingView(rootView: RecapBanner(
            since: session.lastViewedAt, sentence: Recap.sentence(for: events),
            onDismiss: { [weak self] in self?.recapHost?.removeFromSuperview(); self?.recapHost = nil }))
        content.addSubview(host, positioned: .above, relativeTo: nil)
        recapHost = host
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak host] in
            guard let self, let host, self.recapHost === host else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; host.animator().alphaValue = 0 } completionHandler: {
                MainActor.assumeIsolated {
                    host.removeFromSuperview()
                    if self.recapHost === host { self.recapHost = nil }
                }
            }
        }
    }

    func showSearch() {
        if let searchHost { searchHost.isHidden = false; window?.makeFirstResponder(searchHost); return }
        let host = NSHostingView(rootView: SearchBar(
            model: search,
            onChange: { [weak self] needle in self?.session.surface.performBinding("search:" + needle) },
            onNext: { [weak self] in self?.session.surface.performBinding("navigate_search:next") },
            onPrevious: { [weak self] in self?.session.surface.performBinding("navigate_search:previous") },
            onClose: { [weak self] in self?.hideSearch() }))
        content.addSubview(host, positioned: .above, relativeTo: nil)
        searchHost = host
        needsLayout = true
    }

    func hideSearch() {
        session.surface.performBinding("end_search")
        search.needle = ""
        search.total = nil
        search.selected = nil
        searchHost?.removeFromSuperview()
        searchHost = nil
        window?.makeFirstResponder(session.surface)
    }
}

@MainActor
final class TileHeaderModel: ObservableObject {
    @Published var focused = false
    @Published private(set) var isVisible = false
    @Published private(set) var snapshot: TileHeaderSnapshot
    private var subscription: AnyCancellable?
    private var refreshQueued = false

    init(session: TerminalSession) {
        snapshot = TileHeaderSnapshot(session: session)
        // A poll can publish many unrelated metrics. Read only once, after those values land.
        subscription = session.objectWillChange.sink { [weak self, weak session] _ in
            guard let self, self.isVisible, !self.refreshQueued else { return }
            self.refreshQueued = true
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self else { return }
                self.refreshQueued = false
                if let session { self.refresh(session) }
            }
        }
    }

    func setVisible(_ visible: Bool, session: TerminalSession) {
        guard visible != isVisible else { return }
        if visible { update(TileHeaderSnapshot(session: session)) }
        isVisible = visible
    }

    func refresh(_ session: TerminalSession) {
        guard isVisible else { return }
        update(TileHeaderSnapshot(session: session))
    }

    private func update(_ next: TileHeaderSnapshot) {
        if snapshot != next { snapshot = next }
    }
}

/// Only fields actually drawn by a header participate in its invalidation.
struct TileHeaderSnapshot: Equatable {
    let label: String
    let kind: SessionKind
    let state: AgentState
    let stateChangedAt: Date
    let statusWord: String
    let ports: [Int]
    let summary: String?

    @MainActor init(session: TerminalSession) {
        label = session.label
        kind = session.kind
        state = session.state
        stateChangedAt = session.stateChangedAt
        statusWord = session.statusWord
        ports = session.ports
        if case .needsInput(let reason) = session.state {
            summary = session.pendingRequest ?? reason
        } else {
            summary = session.kind.isAgent ? (session.agentStatus ?? session.summary) : session.foregroundProcess
        }
    }
}

/// What a tile's header can ask of the canvas.
@MainActor
struct TileActions {
    var select: () -> Void
    var zoom: () -> Void
    var minimize: () -> Void
    var close: () -> Void
    /// Header drag in progress: translation from where it started (SwiftUI, y down).
    var drag: (CGSize) -> Void
    var dragEnded: () -> Void
}

struct TileHeader: View {
    @ObservedObject var model: TileHeaderModel
    let actions: TileActions
    @State private var hovering = false

    var body: some View {
        if model.isVisible {
            GeometryReader { geometry in header(compact: geometry.size.width < 340) }
        }
    }

    private func header(compact: Bool) -> some View {
        let snapshot = model.snapshot
        return HStack(spacing: 8) {
            if !compact {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color(nsColor: Ink.faint))
                    .help("Drag to rearrange")
            }
            KindMark(kind: snapshot.kind, size: 11)
                .foregroundStyle(snapshot.kind.tint)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(snapshot.kind.tint.opacity(0.1)))
            Text(snapshot.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: model.focused ? Ink.text : Ink.muted))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(snapshot.summary.map { "@\(snapshot.label) · \($0)" } ?? "@\(snapshot.label) · \(snapshot.kind.displayName)")
            Spacer(minLength: 4)
            if !snapshot.ports.isEmpty { PortChips(ports: snapshot.ports, compact: true) }
            if snapshot.kind == .browser {
                BrowserDriverBadge(label: snapshot.label)
            } else {
                StatusCapsule(state: snapshot.state, statusWord: snapshot.statusWord, changedAt: snapshot.stateChangedAt)
                    .fixedSize()
            }
            if compact {
                Menu {
                    Button("Zoom", action: actions.zoom)
                    Button("Minimize to Shelf", action: actions.minimize)
                    Divider()
                    Button("Close", action: actions.close)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: Ink.muted)).frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Tile actions · drag header to rearrange")
                .accessibilityLabel("Tile actions")
            } else {
                HStack(spacing: 2) {
                    HeaderButton(symbol: "minus", help: "Minimize to shelf (⇧⌘M)", action: actions.minimize)
                    HeaderButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom (⌘⏎)", action: actions.zoom)
                    HeaderButton(symbol: "xmark", help: "Close (⌘W)", action: actions.close)
                }
                .opacity(hovering || model.focused ? 1 : 0.55)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Ink.surface))
        .overlay(alignment: .bottom) {
            if model.focused { Color(nsColor: Ink.accent).opacity(0.12).frame(height: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: actions.zoom)
        .onTapGesture(perform: actions.select)
        // Drag the header to move the tile; the canvas reflows the others around it.
        .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { actions.drag($0.translation) }
            .onEnded { _ in actions.dragEnded() })
        .contextMenu {
            Button("Focus", action: actions.select)
            Button("Zoom", action: actions.zoom)
            Button("Minimize to Shelf", action: actions.minimize)
            Divider()
            Button("Close", action: actions.close)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(snapshot.label), \(snapshot.statusWord)\(model.focused ? ", focused" : "")")
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(nsColor: hovering ? Ink.text : Ink.muted))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Ink.raised).opacity(hovering ? 1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "Working 2m", "Needs you", "Done": the shared status vocabulary as a small capsule.
struct StatusCapsule: View {
    let state: AgentState
    let statusWord: String
    let changedAt: Date

    var body: some View {
        if state == .working {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                badge("Working \(elapsed(since: changedAt, now: context.date))")
            }
        } else {
            badge(statusWord)
        }
    }

    private func badge(_ text: String) -> some View {
        let color = Palette.status(state)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: state.needsAttention ? .semibold : .medium).monospacedDigit())
        .foregroundStyle(state.needsAttention ? Palette.attention : Color(nsColor: Ink.muted))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.07)))
        .overlay(Capsule().strokeBorder(color.opacity(0.12), lineWidth: 0.5))
    }
}

/// A browser's tile shows who is driving it, not a process status.
struct BrowserDriverBadge: View {
    let label: String

    var body: some View {
        if let activity = AgentBrowser.shared.activity, activity.browser == label {
            HStack(spacing: 4) {
                Circle().fill(Palette.working).frame(width: 5, height: 5)
                Text("@\(activity.agent) · \(activity.action)").lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.working.opacity(0.18)))
            .foregroundStyle(Palette.working)
            .transition(.opacity)
        }
    }
}

struct RecapBanner: View {
    let since: Date
    let sentence: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.working)
            VStack(alignment: .leading, spacing: 2) {
                Text("Since you left · \(elapsed(since: since)) ago").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}
