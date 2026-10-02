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
            .scrollContentBackground(.hidden)
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
        // Vibrancy comes from the split view's sidebar material.
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
                TextField("New agent in \(URL(fileURLWithPath: targetFolder).lastPathComponent)…", text: $text, axis: .vertical)
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
            HStack(alignment: .top, spacing: 10) {
                AgentAvatar(kind: session.kind, state: session.state)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        trailing(now: context.date)
                    }
                    if session.state.needsAttention {
                        ApprovalStrip(session: session, store: store)
                    } else {
                        detailLines
                    }
                }
            }
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder private func trailing(now: Date) -> some View {
        if session.readyForReview, let stat = session.diffStat, stat.files > 0 {
            Button { actions.review(session) } label: {
                Text("\(stat.files) changed")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.running.opacity(0.2)))
                    .foregroundStyle(Palette.running)
            }
            .buttonStyle(.plain)
            .help("Review the changes (⌥⌘R)")
        } else {
            Text(elapsedLabel(now: now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func elapsedLabel(now: Date) -> String {
        switch session.state {
        case .working, .needsInput, .idle: return elapsed(since: session.stateChangedAt, now: now)
        default: return session.statusWord
        }
    }

    @ViewBuilder private var detailLines: some View {
        if let headline {
            Text(headline)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        if session.state == .working, let activity = session.activity {
            Text(activity)
                .font(.system(size: 11, design: .monospaced))
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
        let meta = metaItems
        if !meta.isEmpty {
            HStack(spacing: 9) {
                ForEach(meta, id: \.text) { item in
                    Label(item.text, systemImage: item.symbol)
                        .font(item.mono ? .system(size: 10.5, design: .monospaced) : .caption)
                        .foregroundStyle(item.color ?? Color.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .labelStyle(CompactLabelStyle())
        }
    }

    private struct MetaItem {
        let text: String
        let symbol: String
        let color: Color?
        var mono = false
    }

    private var metaItems: [MetaItem] {
        var items: [MetaItem] = []
        if let branch = session.spec.worktreeBranch ?? (session.git?.isWorktree == true ? session.git?.branch : nil) {
            items.append(MetaItem(text: branch, symbol: "arrow.triangle.branch", color: nil, mono: true))
        }
        if let evidence = session.testEvidence {
            items.append(MetaItem(text: evidence.passed ? "Tests pass" : "Tests fail", symbol: evidence.passed ? "checkmark.circle.fill" : "xmark.circle.fill",
                                  color: evidence.passed ? Palette.running : Palette.failed))
        }
        if let cost = session.usage.costUSD, cost > 0 {
            items.append(MetaItem(text: String(format: "$%.2f", cost), symbol: "dollarsign.circle", color: nil))
        }
        return items
    }

    private var headline: String? {
        switch session.state {
        case .failed(let reason): return reason
        case .exited: return "Agent exited · shell open"
        case .starting: return "Starting…"
        default:
            if let text = session.agentStatus ?? session.summary { return text }
            return session.state == .idle ? "Ready for a task" : nil
        }
    }
}

/// The agent's mark, carrying its status: orange when it needs you, a spinning arc while it
/// works, muted when idle. This is the one place the sidebar shows state.
struct AgentAvatar: View {
    let kind: SessionKind
    let state: AgentState
    @State private var spin = false

    private var tint: Color {
        switch state {
        case .needsInput: return Palette.attention
        case .failed: return Palette.failed
        case .exited: return .secondary
        default: return kind.tint
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(state.needsAttention ? AnyShapeStyle(Palette.attention.gradient) : AnyShapeStyle(tint.gradient.opacity(state == .idle || state == .exited(0) ? 0.14 : 0.24)))
                .frame(width: 26, height: 26)
            Image(systemName: state.needsAttention ? "hand.raised.fill" : kind.symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(state.needsAttention ? Color.white : tint.opacity(state == .idle ? 0.75 : 1))
            if state == .working {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .trim(from: 0, to: 0.3)
                    .stroke(Palette.working, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 31, height: 31)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spin = true } }
            }
        }
        .frame(width: 31, height: 31)
        .accessibilityLabel(state.phrase)
    }
}

/// Icon tight against its title, as in Finder's status bars.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The request an agent is blocked on, with the answers right there. Allow is the primary
/// action; "Always" lives in its menu and says what it would allow.
private struct ApprovalStrip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let request = session.pendingRequest {
                Text(request)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(request)
            } else {
                Text(session.state.detail ?? "Waiting for you").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button { answer(.approve) } label: { Text("Allow").frame(minWidth: 44) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.attention)
                    .help("Allow once (⌥⌘Y)")
                Button { answer(.deny) } label: { Text("Deny").frame(minWidth: 36) }
                    .buttonStyle(.bordered)
                    .help("Deny (⌥⌘N)")
                Spacer(minLength: 0)
                Menu {
                    Button(store.alwaysRuleText(for: session).map { "Always Allow \($0)" } ?? "Always Allow (Claude's suggested scope)") { answer(.always) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options")
            }
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        HStack(spacing: 8) {
            Image(systemName: session.kind.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(session.label)
                .font(.system(size: 13))
                .lineLimit(1)
            StatusDot(state: session.state, size: 6)
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
        HStack(spacing: 10) {
            if let limits = store.rateLimits {
                UsageMeter(limits: limits)
            }
            Spacer(minLength: 0)
            Menu {
                Button("New Terminal…") { actions.newSession() }
                Divider()
                ForEach(SessionKind.allCases) { kind in
                    Button { NSApp.sendAction(#selector(AppDelegate.newSessionOfKind(_:)), to: nil, from: KindSender(kind: kind)) } label: {
                        Label("New \(kind.displayName)", systemImage: kind.symbol)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New terminal")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// Account usage windows shared by every agent: the thing that actually caps parallelism.
struct UsageMeter: View {
    let limits: RateLimits

    var body: some View {
        HStack(spacing: 12) {
            gauge("5h", limits.fiveHourPercent, limits.fiveHourResets)
            gauge("Week", limits.sevenDayPercent, limits.sevenDayResets)
        }
    }

    @ViewBuilder private func gauge(_ title: String, _ percent: Double?, _ reset: Date?) -> some View {
        if let percent {
            HStack(spacing: 5) {
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Capsule().fill(.quaternary)
                    .frame(width: 44, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(percent > 80 ? Palette.attention : Color.secondary)
                            .frame(width: 44 * min(percent, 100) / 100, height: 4)
                    }
                Text("\(Int(percent))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .help("\(title == "5h" ? "5-hour" : "Weekly") usage · " + (reset.map { "resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
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
