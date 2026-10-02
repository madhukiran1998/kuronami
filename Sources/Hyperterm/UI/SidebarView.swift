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
            HStack(alignment: .top, spacing: 10) {
                AgentAvatar(kind: session.kind, state: session.state)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.label)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .layoutPriority(1)
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
            }
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder private func trailing(now: Date) -> some View {
        if session.readyForReview, let stat = session.diffStat {
            Button { actions.review(session) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "eye").font(.system(size: 8.5, weight: .bold))
                    Text(stat.added + stat.removed == 0 ? "\(stat.files) file\(stat.files == 1 ? "" : "s")" : "+\(stat.added) −\(stat.removed)")
                }
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Palette.running.opacity(0.2)))
                .foregroundStyle(Palette.running)
            }
            .buttonStyle(.plain)
            .help("Ready for review: open the changes (⌥⌘R)")
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
                .fixedSize(horizontal: false, vertical: true)
        }
        if session.state == .working, let activity = session.activity {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                Text(activity).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption.monospaced())
            .foregroundStyle(Palette.working)
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
                        .foregroundStyle(item.color ?? Color.secondary.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .labelStyle(CompactLabelStyle())
        }
    }

    private struct MetaItem {
        let text: String
        let symbol: String
        let color: Color?
    }

    private var metaItems: [MetaItem] {
        var items: [MetaItem] = []
        if let branch = session.spec.worktreeBranch ?? (session.git?.isWorktree == true ? session.git?.branch : nil) {
            items.append(MetaItem(text: branch, symbol: "arrow.triangle.branch", color: nil))
        }
        if let evidence = session.testEvidence {
            items.append(MetaItem(text: evidence.passed ? "passing" : "failing", symbol: evidence.passed ? "checkmark.circle.fill" : "xmark.circle.fill",
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
        default: return session.agentStatus ?? session.summary
        }
    }

    private func stateText(now: Date) -> String {
        let time = elapsed(since: session.stateChangedAt, now: now)
        switch session.state {
        case .working: return time
        case .needsInput: return "waiting \(time)"
        case .idle: return session.summary == nil ? "ready" : "done"
        case .starting: return "starting"
        case .failed: return "failed"
        case .exited: return "exited"
        case .running: return ""
        }
    }
}

/// The agent's mark in a tinted tile, with its state as a badge.
struct AgentAvatar: View {
    let kind: SessionKind
    let state: AgentState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(kind.tint.gradient.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(kind.tint.opacity(0.25), lineWidth: 0.5))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: kind.symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(kind.tint))
            StatusDot(state: state, size: 8)
                .padding(2)
                .background(Circle().fill(.background))
                .offset(x: 4, y: 4)
        }
        .padding(.top, 1)
        .padding(.trailing, 2)
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

/// The request an agent is blocked on, with the answers right there.
private struct ApprovalStrip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(session.hasHookApproval || session.pendingRequest != nil ? "Wants to run" : (session.state.detail ?? "Waiting for you"),
                  systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.attention)
            if let request = session.pendingRequest {
                Text(request)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            HStack(spacing: 6) {
                Button { answer(.approve) } label: { Text("Allow").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.attention)
                Button { answer(.always) } label: { Text("Always").frame(maxWidth: .infinity) }
                    .help(store.alwaysRuleText(for: session).map { "Always allow \($0)" } ?? "Allow and don't ask again for this")
                Button { answer(.deny) } label: { Text("Deny").frame(maxWidth: .infinity) }
            }
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Palette.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.attention.opacity(0.35), lineWidth: 0.5))
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
