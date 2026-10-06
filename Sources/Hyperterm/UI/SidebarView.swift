import SwiftUI

/// Agents grouped by project, in creation order so nothing moves under your hand. Each row says
/// one thing: what the agent is doing, or what it needs from you. Everything else lives in the
/// inspector.
struct SidebarView: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsClosed = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(store.projects, id: \.name) { project in
                            header(project.name, count: project.agents.count)
                            ForEach(project.agents) { session in
                                AgentRow(session: session, store: store, actions: actions)
                                    .id(session.id)
                                ForEach(store.browsers(ownedBy: session)) { browser in
                                    UtilityRow(session: browser, store: store, actions: actions, nested: true).id(browser.id)
                                }
                            }
                        }
                        if !store.looseBrowsers.isEmpty {
                            header("Browsers", count: store.looseBrowsers.count)
                            ForEach(store.looseBrowsers) { UtilityRow(session: $0, store: store, actions: actions).id($0.id) }
                        }
                        if !store.utilities.isEmpty {
                            header("Servers and shells", count: store.utilities.count)
                            ForEach(store.utilities) { UtilityRow(session: $0, store: store, actions: actions).id($0.id) }
                        }
                        if !store.recentlyClosed.isEmpty { recentlyClosed }
                        if store.sessions.isEmpty && store.recentlyClosed.isEmpty {
                            Text("Agents you start appear here, grouped by project.")
                                .font(Typeface.callout)
                                .foregroundStyle(Tone.faint)
                                .padding(.horizontal, Space.s)
                                .padding(.top, Space.l)
                        }
                    }
                    .padding(.horizontal, Space.s)
                    .padding(.bottom, Space.l)
                }
                .scrollIndicators(.never)
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.animation(reduceMotion)) { proxy.scrollTo(id) }
                }
            }
            SidebarFooter(store: store, actions: actions)
        }
        .background(Tone.pane.ignoresSafeArea())
        .foregroundStyle(Tone.text)
        .tint(Palette.accent)
    }

    private func header(_ title: String, count: Int) -> some View {
        SectionHeader(title) { Text(String(count)).monospacedDigit() }
            .padding(.horizontal, Space.s)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xs)
    }

    private var recentlyClosed: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Button {
                withAnimation(Motion.animation(reduceMotion, Motion.quick)) { showsClosed.toggle() }
            } label: {
                SectionHeader("Recently closed") {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showsClosed ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Space.s)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xs)
            if showsClosed {
                // The sidebar shows the latest few; the organizer can reach the rest.
                ForEach(store.recentlyClosed.prefix(15)) { spec in
                    ClosedRow(spec: spec) { store.reopen(spec) }
                }
                Button("Clear List") { store.forgetClosed() }
                    .buttonStyle(.plain)
                    .font(Typeface.caption)
                    .foregroundStyle(Tone.faint)
                    .padding(.horizontal, Space.s)
                    .padding(.top, Space.xs)
            }
        }
    }
}

// MARK: - Rows

/// The row behind a session: selection fill, hover, click, context menu.
private struct RowChrome: ViewModifier {
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.s - 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Tone.raised : hovering ? Tone.surface : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}

struct AgentRow: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let actions: SessionActions

    private var selected: Bool { store.selectedID == session.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                AgentAvatar(kind: session.kind, dimmed: isExited)
                Text(session.label)
                    .font(Typeface.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: Space.xs)
                if session.unread {
                    Circle().fill(Palette.accent).frame(width: 6, height: 6).accessibilityLabel("Unread")
                }
                StateLabel(session: session)
            }
            Group {
                if session.state.needsAttention {
                    ApprovalStrip(session: session, store: store, actions: actions)
                } else if let line = detailLine {
                    Text(line.text)
                        .font(line.mono ? Typeface.codeSmall : Typeface.callout)
                        .foregroundStyle(line.color)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if let reset = store.rateLimitReset(for: session), session.resumeAt == nil {
                    Button("Continue at \(reset.formatted(date: .omitted, time: .shortened))") { store.continueAtReset(session) }
                        .buttonStyle(PanelButtonStyle())
                        .help("Tell the agent to carry on once the usage limit resets")
                }
                badges
            }
            .padding(.leading, Size.avatar + Space.s)
        }
        .modifier(RowChrome(selected: selected) { store.select(session) })
        .contextMenu { SessionMenu(session: session, actions: actions) }
        .opacity(session.isMinimized ? 0.6 : 1)
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.label), \(session.statusWord)")
    }

    private var isExited: Bool {
        if case .exited = session.state { return true }
        return false
    }

    /// The one line under the name: what it's doing now, else what it last said.
    private var detailLine: (text: String, mono: Bool, color: Color)? {
        switch session.state {
        case .failed(let reason): return (reason, false, Palette.failed)
        case .exited: return ("Agent exited · shell open", false, Tone.faint)
        case .starting: return (session.isWaking ? "Waking…" : "Starting…", false, Tone.faint)
        case .working:
            if let activity = session.activity { return (activity, true, Tone.muted) }
        default: break
        }
        if let resume = session.resumeAt {
            return ("Continues at \(resume.formatted(date: .omitted, time: .shortened))", false, Tone.muted)
        }
        if let text = session.agentStatus ?? session.summary { return (text, false, Tone.muted) }
        guard session.state == .idle else { return nil }
        return ("Ready for a task", false, Tone.faint)
    }

    @ViewBuilder private var badges: some View {
        let queued = session.pendingMessages.count
        let stat: DiffStat? = session.diffStat
        let review: DiffStat? = session.readyForReview && (stat?.files ?? 0) > 0 ? stat : nil
        let racing = store.raceSiblings(of: session).count
        let overlap = session.overlapBadge
        if review != nil || queued > 0 || racing > 0 || overlap != nil {
            HStack(spacing: Space.xs) {
                if let overlap {
                    Tag(text: overlap.title, tint: Palette.attention).help(overlap.detail)
                }
                if racing > 0 {
                    Tag(text: "Racing \(racing + 1)", tint: Palette.accent)
                        .help("Started with \(racing) other agent\(racing == 1 ? "" : "s") on the same task. Right-click → Pick This One to keep its work.")
                }
                if let review {
                    Button { actions.review(session) } label: {
                        HStack(spacing: Space.xs) {
                            Text("Review")
                            DiffCount(added: review.added, removed: review.removed)
                        }
                        .font(Typeface.micro)
                        .padding(.horizontal, Space.xs + 1)
                        .padding(.vertical, 1)
                        .background(Palette.running.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .foregroundStyle(Palette.running)
                    }
                    .buttonStyle(.plain)
                    .help("Review \(review.files) changed file\(review.files == 1 ? "" : "s") (⌥⌘R)")
                }
                if queued > 0 { Tag(text: "\(queued) queued") }
            }
        }
    }

    private var tooltip: String {
        var lines = [session.kind.displayName + (session.spec.options?.summary.map { " · " + $0 } ?? "")]
        if let branch = session.git?.branch { lines.append("Branch: " + branch) }
        let tasks = session.tasks
        if tasks.total > 0 { lines.append("Tasks: \(tasks.done)/\(tasks.total)" + (tasks.current.map { " · " + $0 } ?? "")) }
        if let evidence = session.testEvidence { lines.append(evidence.passed ? "Tests pass" : "Tests fail") }
        if let cost = session.usage.costUSD, cost > 0 { lines.append(String(format: "Cost: $%.2f", cost)) }
        return lines.joined(separator: "\n")
    }
}

/// "Working 4m", "Needs you", "Done 12m": state in words, colored only when it matters.
struct StateLabel: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        // Only the clock ticks; the rest of the row re-renders when the session changes.
        TimelineView(.periodic(from: .now, by: session.state == .working ? 15 : 60)) { context in
            // Two Texts joined, so the symbol stays a symbol (interpolating it into a String prints
            // the Image's description).
            ((session.isAsleep ? Text(Image(systemName: "moon.zzz")) + Text(" ") : Text(verbatim: "")) + Text(text(now: context.date)))
            .font(Typeface.caption.weight(session.state.needsAttention ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
        }
    }

    private func text(now: Date) -> String {
        let since = elapsed(since: session.stateChangedAt, now: now)
        switch session.state {
        case .working: return "Working \(since)"
        case .needsInput: return "Needs you"
        case .idle: return "\(session.statusWord) · \(since)"
        default: return session.statusWord
        }
    }

    private var color: Color {
        switch session.state {
        case .working, .starting: return Palette.working
        case .needsInput: return Palette.attention
        case .failed: return Palette.failed
        default: return Tone.faint
        }
    }
}

/// What an agent is blocked on, with the answer right there. A plan in plan mode is shown as a
/// plan, with approving it as the primary action.
private struct ApprovalStrip: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let actions: SessionActions
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let plan = session.pendingPlan {
                Text(planTitle(plan))
                    .font(Typeface.callout)
                    .foregroundStyle(Tone.text)
                    .lineLimit(2)
            } else if let request = session.pendingRequest {
                Text(request)
                    .font(Typeface.codeSmall)
                    .foregroundStyle(Tone.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(request)
            } else {
                Text(session.state.detail ?? "Waiting for you").font(Typeface.callout).foregroundStyle(Tone.muted)
            }
            HStack(spacing: Space.xs) {
                Button(session.pendingPlan != nil ? "Approve Plan" : "Allow") { answer(.approve) }
                    .buttonStyle(PanelButtonStyle(prominent: true, tint: Palette.attention))
                    .help(session.pendingPlan != nil ? "Approve the plan and let the agent start (⌥⌘Y)" : "Allow once (⌥⌘Y)")
                Button(session.pendingPlan != nil ? "Keep Planning" : "Deny") { answer(.deny) }
                    .buttonStyle(PanelButtonStyle())
                    .help("⌥⌘N")
                Spacer(minLength: 0)
                Menu {
                    if session.pendingPlan != nil {
                        Button("Read the Plan") { actions.showPlan(session) }
                    } else {
                        Button(store.alwaysRuleText(for: session).map { "Always Allow \($0)" } ?? "Always Allow (Claude's Suggested Scope)") { answer(.always) }
                    }
                    Button("Show Terminal") { store.select(session) }
                } label: {
                    Image(systemName: "ellipsis").font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.muted)
                }
                .tint(Tone.muted)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            if let error {
                Text(error).font(Typeface.caption).foregroundStyle(Tone.muted)
            }
        }
    }

    private func planTitle(_ plan: String) -> String {
        let firstLine = plan.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let title = firstLine.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) } ?? "Plan"
        return "Plan ready: " + title
    }

    private func answer(_ choice: PromptAnswer) {
        let reason = choice == .deny && session.pendingPlan != nil ? "Keep planning; the user wants to refine the plan before you start." : nil
        switch store.answer(session, choice, reason: reason) {
        case .success: error = nil
        case .failure(let failure):
            error = failure.description
            store.select(session)
        }
    }
}

/// Browsers, servers and shells: one line each.
private struct UtilityRow: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let actions: SessionActions
    var nested = false

    private var driver: AgentBrowser.Activity? {
        AgentBrowser.shared.activity.flatMap { $0.browser == session.label ? $0 : nil }
    }

    var body: some View {
        HStack(spacing: Space.s) {
            KindMark(kind: session.kind)
                .foregroundStyle(driver == nil ? Tone.muted : Palette.working)
                .frame(width: Size.avatar)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.label).font(Typeface.body).lineLimit(1)
                if session.kind == .browser {
                    Text(driver.map { "@\($0.agent) · \($0.action)" } ?? session.spec.url.map(abbreviateURL) ?? "New tab")
                        .font(Typeface.caption)
                        .foregroundStyle(driver == nil ? Tone.faint : Palette.working)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.xs)
            if session.kind != .browser {
                PortChips(ports: session.ports, compact: true)
                StatusDot(state: session.state, size: 6)
            }
        }
        .padding(.leading, nested ? Size.avatar + Space.s : 0)
        .modifier(RowChrome(selected: store.selectedID == session.id) { store.select(session) })
        .contextMenu { SessionMenu(session: session, actions: actions) }
        .opacity(session.isMinimized ? 0.6 : 1)
        .help(session.foregroundProcess ?? session.spec.command ?? session.spec.url ?? abbreviateHome(session.spec.cwd))
    }
}

private struct ClosedRow: View {
    let spec: LaunchSpec
    let reopen: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            AgentAvatar(kind: spec.kind, dimmed: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(spec.label).font(Typeface.body).foregroundStyle(Tone.muted).lineLimit(1)
                if let summary = spec.summary ?? spec.memory?.task {
                    Text(summary).font(Typeface.caption).foregroundStyle(Tone.faint).lineLimit(1)
                }
            }
            Spacer(minLength: Space.xs)
            Text("Reopen").font(Typeface.caption.weight(.medium)).foregroundStyle(Palette.accent)
        }
        .modifier(RowChrome(selected: false, action: reopen))
        .help(spec.canResume ? "Reopen @\(spec.label) and resume its conversation"
                             : "Reopen @\(spec.label) as a new conversation in its folder")
    }
}

// MARK: - Footer

private struct SidebarFooter: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    var body: some View {
        VStack(spacing: Space.s) {
            Hairline()
            HStack(spacing: Space.s) {
                // Both meters stack when Claude and Codex are both in use; each is labeled then.
                VStack(alignment: .leading, spacing: Space.s) {
                    let both = store.rateLimits != nil && store.codexRateLimits != nil
                    if let limits = store.rateLimits { UsageMeter(limits: limits, label: both ? "Claude" : nil) }
                    if let limits = store.codexRateLimits { UsageMeter(limits: limits, label: both || store.rateLimits == nil ? "Codex" : nil) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("New Terminal…", action: actions.newSession)
                    Divider()
                    ForEach(SessionKind.allCases) { kind in
                        Button { NSApp.sendAction(#selector(AppDelegate.newSessionOfKind(_:)), to: nil, from: KindSender(kind: kind)) } label: {
                            Label("New \(kind.displayName)", systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(Typeface.body.weight(.medium)).foregroundStyle(Tone.muted)
                } primaryAction: {
                    actions.newSession()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New terminal (⌘N)")
            }
            // The organizer's mark floats in this corner (OrganizerDock), so the row starts past it
            // and is as tall as its button.
            .frame(minHeight: buttonSize)
            .padding(.leading, Space.m + buttonSize + Space.s)
            .padding(.trailing, Space.m)
            .padding(.bottom, Space.m)
        }
    }

    private var buttonSize: CGFloat { OrganizerDock.markSize(for: NSScreen.main) + Space.s }
}

/// Account usage windows shared by every agent: the thing that actually caps parallelism.
struct UsageMeter: View {
    let limits: RateLimits
    var label: String?

    /// Wide enough for "Week" and "100%" in the micro face, so the bars line up.
    private static let titleWidth: CGFloat = 30
    private static let percentWidth: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if let label {
                Text(label).font(Typeface.micro.weight(.medium)).foregroundStyle(Tone.muted).lineLimit(1)
            }
            gauge("5h", limits.fiveHourPercent, limits.fiveHourResets)
            gauge("Week", limits.sevenDayPercent, limits.sevenDayResets)
        }
    }

    @ViewBuilder private func gauge(_ title: String, _ percent: Double?, _ reset: Date?) -> some View {
        if let percent {
            let high = percent > 80
            let fraction = max(0, min(percent, 100)) / 100
            HStack(spacing: Space.s) {
                Text(title).foregroundStyle(Tone.faint)
                    .frame(width: Self.titleWidth, alignment: .leading)
                Capsule().fill(Tone.raised)
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { bar in
                            Capsule().fill(high ? Palette.attention : Tone.muted)
                                .frame(width: bar.size.width * fraction)
                        }
                    }
                Text("\(Int(percent))%").monospacedDigit().foregroundStyle(high ? Palette.attention : Tone.faint)
                    .frame(width: Self.percentWidth, alignment: .trailing)
            }
            .font(Typeface.micro)
            .lineLimit(1)
            .help("\(title == "5h" ? "5-hour" : "Weekly") usage" + (reset.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
        }
    }
}

// MARK: - Shared pieces

struct PortChips: View {
    let ports: [Int]
    var compact = false

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(ports.prefix(compact ? 2 : 4), id: \.self) { port in
                Button {
                    if let url = URL(string: "http://localhost:" + String(port)) { NSWorkspace.shared.open(url) }
                } label: {
                    Tag(text: ":" + String(port), tint: Palette.running, mono: true)
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
            if session.kind == .claude {
                Button("Fork Conversation") { _ = session.store?.fork(session) }
                    .disabled(session.spec.agentSessionId == nil)
            }
            if session.store?.rateLimitReset(for: session) != nil {
                Button("Continue When the Limit Resets") { session.store?.continueAtReset(session) }
            }
            if session.resumeAt != nil {
                Button("Cancel Scheduled Continue") { session.store?.cancelContinue(session) }
            }
        }
        if session.kind != .browser {
            Button("Open in \(Editors.preferred?.name ?? "Editor")") { Editors.open(session.spec.workPath) }
        }
        if let store = session.store, !store.raceSiblings(of: session).isEmpty {
            Button("Pick This One…") { actions.pickWinner(session) }
        }
        Divider()
        Button(session.isMinimized ? "Restore Tile" : "Minimize Tile") {
            session.store?.setMinimized(session, !session.isMinimized)
        }
        Button("Rename…") { actions.rename(session) }
        if session.kind.isAgent && !session.spec.agentMayRename {
            Button("Let Agent Name It") { actions.releaseLabel(session) }
        }
        Button("Restart") { actions.restart(session) }
        if session.isAsleep {
            Button("Wake") { session.store?.wake(session) }
        } else if session.kind.isAgent, !session.isOrganizer {
            Button("Sleep") { session.store?.sleep(session) }
                .disabled(session.store?.canSleep(session) != true)
                .help("Quit the agent to free its memory; its next message resumes the conversation")
        }
        if session.kind.isAgent, AccountStore.shared.accounts(for: session.kind).count > 1 {
            Menu("Move to Account") {
                ForEach(AccountStore.shared.accounts(for: session.kind)) { account in
                    let current = (session.spec.account ?? AgentAccount.defaultID) == account.id
                    let email = AccountStore.signedInEmail(account)
                    Button((current ? "✓ " : "") + account.name + (email.map { " · \($0)" } ?? " · not signed in")) {
                        session.store?.move(session, to: account)
                    }
                    .disabled(current || email == nil)
                }
            }
        }
        if session.kind == .claude {
            Button("Continue on Phone…") { session.openRemoteControl() }
        }
        Divider()
        Button("Copy Label") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("@" + session.label, forType: .string)
        }
        Button("Reveal in Finder") {
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
    /// Opens the inspector on the agent's pending plan.
    var showPlan: (TerminalSession) -> Void = { _ in }
    /// Keeps one racing agent's work and closes the others, after confirming.
    var pickWinner: (TerminalSession) -> Void = { _ in }
}

/// Wraps children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.s - 2

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
