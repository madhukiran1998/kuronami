import AppKit
import SwiftUI

/// The organizer's place in the window: a round button in the bottom-left corner. Clicking it
/// opens the organizer's terminal in a panel floating above it; clicking again folds it back in.
/// Both float as child windows, so they ride over the sidebar and the canvas alike and move
/// with the window.
@MainActor
final class OrganizerDock {
    final class State: ObservableObject {
        @Published var isOpen = false
    }

    private let store: SessionStore
    private let state = State()
    private weak var window: NSWindow?
    private let button: NSPanel
    private let panel: OrganizerPanel
    private let container = SurfaceContainer()
    private weak var session: TerminalSession?

    static let buttonSize: CGFloat = 40
    static let markSize: CGFloat = 30
    private static let inset: CGFloat = Space.m
    private static let panelSize = NSSize(width: 620, height: 460)
    private static let headerHeight: CGFloat = 36

    init(store: SessionStore) {
        self.store = store
        button = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = OrganizerPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        for floating in [button, panel] as [NSPanel] {
            floating.isOpaque = false
            floating.backgroundColor = .clear
            floating.appearance = NSAppearance(named: .darkAqua)
            floating.isReleasedWhenClosed = false
        }
        button.hasShadow = false
        button.contentView = NSHostingView(rootView: OrganizerButton(store: store, dock: state, toggle: { [weak self] in self?.toggle() }))
        panel.hasShadow = true

        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.backgroundColor = Ink.deep.cgColor
        frame.layer?.cornerRadius = Radius.pane
        frame.layer?.borderColor = Ink.hairline.cgColor
        frame.layer?.borderWidth = Size.hairline
        frame.layer?.masksToBounds = true
        let header = NSHostingView(rootView: OrganizerHeader(store: store, collapse: { [weak self] in self?.close() },
                                                             start: { [weak self] in self?.startIfNeeded() }))
        header.sizingOptions = []
        header.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(container)
        frame.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: frame.topAnchor),
            header.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            container.topAnchor.constraint(equalTo: header.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Space.xs),
            container.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Space.xs),
            container.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -Space.xs),
        ])
        panel.contentView = frame
    }

    /// Puts the button in `window`'s corner. Called again whenever the window comes back, since
    /// hiding the window drops its child windows.
    func install(in window: NSWindow) {
        self.window = window
        if button.parent !== window { window.addChildWindow(button, ordered: .above) }
        if state.isOpen, panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        reposition()
    }

    func reposition() {
        guard let window else { return }
        let frame = window.frame
        let origin = NSPoint(x: frame.minX + Self.inset, y: frame.minY + Self.inset)
        button.setFrame(NSRect(origin: origin, size: NSSize(width: Self.buttonSize, height: Self.buttonSize)), display: true)
        // Above the button, never taller or wider than the window leaves room for.
        let top = frame.maxY - 52
        let bottom = origin.y + Self.buttonSize + Space.s
        let size = NSSize(width: min(Self.panelSize.width, frame.width - Self.inset * 2),
                          height: min(Self.panelSize.height, top - bottom))
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x, y: bottom), size: size), display: true)
    }

    // MARK: - The organizer's surface

    /// Called when the organizer starts or restarts: its terminal lives in the panel, not a tile.
    func attach(_ session: TerminalSession) {
        self.session = session
        container.show(session.surface)
        session.surface.setOccluded(!state.isOpen)
        if state.isOpen { panel.makeFirstResponder(session.surface) }
    }

    func detach(_ session: TerminalSession) {
        guard self.session === session else { return }
        container.show(nil)
        self.session = nil
    }

    // MARK: - Opening and closing

    func toggle() { state.isOpen ? close() : open() }

    func open() {
        guard let window else { return }
        startIfNeeded()
        state.isOpen = true
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        reposition()
        panel.makeKeyAndOrderFront(nil)
        if let session {
            session.surface.setOccluded(false)
            panel.makeFirstResponder(session.surface)
        }
    }

    func close() {
        state.isOpen = false
        session?.surface.setOccluded(true)
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        if let selected = store.selected { window.makeFirstResponder(selected.surface) }
    }

    private func startIfNeeded() {
        store.startOrganizer(cwd: store.selected.map { $0.git?.mainRoot ?? $0.spec.cwd } ?? NSHomeDirectory())
    }
}

/// Borderless, but takes the keyboard: you type into the organizer's terminal here.
final class OrganizerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Holds one terminal surface at a time, sized to fill it.
private final class SurfaceContainer: NSView {
    private var surface: NSView?

    func show(_ surface: NSView?) {
        guard surface !== self.surface else { return }
        self.surface?.removeFromSuperview()
        self.surface = surface
        if let surface {
            surface.removeFromSuperview()
            addSubview(surface)
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        if let surface, surface.frame != bounds { surface.frame = bounds }
    }
}

extension TerminalSession {
    var isExitedProcess: Bool {
        if case .exited = state { return true }
        return false
    }
}

// MARK: - Views

/// The round button: the Kuronami mark, moving with what the organizer is doing.
private struct OrganizerButton: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var dock: OrganizerDock.State
    let toggle: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mood: KuronamiMark.Mood {
        switch store.organizer?.state {
        case .working?, .starting?: return .working
        case .needsInput?: return .needsYou
        default: return .resting
        }
    }

    var body: some View {
        Button(action: toggle) {
            KuronamiMark(mood: mood)
                .frame(width: OrganizerDock.markSize, height: OrganizerDock.markSize)
                .scaleEffect(hovering || dock.isOpen ? 1.08 : 1)
                .animation(Motion.animation(reduceMotion, Motion.quick), value: hovering || dock.isOpen)
                .overlay(alignment: .topTrailing) {
                    if let organizer = store.organizer {
                        OrganizerDot(session: organizer)
                    }
                }
                .frame(width: OrganizerDock.buttonSize, height: OrganizerDock.buttonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(dock.isOpen ? "Hide the organizer" : "Organizer: start agents, arrange the window, close sessions")
        .accessibilityLabel(dock.isOpen ? "Hide the organizer" : "Open the organizer")
    }
}

/// Failure is the one state the mark's motion doesn't say.
private struct OrganizerDot: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if case .failed = session.state { StatusDot(state: session.state) }
    }
}

/// The panel's title row: what the organizer is doing, which CLI runs it, and the fold button.
private struct OrganizerHeader: View {
    @ObservedObject var store: SessionStore
    let collapse: () -> Void
    let start: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            if let organizer = store.organizer {
                OrganizerTitle(session: organizer)
            } else {
                Text("Organizer").font(Typeface.headline).foregroundStyle(Tone.text)
                Text(store.launchingCount > 0 ? "Starting…" : "Not running").font(Typeface.caption).foregroundStyle(Tone.faint)
                if store.launchingCount == 0 {
                    Button("Start", action: start).buttonStyle(.plain).font(Typeface.caption.weight(.medium)).foregroundStyle(Tone.text)
                }
            }
            Spacer(minLength: 0)
            Menu {
                ForEach([SessionKind.claude, .codex]) { kind in
                    Button {
                        store.switchOrganizer(to: kind)
                    } label: {
                        if kind == SessionStore.organizerKind { Label(kind.displayName, systemImage: "checkmark") } else { Text(kind.displayName) }
                    }
                }
            } label: {
                Text(SessionStore.organizerKind.displayName)
                    .font(Typeface.caption.weight(.medium))
                    .foregroundStyle(SessionStore.organizerKind.tint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Which agent runs the organizer. Switching restarts it.")
            Button(action: collapse) {
                Image(systemName: "chevron.down").font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.muted)
            }
            .buttonStyle(.plain)
            .help("Hide the organizer")
            .accessibilityLabel("Hide the organizer")
        }
        .padding(.horizontal, Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tone.deep)
    }
}

private struct OrganizerTitle: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        StatusDot(state: session.state)
        Text("Organizer").font(Typeface.headline).foregroundStyle(Tone.text)
        Text(line).font(Typeface.caption).foregroundStyle(Tone.faint).lineLimit(1).truncationMode(.tail)
    }

    private var line: String {
        switch session.state {
        case .working: return session.activity ?? "Working"
        case .idle: return "Full access"
        default: return session.state.phrase
        }
    }
}
