import SwiftUI

/// Servers and parked tiles stay one click away without taking space from the canvas.
struct ServerStrip: View {
    @ObservedObject var store: SessionStore

    private var servers: [TerminalSession] {
        store.sessions.filter { $0.kind == .server && !$0.pinnedToGrid && !$0.isMinimized }
    }
    private var shelved: [TerminalSession] { store.sessions.filter(\.isMinimized) }

    var body: some View {
        let serverSessions = servers
        let parkedSessions = shelved
        ScrollView(.horizontal) {
            HStack(spacing: Space.xs) {
                ForEach(serverSessions) { ServerChip(session: $0, store: store) }
                if !serverSessions.isEmpty && !parkedSessions.isEmpty {
                    Rectangle().fill(Tone.hairline).frame(width: Size.hairline, height: Space.m).padding(.horizontal, Space.xs)
                }
                ForEach(parkedSessions) { ShelvedChip(session: $0, store: store) }
            }
            .padding(.horizontal, Space.s)
            .frame(maxHeight: .infinity)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tone.floor)
    }
}

/// A chip on the shelf: quiet fill, brighter on hover.
private struct ChipChrome: ViewModifier {
    var active = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(Typeface.caption.weight(.medium))
            .foregroundStyle(Tone.text)
            .padding(.horizontal, Space.s)
            .frame(height: Size.iconButton)
            .background(active || hovering ? Tone.raised : Tone.surface, in: RoundedRectangle(cornerRadius: Radius.control + 1, style: .continuous))
            .onHover { hovering = $0 }
    }
}

private struct ShelvedChip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore

    var body: some View {
        Button { store.select(session) } label: {
            HStack(spacing: Space.xs + 2) {
                KindMark(kind: session.kind, font: Typeface.micro).foregroundStyle(session.kind.tint)
                Text(session.label).lineLimit(1)
                StatusDot(state: session.state, size: 5)
            }
            .modifier(ChipChrome())
        }
        .buttonStyle(.plain)
        .help("Restore \(session.label) · \(session.statusWord)")
        .accessibilityLabel("Restore \(session.label), \(session.statusWord)")
        .contextMenu { Button("Restore") { store.select(session) } }
    }
}

private struct ServerChip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var showing = false
    @State private var logs = ""

    var body: some View {
        Button {
            logs = session.surface.readText(lastLines: 80)
            showing.toggle()
        } label: {
            HStack(spacing: Space.xs + 2) {
                StatusDot(state: session.state, size: 5)
                Text(session.label).lineLimit(1)
                ForEach(session.ports.prefix(2), id: \.self) { port in
                    Text(":" + String(port)).font(Typeface.micro.monospaced()).foregroundStyle(Palette.running)
                }
            }
            .modifier(ChipChrome(active: showing))
        }
        .buttonStyle(.plain)
        .help("Logs and actions for \(session.label)")
        .accessibilityLabel("Server \(session.label), \(session.statusWord)")
        .popover(isPresented: $showing, arrowEdge: .top) { detail }
        .contextMenu {
            Button("Show as Tile") { session.pinnedToGrid = true; store.select(session) }
            if let port = session.ports.first {
                Button("Open in Browser") { open(port) }
                Button("Preview") { PreviewWindowController.show(port: port) }
            }
            Button("Restart") { session.restart() }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(session.label).font(Typeface.headline)
                    Text(shortPath(session.spec.cwd))
                        .font(Typeface.codeSmall)
                        .foregroundStyle(Tone.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                HStack(spacing: Space.xs) {
                    StatusDot(state: session.state, size: 6)
                    Text(session.statusWord)
                }
                .font(Typeface.caption)
                .foregroundStyle(Tone.muted)
            }
            ScrollView {
                Text(logs.isEmpty ? "No output yet." : logs)
                    .font(Typeface.codeSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(Space.m)
            }
            .frame(height: 260)
            .background(Color(nsColor: Theme.terminalBackground), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .foregroundStyle(Color(nsColor: Theme.terminalForeground))
            HStack(spacing: Space.s) {
                Button("Restart") { session.restart(); showing = false }
                Button("Refresh") { logs = session.surface.readText(lastLines: 80) }
                if let port = session.ports.first {
                    Button("Open in Browser") { open(port) }
                    Button("Preview") { PreviewWindowController.show(port: port) }
                }
                Spacer()
                Button("Show as Tile") {
                    session.pinnedToGrid = true
                    showing = false
                    store.select(session)
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(PanelButtonStyle())
        }
        .padding(Space.l)
        .frame(width: 520)
        .foregroundStyle(Tone.text)
        .background(Tone.deep)
    }

    private func open(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }
}

/// Toolbar center: how many agents are working, and how many need you. Approvals are answered
/// on the agent's own card (or ⌥⌘Y / ⌥⌘N); this only takes you there.
struct AttentionQueue: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        let waiting = store.attentionCount
        let working = store.sessions.filter { $0.state == .working || $0.state == .starting }.count
        if waiting > 0 {
            Button { store.selectNextNeedingAttention() } label: {
                HStack(spacing: Space.xs + 2) {
                    Circle().fill(Palette.attention).frame(width: 6, height: 6)
                    Text(waiting == 1 ? "1 needs you" : "\(waiting) need you")
                    KeyboardHint(keys: "⌘J")
                }
                .font(Typeface.callout.weight(.semibold))
                .foregroundStyle(Palette.attention)
                .padding(.leading, Space.s + 2)
                .padding(.trailing, Space.xs)
                .frame(height: 24)
                .background(Palette.attention.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Go to the agent that has waited longest (⌘J)")
        } else if working > 0 {
            HStack(spacing: Space.xs + 2) {
                Circle().fill(Palette.working).frame(width: 6, height: 6)
                Text("\(working) working")
            }
            .font(Typeface.callout)
            .foregroundStyle(Tone.muted)
            .frame(height: 24)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
