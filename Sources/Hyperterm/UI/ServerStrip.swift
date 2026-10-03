import SwiftUI

/// The shelf under the canvas: servers (a chip with their ports; click for logs and actions,
/// "Show as Tile" pins one into the grid) and minimized tiles (click to bring back).
struct ServerStrip: View {
    @ObservedObject var store: SessionStore

    private var servers: [TerminalSession] {
        store.sessions.filter { $0.kind == .server && !$0.pinnedToGrid && !$0.isMinimized }
    }
    private var shelved: [TerminalSession] { store.sessions.filter(\.isMinimized) }

    var body: some View {
        HStack(spacing: 8) {
            if !servers.isEmpty {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ForEach(servers) { server in
                    ServerChip(session: server, store: store)
                }
            }
            if !servers.isEmpty && !shelved.isEmpty {
                Divider().frame(height: 14).padding(.horizontal, 2)
            }
            ForEach(shelved) { session in
                ShelvedChip(session: session, store: store)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A minimized tile waiting on the shelf.
private struct ShelvedChip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var hovering = false

    var body: some View {
        Button { store.select(session) } label: {
            HStack(spacing: 5) {
                KindMark(kind: session.kind, size: 10.5)
                    .foregroundStyle(session.kind.tint)
                Text(session.label).font(.system(size: 11.5, weight: .medium))
                Circle().fill(Palette.status(session.state)).frame(width: 5, height: 5)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary.opacity(hovering ? 1 : 0.6)))
            .overlay(Capsule().strokeBorder(session.state.needsAttention ? Palette.attention.opacity(0.7) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Bring @\(session.label) back")
        .contextMenu {
            Button("Restore") { store.select(session) }
        }
    }
}

private struct ServerChip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var showing = false
    @State private var logs = ""

    var body: some View {
        Button {
            logs = session.surface.readText(lastLines: 30)
            showing.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Palette.status(session.state)).frame(width: 6, height: 6)
                Text(session.label).font(.system(size: 11.5, weight: .medium))
                ForEach(session.ports.prefix(2), id: \.self) { port in
                    Text(":" + String(port)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.running)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary.opacity(showing ? 1 : 0.6)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(session.label).font(.headline)
                    Text(session.statusWord).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                ScrollView {
                    Text(logs.isEmpty ? "No output yet." : logs)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(width: 520, height: 260)
                .padding(8)
                .background(Color(nsColor: Theme.terminalBackground), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color(nsColor: Theme.terminalForeground))
                HStack {
                    Button("Restart") { session.restart(); showing = false }
                    if let port = session.ports.first {
                        Button("Open in Browser") {
                            if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                        }
                        Button("Preview") { PreviewWindowController.show(port: port) }
                    }
                    Spacer()
                    Button("Show as Tile") {
                        session.pinnedToGrid = true
                        showing = false
                        store.select(session)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
        .contextMenu {
            Button("Show as Tile") { session.pinnedToGrid = true; store.select(session) }
            Button("Restart") { session.restart() }
        }
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
            Circle().fill(Palette.attention).frame(width: 7, height: 7)
            Button { store.select(session) } label: {
                HStack(spacing: 6) {
                    Text(session.label).fontWeight(.semibold)
                    if let request = session.pendingRequest {
                        Text("wants to run").foregroundStyle(.secondary)
                        Text(request)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("needs you").foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Go to \(session.label) (⇧⌘U)")
            if count > 1 {
                Text("+\(count - 1)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Button { _ = store.answer(session, .approve) } label: {
                Text("Allow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Ink.floor))
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Capsule().fill(Palette.attention))
            }
            .buttonStyle(.plain)
            .help("Allow (⌥⌘Y)")
            Button { _ = store.answer(session, .deny) } label: {
                Text("Deny")
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Deny (⌥⌘N)")
        }
        .font(.system(size: 12.5))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(Capsule().fill(Palette.attention.opacity(0.1)))
        .overlay(Capsule().strokeBorder(Palette.attention.opacity(0.45), lineWidth: 1))
        .frame(maxWidth: 620)
    }
}
