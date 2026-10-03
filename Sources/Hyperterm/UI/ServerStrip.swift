import SwiftUI

/// Servers and parked sessions stay available without taking space from the canvas.
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
            HStack(spacing: 7) {
                if !serverSessions.isEmpty {
                    shelfLabel("bolt.horizontal", title: "SERVICES")
                    ForEach(serverSessions) { server in
                        ServerChip(session: server, store: store)
                    }
                }
                if !serverSessions.isEmpty && !parkedSessions.isEmpty {
                    Color(nsColor: Ink.hairline)
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 5)
                }
                if !parkedSessions.isEmpty {
                    shelfLabel("rectangle.bottomthird.inset.filled", title: "PARKED")
                    ForEach(parkedSessions) { session in
                        ShelvedChip(session: session, store: store)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Ink.deep))
        .overlay(alignment: .top) { Color(nsColor: Ink.hairline).frame(height: 1) }
    }

    private func shelfLabel(_ symbol: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .medium))
            Text(title).font(.system(size: 8, weight: .semibold)).tracking(0.8)
        }
        .foregroundStyle(Color(nsColor: Ink.faint))
        .padding(.trailing, 3)
        .fixedSize()
    }
}

private struct ShelvedChip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var hovering = false

    var body: some View {
        Button { store.select(session) } label: {
            HStack(spacing: 6) {
                KindMark(kind: session.kind, size: 10)
                    .foregroundStyle(session.kind.tint)
                Text(session.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Circle().fill(Palette.status(session.state)).frame(width: 5, height: 5)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Ink.muted))
                    .opacity(hovering ? 1 : 0)
            }
            .foregroundStyle(Color(nsColor: Ink.text))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(hovering ? Color(nsColor: Ink.raised) : Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(session.state.needsAttention ? Palette.attention.opacity(0.55) : Color(nsColor: Ink.hairline)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Restore @\(session.label) · \(session.statusWord)")
        .accessibilityLabel("Restore \(session.label), \(session.statusWord)")
        .contextMenu {
            Button("Restore") { store.select(session) }
        }
    }
}

private struct ServerChip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var showing = false
    @State private var hovering = false
    @State private var logs = ""

    var body: some View {
        Button {
            logs = session.surface.readText(lastLines: 80)
            showing.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Palette.status(session.state)).frame(width: 5, height: 5)
                Text(session.label).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                ForEach(session.ports.prefix(2), id: \.self) { port in
                    Text(":" + String(port))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.running)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Ink.faint))
            }
            .foregroundStyle(Color(nsColor: Ink.text))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(showing || hovering ? Color(nsColor: Ink.raised) : Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(showing ? Palette.accent.opacity(0.4) : Color(nsColor: Ink.hairline)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("View @\(session.label) logs and service actions")
        .accessibilityLabel("Service \(session.label), \(session.statusWord)")
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.running)
                    .frame(width: 35, height: 35)
                    .background(Palette.running.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.label).font(.system(size: 15, weight: .semibold))
                    Text(shortPath(session.spec.cwd))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(nsColor: Ink.muted))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Palette.status(session.state)).frame(width: 5, height: 5)
                    Text(session.statusWord).font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Color(nsColor: Ink.muted))
            }
            VStack(spacing: 0) {
                HStack {
                    Text("RECENT OUTPUT").font(.system(size: 9, weight: .semibold)).tracking(1)
                    Spacer()
                    Button { logs = session.surface.readText(lastLines: 80) } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(ChromeButtonStyle())
                    .help("Refresh service output")
                }
                .foregroundStyle(Color(nsColor: Ink.muted))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: Ink.surface))
                Color(nsColor: Ink.hairline).frame(height: 1)
                ScrollView {
                    Text(logs.isEmpty ? "No output yet. Your service logs will appear here." : logs)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(height: 250)
                .background(Color(nsColor: Theme.terminalBackground))
                .foregroundStyle(Color(nsColor: Theme.terminalForeground))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Ink.hairline)))
            HStack(spacing: 8) {
                Button { session.restart(); showing = false } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(ChromeButtonStyle())
                if let port = session.ports.first {
                    Button("Open Browser") { open(port) }
                        .padding(.horizontal, 5)
                        .buttonStyle(ChromeButtonStyle())
                    Button("Preview") { PreviewWindowController.show(port: port) }
                        .padding(.horizontal, 5)
                        .buttonStyle(ChromeButtonStyle())
                }
                Spacer()
                Button {
                    session.pinnedToGrid = true
                    showing = false
                    store.select(session)
                } label: {
                    Label("Show as Tile", systemImage: "rectangle.grid.1x2")
                        .padding(.horizontal, 9).padding(.vertical, 7)
                }
                .buttonStyle(ChromeButtonStyle(accent: true))
                .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(16)
        .frame(width: 550)
        .foregroundStyle(Color(nsColor: Ink.text))
        .background(Color(nsColor: Ink.deep))
    }

    private func open(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }
}

/// Toolbar center: the next request waiting on you, answerable in place.
struct AttentionQueue: View {
    @ObservedObject var store: SessionStore

    private var waiting: [TerminalSession] {
        store.sessions.filter { $0.state.needsAttention }.sorted { $0.stateChangedAt < $1.stateChangedAt }
    }

    var body: some View {
        if let next = waiting.first {
            QueueItem(session: next, store: store, count: waiting.count)
        } else if !store.sessions.isEmpty {
            let working = store.sessions.filter { $0.state == .working || $0.state == .starting }.count
            HStack(spacing: 7) {
                Image(systemName: working > 0 ? "waveform.path" : "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(working > 0 ? Palette.accent : Palette.running)
                Text(working > 0 ? "\(working) working" : "All clear")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(nsColor: Ink.muted))
            }
            .padding(.horizontal, 12)
            .frame(height: 29)
            .background(Color(nsColor: Ink.surface), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: Ink.hairline)))
            .help(working > 0 ? "\(working) sessions are working. No requests need your attention." : "No sessions need your attention")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

private struct QueueItem: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let count: Int

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(Palette.attention).frame(width: 6, height: 6)
            Button { store.select(session) } label: {
                HStack(spacing: 6) {
                    Text(session.label).fontWeight(.semibold).lineLimit(1)
                    if let request = session.pendingRequest {
                        Text(request)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(nsColor: Ink.muted))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("needs you").foregroundStyle(Color(nsColor: Ink.muted)).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Go to \(session.label) (⌘J)")
            if count > 1 {
                Text("+\(count - 1)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.attention)
            }
            Button { _ = store.answer(session, .approve) } label: {
                Text("Allow")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Ink.floor))
                    .padding(.horizontal, 10)
                    .frame(height: 23)
                    .background(Capsule().fill(Palette.attention))
            }
            .buttonStyle(.plain)
            .help("Allow (⌥⌘Y)")
            Button { _ = store.answer(session, .deny) } label: {
                Text("Deny")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(nsColor: Ink.muted))
                    .padding(.horizontal, 7)
                    .frame(height: 23)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Deny (⌥⌘N)")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color(nsColor: Ink.text))
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(height: 31)
        .background(Capsule().fill(Palette.attention.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Palette.attention.opacity(0.3)))
        .frame(maxWidth: 540)
    }
}
