import AppKit
import Combine
import SwiftUI

/// Sumi's place in the window: a round button in the bottom-left corner. Clicking it
/// opens Sumi's terminal in a panel floating above it; clicking again folds it back in.
/// Both float as child windows, so they ride over the sidebar and the canvas alike and move
/// with the window.
@MainActor
final class SumiDock {
    final class State: ObservableObject {
        @Published var isOpen = false
        @Published var markSize: CGFloat = 40
    }

    private let store: SessionStore
    private let state = State()
    private weak var window: NSWindow?
    private let button: NSPanel
    private let panel: SumiPanel
    private let container = SurfaceContainer()
    private var chooser: ChooserHostingView<SumiChooser>!
    private let chooserState = SumiChooserState()
    private var installedWatch: AnyCancellable?
    private var startWatch: Task<Void, Never>?
    private weak var session: TerminalSession?
    private var choiceWatch: AnyCancellable?
    /// Windows whose clicks leave Sumi open (popped-out tiles, the switcher, the mention picker).
    var keepsOpenForClicks: (NSWindow) -> Bool = { _ in false }

    /// The mark grows with the screen: 5% of its shorter side, between 40 and 60 points.
    static func markSize(for screen: NSScreen?) -> CGFloat {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return min(60, max(40, (min(visible.width, visible.height) * 0.05).rounded()))
    }

    private var buttonSize: CGFloat { state.markSize + Space.s }
    private static let inset: CGFloat = Space.m
    private static let panelSize = NSSize(width: 620, height: 460)
    private static let headerHeight: CGFloat = 36

    init(store: SessionStore) {
        self.store = store
        button = NSPanel(contentRect: NSRect(x: 0, y: 0, width: state.markSize + Space.s, height: state.markSize + Space.s),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = SumiPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        for floating in [button, panel] as [NSPanel] {
            floating.isOpaque = false
            floating.backgroundColor = .clear
            floating.appearance = NSAppearance(named: .darkAqua)
            floating.isReleasedWhenClosed = false
        }
        button.hasShadow = false
        button.contentView = NSHostingView(rootView: SumiButton(store: store, dock: state, toggle: { [weak self] in self?.toggle() }))
        panel.hasShadow = true

        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.backgroundColor = Ink.deep.cgColor
        frame.layer?.cornerRadius = Radius.pane
        frame.layer?.borderColor = Ink.hairline.cgColor
        frame.layer?.borderWidth = Size.hairline
        frame.layer?.masksToBounds = true
        let header = NSHostingView(rootView: SumiHeader(store: store, collapse: { [weak self] in self?.close() },
                                                             start: { [weak self] in self?.startIfNeeded() }))
        header.sizingOptions = []
        header.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        chooser = ChooserHostingView(rootView: SumiChooser(state: chooserState,
                                                                pick: { [weak self] in self?.pick($0) },
                                                                back: { [weak self] in self?.goBack() }))
        chooser.onKey = { [weak self] in self?.handleKey($0) ?? false }
        chooser.translatesAutoresizingMaskIntoConstraints = false
        chooser.isHidden = true
        frame.addSubview(container)
        frame.addSubview(chooser)
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
            chooser.topAnchor.constraint(equalTo: header.bottomAnchor),
            chooser.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            chooser.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            chooser.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
        ])
        panel.contentView = frame
        // Switching to a CLI it hasn't run on yet (here or in Settings) closes Sumi and
        // asks for a model.
        choiceWatch = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncChooser() }
        }
        installedWatch = InstalledAgents.shared.$kinds.sink { [weak self] _ in
            DispatchQueue.main.async { self?.skipCLIStepIfSole() }
        }
        // Clicking anywhere else in Tako folds it away, like a popover. Only a click: the
        // sumi's own work (a confirm sheet, a popped-out tile, an app it opens) also takes
        // focus from the panel, and must not fold it.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.closeOnClickAway(event); self?.focusOnClickIn(event) }
            return event
        }
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
        let markSize = Self.markSize(for: window.screen)
        if state.markSize != markSize { state.markSize = markSize }
        let origin = NSPoint(x: frame.minX + Self.inset, y: frame.minY + Self.inset)
        button.setFrame(NSRect(origin: origin, size: NSSize(width: buttonSize, height: buttonSize)), display: true)
        // Above the button, never taller or wider than the window leaves room for.
        let top = frame.maxY - 52
        let bottom = origin.y + buttonSize + Space.s
        let size = NSSize(width: min(Self.panelSize.width, frame.width - Self.inset * 2),
                          height: min(Self.panelSize.height, top - bottom))
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x, y: bottom), size: size), display: true)
    }

    // MARK: - Sumi's surface

    /// Called when Sumi starts or restarts: its terminal lives in the panel, not a tile.
    func attach(_ session: TerminalSession) {
        self.session = session
        container.show(session.surface)
        session.surface.setOccluded(!state.isOpen)
        if state.isOpen, chooser.isHidden { panel.makeFirstResponder(session.surface) }
    }

    func detach(_ session: TerminalSession) {
        guard self.session === session else { return }
        container.show(nil)
        self.session = nil
    }

    // MARK: - Opening and closing

    func toggle() {
        state.isOpen ? close() : open()
    }

    /// A click outside the panel and its button, except in a sheet (a confirm Sumi asked for).
    private func closeOnClickAway(_ event: NSEvent) {
        guard state.isOpen, let clicked = event.window, clicked !== panel, clicked !== button,
              clicked.sheetParent == nil, !keepsOpenForClicks(clicked) else { return }
        // The click is already taking focus where it landed.
        close(restoreFocus: false)
    }

    /// A click anywhere on the panel (its frame and header too) leaves the keyboard in the terminal,
    /// or in the chooser while it shows.
    private func focusOnClickIn(_ event: NSEvent) {
        guard state.isOpen, event.window === panel else { return }
        if !chooser.isHidden {
            if !panel.isKeyWindow { panel.makeKey() }
            if panel.firstResponder !== chooser, !(panel.firstResponder is NSText) { panel.makeFirstResponder(chooser) }
            return
        }
        guard let session else { return }
        if !panel.isKeyWindow { panel.makeKey() }
        if panel.firstResponder !== session.surface, !(panel.firstResponder is NSText) { panel.makeFirstResponder(session.surface) }
    }

    func open() {
        guard let window else { return }
        // The panel is the window's child: with the window hidden it would show nothing.
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        store.reconcileSumiKind()
        startIfNeeded()
        state.isOpen = true
        session?.unread = false
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        reposition()
        panel.makeKeyAndOrderFront(nil)
        if !chooser.isHidden {
            panel.makeFirstResponder(chooser)
        } else if let session {
            session.surface.setOccluded(false)
            panel.makeFirstResponder(session.surface)
        }
    }

    func close(restoreFocus: Bool = true) {
        state.isOpen = false
        // A reply that arrived while the panel was open was seen.
        session?.unread = false
        session?.surface.setOccluded(true)
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        guard restoreFocus, let window else { return }
        window.makeKeyAndOrderFront(nil)
        if let selected = store.selected, selected.surface.window === window { window.makeFirstResponder(selected.surface) }
    }

    /// The first time, the panel asks which CLI and model to run instead of starting one.
    private func startIfNeeded() {
        guard store.sumiNeedsChoice else {
            chooser.isHidden = true
            store.startSumi()
            return
        }
        showChooser()
    }

    /// Shows the chooser on its first step (or a model step, when there is nothing to choose
    /// between CLIs) and makes it the keyboard's target. A pending failure note stays as it is.
    private func showChooser() {
        InstalledAgents.shared.refresh()
        if chooserState.model.notice == nil {
            let installed = InstalledAgents.shared
            if let kind = SessionStore.chosenSumiKind ?? SumiOnboarding.soleCLI(installed: installed.kinds) {
                SessionStore.sumiKind = kind
                chooserState.model = .models(for: kind)
            } else {
                chooserState.model = .clis(isEnabled: installed.isInstalled)
            }
        }
        chooser.isHidden = false
        if state.isOpen { panel.makeFirstResponder(chooser) }
    }

    /// Installed CLIs just became known: with only one, its model step replaces the CLI step.
    private func skipCLIStepIfSole() {
        guard !chooser.isHidden, chooserState.model.step == nil,
              let kind = SumiOnboarding.soleCLI(installed: InstalledAgents.shared.kinds) else { return }
        choose(kind)
    }

    private var rows: (count: Int, isEnabled: (Int) -> Bool) {
        if let kind = chooserState.model.step { return (SessionStore.sumiModels(for: kind).count, { _ in true }) }
        let choices = SessionStore.sumiChoices
        return (choices.count, { InstalledAgents.shared.isInstalled(choices[$0]) })
    }

    private func handleKey(_ key: SumiChooserKey) -> Bool {
        let rows = rows
        switch chooserState.model.handle(key, count: rows.count, isEnabled: rows.isEnabled) {
        case .pick(let index): pick(index)
        case .back: goBack()
        case .none: break
        }
        return true
    }

    private func pick(_ index: Int) {
        if let kind = chooserState.model.step {
            let models = SessionStore.sumiModels(for: kind)
            if models.indices.contains(index) { chooseModel(models[index].name, of: kind) }
        } else {
            let choices = SessionStore.sumiChoices
            if choices.indices.contains(index) { choose(choices[index]) }
        }
    }

    /// One step back; on the first step (or with no CLI to go back to), folds the panel away.
    private func goBack() {
        if chooserState.model.step != nil, SumiOnboarding.soleCLI(installed: InstalledAgents.shared.kinds) == nil {
            chooserState.model = .clis(isEnabled: InstalledAgents.shared.isInstalled)
        } else {
            close()
        }
    }

    private func choose(_ kind: SessionKind) {
        store.chooseSumi(kind)
        chooserState.model = .models(for: kind)
        syncChooser()
    }

    private func chooseModel(_ name: String?, of kind: SessionKind) {
        chooserState.model.notice = nil
        chooser.isHidden = true
        store.chooseSumiModel(name, for: kind)
        watchStart(kind: kind, name: name)
    }

    /// A model the CLI won't run, or a CLI that isn't there, would otherwise leave "Not running".
    /// Within a few seconds of a choice, Sumi that is gone or has exited sends the user
    /// back to the model step with a note.
    private func watchStart(kind: SessionKind, name: String?) {
        startWatch?.cancel()
        let began = Date()
        startWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                // The user switched CLI or model since: another watch or no watch applies.
                guard SessionStore.sumiKind == kind, SessionStore.chosenSumiModel(for: kind) == (name ?? "") else { return }
                let sumi = store.sumi
                let exited = sumi.map { $0.isExitedProcess || { if case .failed = $0.state { return true } else { return false } }($0) }
                switch SumiOnboarding.startVerdict(exited: exited, launching: store.sumiStarting || store.launchingCount > 0,
                                                        elapsed: Date().timeIntervalSince(began)) {
                case .waiting: continue
                case .started: return
                case .failed:
                    if let sumi { store.close(sumi) }
                    SessionStore.forgetSumiModel(for: kind)
                    let title = SessionStore.sumiModels(for: kind).first { $0.name == name }?.title ?? name ?? "its default model"
                    chooserState.model = .models(for: kind, notice: SumiOnboarding.failureMessage(kind: kind, modelTitle: title), avoiding: name)
                    showChooser()
                    return
                }
            }
        }
    }

    private func syncChooser() {
        let hidden = !store.sumiNeedsChoice
        guard chooser.isHidden != hidden else { return }
        if hidden { chooser.isHidden = true } else { showChooser() }
    }
}

/// Takes the keyboard while the chooser shows, so keys never reach a terminal surface behind it.
private final class ChooserHostingView<Content: View>: NSHostingView<Content> {
    var onKey: ((SumiChooserKey) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = SumiChooserKey.from(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers),
              onKey?(key) == true else { return super.keyDown(with: event) }
    }
}

/// Borderless, but takes the keyboard: you type into Sumi's terminal here.
final class SumiPanel: NSPanel {
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

/// The round button: the Tako mark, moving with what Sumi is doing.
private struct SumiButton: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var dock: SumiDock.State
    let toggle: () -> Void
    @State private var hovering = false
    @AppStorage(SessionStore.sumiKindKey, store: SessionStore.sumiDefaults) private var chosen: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Nil until a CLI is chosen; one running from before there was a choice counts.
    private var kind: SessionKind? { store.sumi?.kind ?? SessionStore.chosenSumiKind }

    var body: some View {
        Button(action: toggle) {
            SumiMark(sumi: store.sumi, isOpen: dock.isOpen)
                .frame(width: dock.markSize, height: dock.markSize)
                .scaleEffect(hovering || dock.isOpen ? 1.08 : 1)
                .animation(Motion.animation(reduceMotion, Motion.quick), value: hovering || dock.isOpen)
                .overlay(alignment: .topTrailing) {
                    if let sumi = store.sumi {
                        SumiDot(session: sumi)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let kind { CLIBadge(kind: kind) }
                }
                // Phone Mode: Sumi is answering for the user.
                .overlay {
                    if store.isPhoneModeOn {
                        Circle().strokeBorder(Palette.attention, lineWidth: Size.hairline * 2)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if store.isPhoneModeOn { PhoneBadge() }
                }
                .frame(width: dock.markSize + Space.s, height: dock.markSize + Space.s)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help((store.isPhoneModeOn ? "Phone Mode on: Sumi answers agents for you. " : "")
              + (dock.isOpen ? "Hide Sumi (⌃⌘O)" : "Sumi\(kind.map { " (\($0.displayName))" } ?? ""): start agents, arrange the window, close sessions (⌃⌘O)"))
        .accessibilityLabel(dock.isOpen ? "Hide Sumi" : "Open Sumi")
    }
}

/// The mark, moving with Sumi's own state. It fills with the sun's color when the
/// sumi is blocked on you, or has replied while its panel was closed.
private struct SumiMark: View {
    let sumi: TerminalSession?
    let isOpen: Bool

    var body: some View {
        if let sumi {
            Live(session: sumi, isOpen: isOpen)
        } else {
            KuronamiMark(mood: .resting)
        }
    }

    private struct Live: View {
        @ObservedObject var session: TerminalSession
        let isOpen: Bool

        var body: some View { KuronamiMark(mood: KuronamiMark.sumiMood(session.state, unread: session.unread, isOpen: isOpen)) }
    }
}

/// Which CLI runs Sumi: its monogram in its own color, tucked into the mark's corner.
private struct CLIBadge: View {
    let kind: SessionKind

    var body: some View {
        KindMark(kind: kind, font: Typeface.micro)
            .foregroundStyle(kind.tint)
            .frame(width: Size.markBadge, height: Size.markBadge)
            .background(Tone.deep, in: Circle())
            .overlay(Circle().strokeBorder(Tone.hairline, lineWidth: Size.hairline))
            .accessibilityHidden(true)
    }
}

/// Phone Mode is on: a phone in gold, in the corner opposite the CLI badge.
private struct PhoneBadge: View {
    var body: some View {
        Image(systemName: "iphone")
            .font(Typeface.micro.weight(.bold))
            .foregroundStyle(Tone.deep)
            .frame(width: Size.markBadge, height: Size.markBadge)
            .background(Palette.attention, in: Circle())
            .accessibilityLabel("Phone Mode on")
    }
}

/// Failure is the one state the mark's motion doesn't say.
private struct SumiDot: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if case .failed = session.state { StatusDot(state: session.state) }
    }
}

/// The panel's title row: what Sumi is doing, which CLI runs it, and the fold button.
private struct SumiHeader: View {
    @ObservedObject var store: SessionStore
    let collapse: () -> Void
    let start: () -> Void

    var body: some View {
        let choosing = store.sumiNeedsChoice
        HStack(spacing: Space.s) {
            if let sumi = store.sumi {
                SumiTitle(session: sumi)
            } else {
                Text("Sumi").font(Typeface.headline).foregroundStyle(Tone.text)
                Text(choosing ? "Setup" : store.launchingCount > 0 ? "Starting…" : "Not running").font(Typeface.caption).foregroundStyle(Tone.faint)
                if store.launchingCount == 0 && !choosing {
                    Button("Start", action: start).buttonStyle(.plain).font(Typeface.caption.weight(.medium)).foregroundStyle(Tone.text)
                }
            }
            Spacer(minLength: 0)
            if !choosing { SumiCLIMenu(store: store) }
            Button(action: collapse) {
                Image(systemName: "chevron.down").font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.muted)
            }
            .buttonStyle(.plain)
            .help("Hide Sumi")
            .accessibilityLabel("Hide Sumi")
        }
        .padding(.horizontal, Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tone.deep)
    }
}

/// The CLI and model menu. It shows the CLI that was chosen, not the one still running: while a
/// switch or launch is in flight the two differ, and a model picked from the running CLI's list
/// would write that CLI back as the choice. It holds the store without observing it, so the
/// menu isn't rebuilt (and dismissed) by every session update; it redraws only when the saved
/// choice changes.
private struct SumiCLIMenu: View {
    let store: SessionStore
    /// The saved CLI and model this menu last drew; only a change in it redraws the menu.
    @State private var drawn = ""

    var body: some View {
        let shown = SessionStore.sumiKind
        let current = SessionStore.sumiModel(for: shown)
        let _ = drawn
        Menu {
            ForEach(SessionStore.sumiChoices) { kind in
                Button {
                    store.switchSumi(to: kind)
                } label: {
                    if kind == shown { Label(kind.displayName, systemImage: "checkmark") } else { Text(kind.displayName) }
                }
            }
            Section("Model") {
                ForEach(SessionStore.sumiModels(for: shown)) { model in
                    let title = model.title + (model.recommended ? " (Recommended)" : "")
                    Button {
                        store.chooseSumiModel(model.name, for: shown)
                    } label: {
                        if model.name == current { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
        } label: {
            Text(shown.displayName)
                .font(Typeface.caption.weight(.medium))
                .foregroundStyle(shown.tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which agent and model run Sumi. Switching restarts it.")
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: SessionStore.sumiDefaults)) { _ in
            let kind = SessionStore.sumiKind
            let saved = "\(kind.rawValue)|\(SessionStore.sumiModel(for: kind) ?? "")"
            if saved != drawn { drawn = saved }
        }
    }
}

private struct SumiTitle: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        StatusDot(state: session.state)
        Text("Sumi").font(Typeface.headline).foregroundStyle(Tone.text)
        Text(line).font(Typeface.caption).foregroundStyle(Tone.faint).lineLimit(1).truncationMode(.tail)
    }

    private var line: String {
        switch session.state {
        case .working: return session.activity ?? "Working"
        case .idle:
            let model = session.spec.options?.model
            let title = model.map { name in SessionStore.sumiModels(for: session.kind).first { $0.name == name }?.title ?? name }
            return [title, "Full access"].compactMap { $0 }.joined(separator: " · ")
        default: return session.state.phrase
        }
    }
}

@MainActor
final class SumiChooserState: ObservableObject {
    @Published var model = SumiChooserModel()
}

/// The first time the panel opens: which CLI runs Sumi, then which of its models. Ones
/// not on the PATH show, greyed. Keys drive it (see SumiChooserKey); the selected row has a ring.
private struct SumiChooser: View {
    @ObservedObject var state: SumiChooserState
    let pick: (Int) -> Void
    let back: () -> Void
    @ObservedObject private var installed = InstalledAgents.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let notice = state.model.notice {
                Text(notice).font(Typeface.caption.weight(.medium)).foregroundStyle(Palette.attention)
                    .frame(width: 300, alignment: .leading)
            }
            if let kind = state.model.step {
                models(kind)
            } else {
                clis
            }
            Spacer(minLength: 0)
            Text(hint).font(Typeface.caption).foregroundStyle(Tone.faint)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tone.deep)
    }

    private var hint: String {
        state.model.step == nil ? "↑↓ choose · ↩ select · esc close" : "↑↓ choose · ↩ start · esc back"
    }

    @ViewBuilder private var clis: some View {
        Text("Run Sumi with").font(Typeface.headline).foregroundStyle(Tone.text)
        ForEach(Array(SessionStore.sumiChoices.enumerated()), id: \.element) { index, kind in
            let available = installed.isInstalled(kind)
            Button { pick(index) } label: {
                HStack(spacing: Space.s) {
                    AgentAvatar(kind: kind, dimmed: !available)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(kind.displayName).font(Typeface.body.weight(.medium)).foregroundStyle(available ? Tone.text : Tone.faint)
                        Text(available ? kind.sumiNote : "not installed").font(Typeface.caption).foregroundStyle(Tone.faint)
                    }
                    Spacer(minLength: 0)
                    Text("\(index + 1)").font(Typeface.caption).foregroundStyle(Tone.faint)
                }
                .modifier(ChoiceRow(selected: state.model.selection == index && available))
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .onHover { if $0, available { state.model.selection = index } }
        }
        Text("You can change it later in the header or in Settings.").font(Typeface.caption).foregroundStyle(Tone.faint)
    }

    /// The second step: a small model is recommended, since Sumi wakes on every update.
    @ViewBuilder private func models(_ kind: SessionKind) -> some View {
        let models = SessionStore.sumiModels(for: kind)
        Text("Pick \(kind.displayName)'s model").font(Typeface.headline).foregroundStyle(Tone.text)
        Text("It wakes on every update it watches, so a smaller model saves the most tokens.")
            .font(Typeface.caption).foregroundStyle(Tone.faint).frame(width: 300, alignment: .leading)
        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
            Button { pick(index) } label: {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.s) {
                        Text(model.title).font(Typeface.body.weight(.medium)).foregroundStyle(Tone.text)
                        if model.recommended { Tag(text: "Recommended", tint: Palette.accent) }
                        Spacer(minLength: 0)
                        Text("\(index + 1)").font(Typeface.caption).foregroundStyle(Tone.faint)
                    }
                    Text(model.detail).font(Typeface.caption).foregroundStyle(Tone.faint).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ChoiceRow(selected: state.model.selection == index))
            }
            .buttonStyle(.plain)
            .onHover { if $0 { state.model.selection = index } }
        }
        if models.indices.contains(state.model.selection) {
            Button { pick(state.model.selection) } label: {
                Text("Start with \(models[state.model.selection].title)")
                    .font(Typeface.body.weight(.medium)).foregroundStyle(Tone.text)
                    .frame(width: 300)
                    .padding(.vertical, Space.s)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        if SumiOnboarding.soleCLI(installed: installed.kinds) == nil {
            Button("Choose another CLI", action: back)
                .buttonStyle(.plain).font(Typeface.caption).foregroundStyle(Tone.muted)
        }
    }
}

/// One choice on the chooser: a fixed-width card, ringed while selected.
private struct ChoiceRow: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .padding(Space.s)
            .frame(width: 300)
            .background(selected ? Tone.surface.opacity(1) : Tone.surface.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .strokeBorder(selected ? Palette.accent : Color.clear, lineWidth: Size.hairline * 2))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}

extension SessionKind {
    /// One line on Sumi chooser.
    var sumiNote: String {
        switch self {
        case .claude: return "Anthropic's agent, on your Claude plan or API key."
        case .codex: return "OpenAI's agent, on your ChatGPT plan or API key."
        default: return displayName
        }
    }
}
