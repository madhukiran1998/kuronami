import SwiftUI

/// Native macOS sidebar: translucent, sectioned by project, system selection highlight.
struct SidebarView: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    private var selection: Binding<UUID?> {
        Binding(
            get: { store.selectedID },
            set: { id in
                if let id, let session = store.sessions.first(where: { $0.id == id }) { store.select(session) }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            DispatchField(store: store, actions: actions)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
            List(selection: selection) {
                ForEach(store.projects, id: \.name) { project in
                    Section(project.name) {
                        ForEach(project.agents) { session in
                            AgentRow(session: session, store: store, actions: actions)
                                .tag(session.id)
                                .contextMenu { SessionMenu(session: session, actions: actions) }
                        }
                    }
                }
                if !store.utilities.isEmpty {
                    Section("Servers & Shells") {
                        ForEach(store.utilities) { session in
                            UtilityRow(session: session)
                                .tag(session.id)
                                .contextMenu { SessionMenu(session: session, actions: actions) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if store.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No terminals", systemImage: "terminal")
                    } description: {
                        Text("Dispatch a task above, or press ⌘N.")
                    }
                }
            }
            SidebarFooter(store: store, actions: actions)
        }
    }
}

// MARK: - Dispatch

/// Type a task, press Return: a new agent starts on it in its own worktree.
private struct DispatchField: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions
    @State private var text = ""
    @State private var kind: SessionKind = .claude
    @State private var folder: String?
    @FocusState private var focused: Bool

    private var targetFolder: String {
        folder ?? store.selected?.git?.root ?? store.selected?.spec.cwd ?? NSHomeDirectory()
    }

    private var folders: [String] {
        let roots = store.sessions.map { $0.git.map { GitInfo.mainRoot($0) } ?? $0.spec.cwd }
        return Array(NSOrderedSet(array: roots).array as? [String] ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(kind.tint)
                    .font(.system(size: 12, weight: .semibold))
                TextField("Ask a new agent…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(submit)
                Menu {
                    Picker("Agent", selection: $kind) {
                        Label("Claude Code", systemImage: SessionKind.claude.symbol).tag(SessionKind.claude)
                        Label("Codex", systemImage: SessionKind.codex.symbol).tag(SessionKind.codex)
                    }
                    .pickerStyle(.inline)
                    Section("Folder") {
                        ForEach(folders, id: \.self) { dir in
                            Button(abbreviateHome(dir)) { folder = dir }
                        }
                        Button("Choose…") { chooseFolder() }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Agent and folder")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
            if focused || !text.isEmpty {
                Text("\(kind.displayName) · \(shortPath(targetFolder)) · own worktree · ⏎ to start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    private func submit() {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        actions.dispatch(task, kind, targetFolder)
        text = ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

// MARK: - Rows

struct AgentRow: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let actions: SessionActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusDot(state: session.state, size: 7)
                    Text(session.label)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Image(systemName: session.kind.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(session.kind.tint)
                    if session.unread { Circle().fill(Palette.working).frame(width: 6, height: 6) }
                    Spacer(minLength: 4)
                    trailing(now: context.date)
                }
                if session.state.needsAttention {
                    ApprovalStrip(session: session, store: store)
                } else {
                    detailLines
                }
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder private func trailing(now: Date) -> some View {
        if session.readyForReview, let stat = session.diffStat {
            Button { actions.review(session) } label: {
                Text("+\(stat.added) −\(stat.removed)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.running.opacity(0.18)))
                    .foregroundStyle(Palette.running)
            }
            .buttonStyle(.plain)
            .help("Ready for review: open the changes")
        } else {
            Text(stateText(now: now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(session.state.needsAttention ? Palette.attention : .secondary)
        }
    }

    @ViewBuilder private var detailLines: some View {
        if let headline {
            Text(headline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if session.state == .working, let activity = session.activity {
            Label(activity, systemImage: "arrow.right")
                .labelStyle(.titleAndIcon)
                .font(.caption.monospaced())
                .foregroundStyle(Palette.working)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        let progress = session.tasks
        if progress.total > 0 && progress.done < progress.total {
            HStack(spacing: 6) {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .frame(width: 54)
                    .controlSize(.mini)
                Text("\(progress.done)/\(progress.total)\(progress.current.map { " · " + $0 } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        HStack(spacing: 8) {
            if let branch = session.spec.worktreeBranch ?? (session.git?.isWorktree == true ? session.git?.branch : nil) {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
            }
            if let evidence = session.testEvidence {
                Label(evidence.passed ? "tests pass" : "tests fail", systemImage: evidence.passed ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(evidence.passed ? Palette.running : Palette.failed)
                    .help(evidence.summary)
            }
            if let cost = session.usage.costUSD {
                Text(String(format: "$%.2f", cost)).monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .labelStyle(.titleAndIcon)
    }

    private var headline: String? {
        switch session.state {
        case .failed(let reason): return reason
        case .exited: return "Agent exited · shell open"
        default: return session.agentStatus ?? session.summary
        }
    }

    private func stateText(now: Date) -> String {
        let time = elapsed(since: session.stateChangedAt, now: now)
        switch session.state {
        case .working: return time
        case .needsInput: return "waiting \(time)"
        case .idle: return session.summary == nil ? "ready" : "done"
        case .starting: return "…"
        case .failed: return "failed"
        case .exited: return "exited"
        case .running: return ""
        }
    }
}

/// The request an agent is blocked on, with the answers right there.
private struct ApprovalStrip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.pendingRequest ?? session.state.detail ?? "Waiting for you")
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(3)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.attention.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                Button("Allow") { answer(.approve) }
                    .keyboardShortcut(.defaultAction)
                Button("Always") { answer(.always) }
                    .help(store.alwaysRuleText(for: session).map { "Always allow \($0)" } ?? "Allow and don't ask again for this")
                Button("Deny") { answer(.deny) }
            }
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func answer(_ choice: PromptAnswer) {
        switch store.answer(session, choice) {
        case .success: error = nil
        case .failure(let failure):
            error = failure.description
            store.select(session)
        }
    }
}

private struct UtilityRow: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: session.state, size: 7)
            Image(systemName: session.kind.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(session.label)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 4)
            PortChips(ports: session.ports, compact: true)
        }
        .help(session.foregroundProcess ?? session.spec.command ?? abbreviateHome(session.spec.cwd))
    }
}

// MARK: - Footer

private struct SidebarFooter: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    var body: some View {
        VStack(spacing: 6) {
            if let limits = store.rateLimits {
                UsageMeter(limits: limits)
            }
            HStack {
                Button { actions.newSession() } label: {
                    Label("New Terminal", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Account usage windows shared by every agent: the thing that actually caps parallelism.
struct UsageMeter: View {
    let limits: RateLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("5-hour", limits.fiveHourPercent, limits.fiveHourResets)
            row("Weekly", limits.sevenDayPercent, limits.sevenDayResets)
        }
    }

    @ViewBuilder private func row(_ title: String, _ percent: Double?, _ reset: Date?) -> some View {
        if let percent {
            HStack(spacing: 8) {
                Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                ProgressView(value: min(percent, 100), total: 100)
                    .progressViewStyle(.linear)
                    .tint(percent > 85 ? Palette.failed : percent > 65 ? Palette.attention : Color.accentColor)
                    .controlSize(.small)
                Text("\(Int(percent))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
            .help(reset.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        }
    }
}

// MARK: - Shared pieces

struct StatusDot: View {
    let state: AgentState
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Palette.status(state))
            .frame(width: size, height: size)
            .overlay {
                if state.needsAttention {
                    Circle().stroke(Palette.attention.opacity(0.45), lineWidth: 2).frame(width: size + 5, height: size + 5)
                }
            }
            .opacity(state == .working && pulse ? 0.35 : 1)
            .onAppear { updatePulse() }
            .onChange(of: state) { updatePulse() }
            .accessibilityLabel(state.phrase)
    }

    private func updatePulse() {
        guard state == .working else { pulse = false; return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }
}

struct PortChips: View {
    let ports: [Int]
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ports.prefix(compact ? 2 : 4), id: \.self) { port in
                Button {
                    if let url = URL(string: "http://localhost:" + String(port)) { NSWorkspace.shared.open(url) }
                } label: {
                    Text(":" + String(port))
                        .font(.caption.monospaced().weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.running.opacity(0.15)))
                        .foregroundStyle(Palette.running)
                }
                .buttonStyle(.plain)
                .help("Open http://localhost:" + String(port))
                .contextMenu {
                    Button("Open in Browser") {
                        if let url = URL(string: "http://localhost:" + String(port)) { NSWorkspace.shared.open(url) }
                    }
                    Button("Open in Hyperterm") {
                        NSApp.sendAction(#selector(AppDelegate.openPreview(_:)), to: nil, from: PortSender(port: port))
                    }
                }
            }
        }
    }
}

final class PortSender: NSObject {
    let port: Int
    init(port: Int) { self.port = port }
}

struct SessionMenu: View {
    let session: TerminalSession
    let actions: SessionActions

    var body: some View {
        if session.kind.isAgent {
            Button("Review Changes") { actions.review(session) }
        }
        Button("Rename…") { actions.rename(session) }
        if session.kind.isAgent && !session.spec.agentMayRename {
            Button("Let Agent Name It") { actions.releaseLabel(session) }
        }
        Button("Restart") { actions.restart(session) }
        if session.kind == .claude {
            Button("Continue on Phone…") { session.openRemoteControl() }
        }
        Divider()
        Button("Copy Label") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("@" + session.label, forType: .string)
        }
        Button("Reveal Folder in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.spec.workPath)])
        }
        Divider()
        Button("Close", role: .destructive) { actions.close(session) }
    }
}

/// Window-level actions the views can trigger.
@MainActor
struct SessionActions {
    var newSession: () -> Void
    var rename: (TerminalSession) -> Void
    var releaseLabel: (TerminalSession) -> Void
    var restart: (TerminalSession) -> Void
    var close: (TerminalSession) -> Void
    var review: (TerminalSession) -> Void
    var dispatch: (String, SessionKind, String) -> Void
}

/// Wraps children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
