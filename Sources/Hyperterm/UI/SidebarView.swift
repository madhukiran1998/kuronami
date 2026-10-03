import SwiftUI

/// Stable project groups, explicit selection, and a composer that stays within reach.
struct SidebarView: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            WorkspacePulse(store: store, actions: actions)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            DispatchField(store: store, actions: actions)
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            Rectangle().fill(Color(nsColor: Ink.hairline).opacity(0.6)).frame(height: 1)
                .padding(.horizontal, 14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.projects, id: \.name) { project in
                            sectionHeader(project.name, count: project.agents.count, symbol: "folder")
                            ForEach(project.agents) { session in
                                AgentRow(session: session, store: store, actions: actions)
                                    .id(session.id)
                                    .contentShape(RoundedRectangle(cornerRadius: 10))
                                    .onTapGesture { store.select(session) }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { store.select(session) }
                                    .contextMenu { SessionMenu(session: session, actions: actions) }
                                ForEach(store.browsers(ownedBy: session)) { browser in
                                    browserRow(browser, nested: true)
                                }
                            }
                        }
                        if !store.looseBrowsers.isEmpty {
                            sectionHeader("Browsers", count: store.looseBrowsers.count, symbol: "globe")
                            ForEach(store.looseBrowsers) { browser in browserRow(browser, nested: false) }
                        }
                        if !store.utilities.isEmpty {
                            sectionHeader("Servers & shells", count: store.utilities.count, symbol: "terminal")
                            ForEach(store.utilities) { session in
                                UtilityRow(session: session)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .background(selectionFill(session), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.select(session) }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { store.select(session) }
                                    .contextMenu { SessionMenu(session: session, actions: actions) }
                                    .id(session.id)
                            }
                        }
                        if store.sessions.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("A place for every agent.")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color(nsColor: Ink.muted))
                                Text("Your agents, browsers, and servers\nwill appear here, grouped by project.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(nsColor: Ink.faint))
                                    .lineSpacing(3)
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 22)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id) }
                }
            }
            SidebarFooter(store: store, actions: actions)
        }
        .background(Color(nsColor: Ink.deep).ignoresSafeArea())
        .foregroundStyle(Color(nsColor: Ink.text))
        .tint(Palette.accent)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            WaveMark().frame(width: 30, height: 30)
                .padding(5)
                .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color(nsColor: Ink.hairline)))
            VStack(alignment: .leading, spacing: 2) {
                Text("KURONAMI")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(Color(nsColor: Ink.muted))
                Text("Workspace").font(.system(size: 20, weight: .semibold)).tracking(-0.6)
            }
            Spacer(minLength: 0)
            Button { NSApp.sendAction(#selector(AppDelegate.showSwitcher(_:)), to: nil, from: nil) } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: Ink.muted))
                    .frame(width: 28, height: 30)
            }
            .buttonStyle(.plain)
            .help("Search sessions and commands (⌘P)")
            .accessibilityLabel("Search sessions and commands")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }

    private func sectionHeader(_ title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).lineLimit(1)
            Spacer(minLength: 4)
            Text(String(count)).font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(Color(nsColor: Ink.faint))
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private func selectionFill(_ session: TerminalSession) -> Color {
        Color(nsColor: store.selectedID == session.id ? Ink.raised : Ink.deep)
    }

    private func browserRow(_ browser: TerminalSession, nested: Bool) -> some View {
        BrowserRow(session: browser, nested: nested)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selectionFill(browser), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { store.select(browser) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.select(browser) }
            .contextMenu { SessionMenu(session: browser, actions: actions) }
            .id(browser.id)
    }
}

private struct WorkspacePulse: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    var body: some View {
        HStack(spacing: 0) {
            metric("Working", value: store.sessions.filter { $0.state == .working }.count, color: Palette.working) {
                if let session = store.sessions.first(where: { $0.state == .working }) { store.select(session) }
            }
            separator
            metric("Needs you", value: store.attentionCount, color: Palette.attention) { store.selectNextNeedingAttention() }
            separator
            metric("To review", value: store.reviewCount, color: Palette.running) {
                if let session = store.sessions.first(where: \.readyForReview) { actions.review(session) }
            }
        }
        .padding(.vertical, 10)
        .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Ink.hairline).opacity(0.65)))
    }

    private var separator: some View {
        Rectangle().fill(Color(nsColor: Ink.hairline)).frame(width: 1, height: 24)
    }

    private func metric(_ title: String, value: Int, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(value > 0 ? color : Color(nsColor: Ink.faint)).frame(width: 4, height: 4)
                    Text(String(value)).font(.system(size: 18, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(value > 0 ? Color(nsColor: Ink.text) : Color(nsColor: Ink.faint))
                }
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Color(nsColor: Ink.muted))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value == 0)
        .help("Go to \(title.lowercased())")
        .accessibilityLabel("\(value) \(title.lowercased())")
    }
}

// MARK: - Dispatch

/// Type a task, press Return: a new agent starts in the chosen project.
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.launchingCount > 0 ? "LAUNCHING \(store.launchingCount) SESSION\(store.launchingCount == 1 ? "" : "S")…" : "LAUNCH AN AGENT")
                    .font(.system(size: 9, weight: .semibold)).tracking(1)
                    .foregroundStyle(Color(nsColor: Ink.faint))
                Spacer()
                if store.launchingCount > 0 {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Color(nsColor: Ink.faint))
                }
            }
            TextField("What are we building?", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...4)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("Task for a new agent")
            HStack(spacing: 7) {
                Menu {
                    Picker("Agent", selection: $kind) {
                        Label("Claude Code", systemImage: SessionKind.claude.symbol).tag(SessionKind.claude)
                        Label("Codex", systemImage: SessionKind.codex.symbol).tag(SessionKind.codex)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(kind == .claude ? "Claude" : "Codex")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(kind.tint)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Choose agent")
                Menu {
                    ForEach(folders, id: \.self) { dir in Button(abbreviateHome(dir)) { folder = dir } }
                    if !folders.isEmpty { Divider() }
                    Button("Choose Folder…") { chooseFolder() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text(URL(fileURLWithPath: targetFolder).lastPathComponent).font(.system(size: 10))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(Color(nsColor: Ink.muted))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("Project: " + abbreviateHome(targetFolder))
                Spacer(minLength: 0)
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color(nsColor: Ink.faint) : Color(nsColor: Ink.floor))
                        .frame(width: 25, height: 25)
                        .background(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color(nsColor: Ink.raised) : Palette.accent,
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Launch agent (Return)")
                .accessibilityLabel("Launch agent")
            }
        }
        .padding(12)
        .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(focused ? Palette.accent.opacity(0.7) : Color(nsColor: Ink.hairline)))
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
        panel.directoryURL = URL(fileURLWithPath: expandTilde(targetFolder))
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

// MARK: - Rows

struct AgentRow: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let actions: SessionActions
    @State private var hovering = false

    private var selected: Bool { store.selectedID == session.id }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            AgentAvatar(kind: session.kind, state: session.state)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Ink.text))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    if session.unread {
                        Circle().fill(Palette.accent).frame(width: 5, height: 5)
                            .accessibilityLabel("Unread activity")
                    }
                }
                HStack(spacing: 4) {
                    trailing
                    Spacer(minLength: 0)
                    if session.isMinimized {
                        Image(systemName: "minus.square").font(.system(size: 10))
                            .foregroundStyle(Color(nsColor: Ink.faint))
                    }
                }
                if session.state.needsAttention {
                    ApprovalStrip(session: session, store: store)
                } else {
                    detailLines
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: selected ? Ink.raised : hovering ? Ink.surface : Ink.deep),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(session.state.needsAttention ? Palette.attention.opacity(0.4)
                          : selected ? Palette.accent.opacity(0.35) : Color.clear))
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(Palette.accent).frame(width: 2, height: 20).padding(.leading, 1)
            }
        }
        .opacity(session.isMinimized ? 0.65 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(session.label), \(session.statusWord)")
        .accessibilityValue(selected ? "Selected" : "")
    }

    @ViewBuilder private var trailing: some View {
        if session.readyForReview, let stat = session.diffStat, stat.files > 0 {
            Button { actions.review(session) } label: {
                Label("Review \(stat.files) file\(stat.files == 1 ? "" : "s")", systemImage: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.running.opacity(0.2)))
                    .foregroundStyle(Palette.running)
            }
            .buttonStyle(.plain)
            .help("Review the changes (⌥⌘R)")
        } else {
            // Only the clock ticks; the rest of the row re-renders when the session changes.
            TimelineView(.periodic(from: .now, by: session.state == .working ? 15 : 60)) { context in
                Text(elapsedLabel(now: context.date))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(statusColor)
            }
        }
    }

    /// "Working · 4m", "Needs you", "Done · 12m": state in words, colored only when it matters.
    private func elapsedLabel(now: Date) -> String {
        let since = elapsed(since: session.stateChangedAt, now: now)
        switch session.state {
        case .working: return "Working · \(since)"
        case .needsInput: return "Needs you"
        case .idle: return "\(session.statusWord) · \(since)"
        default: return session.statusWord
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .working, .starting: return Palette.working
        case .needsInput: return Palette.attention
        case .failed: return Palette.failed
        default: return Color(nsColor: Ink.muted)
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

/// The agent's mark carries a static, legible state. Nothing animates while the app rests.
struct AgentAvatar: View {
    let kind: SessionKind
    let state: AgentState

    /// Color here means state; with no state worth flagging, the mark wears the agent's own tint.
    private var stateColor: Color? {
        switch state {
        case .working, .starting: return Palette.working
        case .needsInput: return Palette.attention
        case .failed: return Palette.failed
        default: return nil
        }
    }

    var body: some View {
        let needsYou = state.needsAttention
        KindMark(kind: kind, size: 12)
            .foregroundStyle(needsYou ? Color(nsColor: Ink.floor) : (stateColor ?? kind.tint.opacity(state == .exited(0) ? 0.45 : 0.9)))
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(needsYou ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(Color(nsColor: Ink.surface))))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(needsYou ? Color.clear : (stateColor?.opacity(0.6) ?? Color(nsColor: Ink.hairline)), lineWidth: 1))
            .frame(width: 30, height: 30)
            .accessibilityLabel(state.phrase)
    }
}

/// One glyph language everywhere: agents are monograms (C, X), everything else a plain symbol.
struct KindMark: View {
    let kind: SessionKind
    var size: CGFloat = 12

    var body: some View {
        if let letter = kind.monogram {
            Text(letter).font(.system(size: size, weight: .bold, design: .rounded))
        } else {
            Image(systemName: kind.symbol).font(.system(size: size - 1, weight: .medium))
        }
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
        .background(Palette.attention.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.attention.opacity(0.16)))
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
            KindMark(kind: session.kind, size: 12)
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
        .opacity(session.isMinimized ? 0.55 : 1)
    }
}

/// A browser: its page and, while an agent acts on it, who.
private struct BrowserRow: View {
    @ObservedObject var session: TerminalSession
    let nested: Bool

    private var activity: AgentBrowser.Activity? {
        AgentBrowser.shared.activity.flatMap { $0.browser == session.label ? $0 : nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(activity == nil ? Color.secondary : Palette.working)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(activity.map { "@\($0.agent) · \($0.action)" } ?? session.spec.url.map(abbreviateURL) ?? "New tab")
                    .font(.system(size: 11))
                    .foregroundStyle(activity == nil ? Color.secondary : Palette.working)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if activity != nil {
                Circle().fill(Palette.working).frame(width: 6, height: 6)
            }
        }
        .padding(.leading, nested ? 18 : 0)
        .padding(.vertical, 1)
        .help(session.summary ?? session.spec.url ?? session.label)
        .opacity(session.isMinimized ? 0.55 : 1)
    }
}

// MARK: - Footer

private struct SidebarFooter: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    var body: some View {
        VStack(spacing: 12) {
            Rectangle().fill(Color(nsColor: Ink.hairline).opacity(0.6)).frame(height: 1)
            if let limits = store.rateLimits {
                HStack {
                    UsageMeter(limits: limits)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                Button(action: actions.newSession) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        Text("New session").font(.system(size: 12, weight: .medium))
                        Spacer()
                        KeyboardHint(keys: "⌘N")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: Ink.hairline)))
                }
                .buttonStyle(.plain)
                .help("Configure a new terminal (⌘N)")
                Menu {
                    Button("New Terminal…") { actions.newSession() }
                    Divider()
                    ForEach(SessionKind.allCases) { kind in
                        Button { NSApp.sendAction(#selector(AppDelegate.newSessionOfKind(_:)), to: nil, from: KindSender(kind: kind)) } label: {
                            Label("New \(kind.displayName)", systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Quick launch")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
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
                            .frame(width: 44 * max(0, min(percent, 100)) / 100, height: 4)
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

    var body: some View {
        Circle()
            .fill(Palette.status(state))
            .frame(width: size, height: size)
            .overlay {
                if state.needsAttention {
                    Circle().stroke(Palette.attention.opacity(0.45), lineWidth: 2).frame(width: size + 5, height: size + 5)
                }
            }
            .accessibilityLabel(state.phrase)
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
                    Button("Open in Kuronami") {
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
        Button(session.isMinimized ? "Restore Tile" : "Minimize Tile") {
            session.store?.setMinimized(session, !session.isMinimized)
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
