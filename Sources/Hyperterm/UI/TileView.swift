import AppKit
import SwiftUI

/// A session's terminal plus, in split/grid layouts, a slim header naming it. The surface is
/// reparented into whichever tile shows it; the process keeps running regardless.
///
/// Focus and attention are different signals: the focused tile gets an accent border; a tile that
/// needs you gets a breathing orange glow outside its edge, never a border.
@MainActor
final class TileView: NSView {
    let session: TerminalSession
    private let content = NSView()
    private let header: NSHostingView<TileHeader>
    private let model: TileHeaderModel
    private let border = CALayer()
    private let headerRule = CALayer()
    private let sweep = CAGradientLayer()
    private let dimmer = PassthroughView()
    private var recapHost: NSHostingView<RecapBanner>?
    private var searchHost: NSHostingView<SearchBar>?
    let search = SearchModel()

    private static let headerHeight: CGFloat = 28
    private static let radius: CGFloat = 12

    var showsHeader = false {
        didSet {
            guard showsHeader != oldValue else { return }
            header.isHidden = !showsHeader
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
        let working: Bool
    }

    init(session: TerminalSession, actions: TileActions) {
        self.session = session
        self.model = TileHeaderModel()
        self.header = NSHostingView(rootView: TileHeader(session: session, model: model, actions: actions))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        content.wantsLayer = true
        // Matches the terminal's 0.9 background opacity so the padding blends with the glass.
        content.layer?.backgroundColor = Theme.terminalBackground.withAlphaComponent(0.9).cgColor
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        addSubview(content)

        border.borderWidth = 1
        border.cornerCurve = .continuous
        border.zPosition = 20
        headerRule.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        headerRule.zPosition = 9
        sweep.colors = [NSColor.clear.cgColor, NSColor(Palette.working).withAlphaComponent(0.9).cgColor, NSColor.clear.cgColor]
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.zPosition = 10
        sweep.isHidden = true
        [headerRule, sweep].forEach { content.layer?.addSublayer($0) }
        layer?.addSublayer(border)

        dimmer.wantsLayer = true
        dimmer.layer?.backgroundColor = NSColor.black.withAlphaComponent(Theme.isDark ? 0.3 : 0.1).cgColor
        dimmer.isHidden = true
        content.addSubview(header)
        content.addSubview(dimmer)
        header.isHidden = true
        attachSurface()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Called after a restart swaps the session's surface.
    func attachSurface() {
        content.subviews.filter { $0 is TerminalSurfaceView && $0 !== session.surface }.forEach { $0.removeFromSuperview() }
        if session.surface.superview !== content {
            session.surface.removeFromSuperview()
            content.addSubview(session.surface, positioned: .below, relativeTo: header)
        }
        needsLayout = true
    }

    func refreshAttention() { updateChrome() }

    /// Picked up by its header: drawn above the other tiles with a deeper shadow.
    func setLifted(_ lifted: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer?.zPosition = lifted ? 100 : 0
        layer?.shadowRadius = lifted ? 28 : 12
        layer?.shadowOpacity = lifted ? 0.5 : 0.28
        alphaValue = lifted ? 0.94 : 1
        CATransaction.commit()
        if !lifted { drawnChrome = nil; updateChrome() }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        content.frame = bounds
        let headerHeight = showsHeader ? Self.headerHeight : 0
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        let inset: CGFloat = 0
        session.surface.frame = NSRect(x: inset, y: inset, width: bounds.width - inset * 2,
                                       height: bounds.height - headerHeight - inset * 2)
        dimmer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - headerHeight)
        if let recapHost {
            let width = min(bounds.width - 24, 560)
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
        sweep.frame = NSRect(x: 0, y: bounds.height - headerHeight - 1, width: bounds.width, height: 1.5)
        CATransaction.commit()
    }

    // MARK: - Chrome

    private func updateChrome() {
        let chrome = Chrome(header: showsHeader, focused: isFocusedTile,
                            attention: session.state.needsAttention, working: session.state == .working)
        guard chrome != drawnChrome else { return }
        drawnChrome = chrome
        // Every pane is a rounded, softly shadowed card on the glass.
        content.layer?.cornerRadius = Self.radius
        border.cornerRadius = Self.radius
        let attention = session.state.needsAttention
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        if showsHeader && isFocusedTile {
            border.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
            border.borderWidth = 1.5
        } else {
            border.borderColor = NSColor.white.withAlphaComponent(Theme.isDark ? 0.09 : 0.5).cgColor
            border.borderWidth = 0.5
        }
        CATransaction.commit()
        dimmer.isHidden = !(showsHeader && !isFocusedTile)
        setGlow(attention)
        setSweep(session.state == .working && showsHeader)
    }

    /// An orange halo that breathes slowly while the agent waits on you.
    private func setGlow(_ on: Bool) {
        guard let layer else { return }
        if on {
            layer.shadowColor = NSColor(Palette.attention).cgColor
            layer.shadowOffset = .zero
            layer.shadowRadius = 14
            layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
            guard layer.animation(forKey: "glow") == nil else { return }
            layer.shadowOpacity = 0.55
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let breathe = CABasicAnimation(keyPath: "shadowOpacity")
                breathe.fromValue = 0.25
                breathe.toValue = 0.7
                breathe.duration = 0.85
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(breathe, forKey: "glow")
            }
        } else {
            layer.removeAnimation(forKey: "glow")
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: -3)
            layer.shadowRadius = 12
            layer.shadowOpacity = 0.28
            layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        }
    }

    /// A light that travels along the header's bottom edge while the agent works.
    private func setSweep(_ on: Bool) {
        sweep.isHidden = !on
        guard on else { sweep.removeAnimation(forKey: "sweep"); return }
        guard sweep.animation(forKey: "sweep") == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        sweep.locations = [0, 0.1, 0.2]
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [-0.3, -0.15, 0]
        move.toValue = [1, 1.15, 1.3]
        move.duration = 1.8
        move.repeatCount = .infinity
        sweep.add(move, forKey: "sweep")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.shadowPath = CGPath(roundedRect: NSRect(origin: .zero, size: newSize), cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
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
        let surface = session.surface
        let host = NSHostingView(rootView: SearchBar(
            model: search,
            onChange: { needle in surface.performBinding("search:" + needle) },
            onNext: { surface.performBinding("navigate_search:next") },
            onPrevious: { surface.performBinding("navigate_search:previous") },
            onClose: { [weak self] in self?.hideSearch() }))
        content.addSubview(host, positioned: .above, relativeTo: nil)
        searchHost = host
        needsLayout = true
    }

    func hideSearch() {
        session.surface.performBinding("end_search")
        search.needle = ""
        search.total = nil
        searchHost?.removeFromSuperview()
        searchHost = nil
        window?.makeFirstResponder(session.surface)
    }
}

/// Visual-only overlay; clicks go through to the terminal underneath.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class TileHeaderModel: ObservableObject {
    @Published var focused = false
}

/// 26pt: the label, and a status capsule. The summary appears on hover only, since the agent's
/// own screen already says what it's doing.
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
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: TileHeaderModel
    let actions: TileActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: session.kind.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(session.kind.tint.opacity(model.focused ? 1 : 0.7))
            Text(session.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.focused ? Color.primary : Color.secondary)
                .lineLimit(1)
            if hovering, let summary = headerSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }
            Spacer(minLength: 6)
            if !session.ports.isEmpty { PortChips(ports: session.ports, compact: true) }
            if session.kind == .browser {
                BrowserDriverBadge(label: session.label)
            } else {
                StatusCapsule(session: session)
            }
            HStack(spacing: 2) {
                HeaderButton(symbol: "minus", help: "Minimize to shelf (⇧⌘M)", action: actions.minimize)
                HeaderButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom (⌘⏎)", action: actions.zoom)
                HeaderButton(symbol: "xmark", help: "Close (⌘W)", action: actions.close)
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(model.focused ? 0.045 : 0.02))
        .contentShape(Rectangle())
        .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovering = value } }
        .onTapGesture(count: 2, perform: actions.zoom)
        .onTapGesture(perform: actions.select)
        // Drag the header to move the tile; the canvas reflows the others around it.
        .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { actions.drag($0.translation) }
            .onEnded { _ in actions.dragEnded() })
    }

    private var headerSummary: String? {
        if case .needsInput(let reason) = session.state { return session.pendingRequest ?? reason }
        return session.kind.isAgent ? (session.agentStatus ?? session.summary) : session.foregroundProcess
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
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// "Working 2m", "Needs you", "Done": the shared status vocabulary as a small capsule.
struct StatusCapsule: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let color = Palette.status(session.state)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(text(now: context.date))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(session.state.needsAttention ? 0.25 : 0.12)))
            .foregroundStyle(session.state.needsAttention ? Palette.attention : Color.secondary)
        }
    }

    private func text(now: Date) -> String {
        switch session.state {
        case .working: return "Working \(elapsed(since: session.stateChangedAt, now: now))"
        default: return session.statusWord
        }
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
