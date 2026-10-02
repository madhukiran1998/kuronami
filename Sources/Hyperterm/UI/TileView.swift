import AppKit
import SwiftUI

/// A session's terminal plus, in split/grid layouts, a slim header naming it. The surface is
/// reparented into whichever tile shows it; the process keeps running regardless.
@MainActor
final class TileView: NSView {
    let session: TerminalSession
    private let header: NSHostingView<TileHeader>
    private let model: TileHeaderModel
    private let border = CALayer()
    private let dimmer = PassthroughView()
    private let headerRule = CALayer()
    private static let headerHeight: CGFloat = 27
    private static let radius: CGFloat = 7

    let search = SearchModel()
    private var recapHost: NSHostingView<RecapBanner>?

    /// "Since you left 14m ago: 6 edits, tests passed, finished: …" when returning to an agent.
    func showRecapIfNeeded() {
        let events = session.timeline.filter { $0.date > session.lastViewedAt }
        guard session.kind.isAgent, !events.isEmpty, Date().timeIntervalSince(session.lastViewedAt) > 120 else { return }
        recapHost?.removeFromSuperview()
        let host = NSHostingView(rootView: RecapBanner(
            since: session.lastViewedAt, sentence: Recap.sentence(for: events),
            onDismiss: { [weak self] in self?.recapHost?.removeFromSuperview(); self?.recapHost = nil }))
        addSubview(host, positioned: .above, relativeTo: nil)
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
    private var searchHost: NSHostingView<SearchBar>?

    func showSearch() {
        if let searchHost { searchHost.isHidden = false; window?.makeFirstResponder(searchHost); return }
        let surface = session.surface
        let host = NSHostingView(rootView: SearchBar(
            model: search,
            onChange: { needle in surface.performBinding("search:" + needle) },
            onNext: { surface.performBinding("navigate_search:next") },
            onPrevious: { surface.performBinding("navigate_search:previous") },
            onClose: { [weak self] in self?.hideSearch() }))
        host.frame.size = host.fittingSize
        addSubview(host, positioned: .above, relativeTo: nil)
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

    var showsHeader = false { didSet { needsLayout = true; header.isHidden = !showsHeader; updateBorder() } }
    var isFocusedTile = false { didSet { model.focused = isFocusedTile; updateBorder() } }

    init(session: TerminalSession, onSelect: @escaping () -> Void, onZoom: @escaping () -> Void) {
        self.session = session
        self.model = TileHeaderModel()
        self.header = NSHostingView(rootView: TileHeader(session: session, model: model, onSelect: onSelect, onZoom: onZoom))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.terminalBackground.cgColor
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        border.borderWidth = 1
        border.cornerRadius = Self.radius
        border.cornerCurve = .continuous
        border.zPosition = 11
        // Unfocused tiles recede so the one taking keystrokes is obvious at a glance.
        dimmer.wantsLayer = true
        dimmer.layer?.backgroundColor = NSColor.black.withAlphaComponent(Theme.isDark ? 0.32 : 0.12).cgColor
        dimmer.isHidden = true
        headerRule.backgroundColor = NSColor.separatorColor.cgColor
        headerRule.zPosition = 9
        [border, headerRule].forEach { layer?.addSublayer($0) }
        addSubview(header)
        addSubview(dimmer)
        header.isHidden = true
        attachSurface()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Called after a restart swaps the session's surface.
    func attachSurface() {
        subviews.filter { $0 is TerminalSurfaceView && $0 !== session.surface }.forEach { $0.removeFromSuperview() }
        if session.surface.superview !== self {
            session.surface.removeFromSuperview()
            addSubview(session.surface, positioned: .below, relativeTo: header)
        }
        needsLayout = true
    }

    func refreshAttention() { updateBorder() }

    override func layout() {
        super.layout()
        let headerHeight = showsHeader ? Self.headerHeight : 0
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        // Inset the terminal slightly inside tiles so text doesn't touch the rounded border.
        let inset: CGFloat = showsHeader ? 4 : 0
        session.surface.frame = NSRect(x: inset, y: inset, width: bounds.width - inset * 2,
                                       height: bounds.height - headerHeight - inset * 2)
        dimmer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - headerHeight)
        if let recapHost {
            let width = min(bounds.width - 24, 560)
            let height = recapHost.fittingSize.height
            recapHost.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - headerHeight - height - 12, width: width, height: height)
        }
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
        CATransaction.commit()
    }

    private func updateBorder() {
        let color: NSColor
        if !showsHeader {
            color = .clear
        } else if session.state.needsAttention {
            color = NSColor(Palette.attention).withAlphaComponent(0.8)
        } else if isFocusedTile {
            color = Theme.focusRing
        } else {
            color = NSColor.separatorColor
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        border.borderColor = color.cgColor
        border.borderWidth = session.state.needsAttention && showsHeader ? 1.5 : 1
        CATransaction.commit()
        dimmer.isHidden = !(showsHeader && !isFocusedTile)
        let radius = showsHeader ? Self.radius : 0
        layer?.cornerRadius = radius
        border.cornerRadius = radius
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

struct TileHeader: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: TileHeaderModel
    let onSelect: () -> Void
    let onZoom: () -> Void
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            HStack(spacing: 7) {
                StatusDot(state: session.state, size: 6)
                Text("@" + session.label)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(model.focused ? Color.primary : Color.primary.opacity(0.6))
                if let summary = headerSummary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(session.state.needsAttention ? Palette.attention : Color.secondary.opacity(model.focused ? 0.9 : 0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if !session.ports.isEmpty { PortChips(ports: session.ports, compact: true) }
                if let state = stateLine(now: context.date) {
                    Text(state)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(session.state.needsAttention ? Palette.attention : Color.secondary.opacity(0.7))
                        .lineLimit(1)
                }
                Button(action: onZoom) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Zoom (⌘⏎)")
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.bar)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2, perform: onZoom)
            .onTapGesture(perform: onSelect)
        }
    }

    private var headerSummary: String? {
        if case .needsInput(let reason) = session.state { return reason }
        return session.kind.isAgent ? session.summary : session.foregroundProcess
    }

    /// Agents show their turn state; shells and servers are already described by the dot.
    private func stateLine(now: Date) -> String? {
        switch session.state {
        case .working, .needsInput, .idle:
            return "\(session.state.phrase) \(elapsed(since: session.stateChangedAt, now: now))"
        case .failed, .exited, .starting:
            return session.state.phrase
        case .running:
            return nil
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
