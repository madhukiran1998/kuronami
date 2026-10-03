import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case changes = "Changes", activity = "Activity", info = "Info"
    var id: String { rawValue }
}

/// Right-hand inspector for the selected terminal.
struct InspectorView: View {
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    var body: some View {
        Group {
            if let session = store.selected {
                InspectorContent(session: session, store: store, actions: actions)
                    .id(session.id)
            } else {
                InspectorEmptyState(symbol: "sidebar.right", title: "Your workspace, in detail", detail: "Select a session to review changes, follow its activity, and see what’s running.")
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Color(nsColor: Ink.text))
        .background(Color(nsColor: Ink.deep))
        .tint(Palette.accent)
    }
}

private struct InspectorContent: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("INSPECTOR")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(Color(nsColor: Ink.faint))
                HStack(spacing: 10) {
                    AgentAvatar(kind: session.kind, state: session.state)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("@" + session.label)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                        Text(session.kind == .browser ? (session.spec.url ?? "New browser tab") : shortPath(session.spec.workPath))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(nsColor: Ink.muted))
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Circle().fill(Palette.status(session.state)).frame(width: 5, height: 5)
                    Text(session.statusWord)
                        .foregroundStyle(session.state.needsAttention ? Palette.attention : Color(nsColor: Ink.muted))
                    Spacer()
                    Text(session.kind.displayName).foregroundStyle(Color(nsColor: Ink.faint))
                }
                .font(.system(size: 10.5, weight: .medium))
            }
            .padding(16)
            if session.kind != .browser {
                HStack(spacing: 4) {
                    ForEach(InspectorTab.allCases) { tab in
                        Button { store.inspectorTab = tab } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 11.5, weight: store.inspectorTab == tab ? .semibold : .medium))
                                .foregroundStyle(store.inspectorTab == tab ? Color(nsColor: Ink.text) : Color(nsColor: Ink.muted))
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .background(store.inspectorTab == tab ? Color(nsColor: Ink.raised) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(store.inspectorTab == tab ? Color(nsColor: Ink.hairline) : .clear, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.inspectorTab == tab ? .isSelected : [])
                    }
                }
                .padding(4)
                .background(Color(nsColor: Ink.floor), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            inspectorRule
            switch session.kind == .browser ? .info : store.inspectorTab {
            case .changes: ChangesView(session: session, store: store)
            case .activity: ActivityView(session: session)
            case .info: InfoView(session: session, store: store, actions: actions)
            }
        }
    }
}

private var inspectorRule: some View {
    Rectangle().fill(Color(nsColor: Ink.hairline)).frame(height: 1)
}

private struct InspectorEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(Palette.accent.opacity(0.8))
                .frame(width: 56, height: 56)
                .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color(nsColor: Ink.hairline), lineWidth: 1))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Color(nsColor: Ink.muted))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 38)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Changes

struct ReviewComment: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let line: Int
    let code: String
    var text: String
}

private struct ChangesView: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    @State private var files: [Review.FileDiff] = []
    /// Parsed once per load, off the main thread: the body re-runs on every session change.
    @State private var parsed: [String: [PatchLine]] = [:]
    @State private var selected: String?
    @State private var loading = false
    @State private var comments: [ReviewComment] = []
    @State private var draftLine: Int?
    @State private var draftText = ""
    @State private var result: String?
    @State private var working = false
    @State private var totals = DiffStat(added: 0, removed: 0, files: 0)
    @State private var loadRequest = UUID()

    private var path: String { session.spec.workPath }
    private var isWorktree: Bool { session.spec.worktreeBranch != nil || session.git?.isWorktree == true }

    var body: some View {
        VStack(spacing: 0) {
            summary
            inspectorRule
            if files.isEmpty {
                InspectorEmptyState(symbol: loading ? "hourglass" : "checkmark.circle", title: loading ? "Loading changes…" : "A clean working tree", detail: loading ? "Reading this session’s latest changes." : "File changes from @\(session.label) appear here. Review a diff and leave comments for the agent.")
            } else {
                fileList
                inspectorRule
                patchView
            }
            if !files.isEmpty || !comments.isEmpty {
                inspectorRule
                footer
            }
        }
        .task(id: session.diffStat) { await load() }
        .onAppear { session.readyForReview = false }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if !files.isEmpty {
                    Text("\(files.count) changed file\(files.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Text("+\(totals.added)").foregroundStyle(Palette.running)
                    Text("−\(totals.removed)").foregroundStyle(Palette.failed)
                } else {
                    Text(loading ? "Reading changes" : "Working tree clean")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: Ink.muted))
                    Spacer()
                }
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(nsColor: Ink.muted))
                    .disabled(loading)
                    .help("Refresh changes")
                    .accessibilityLabel("Refresh changes")
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            VStack(alignment: .leading, spacing: 6) {
                if let branch = session.git?.branch {
                    Label(session.spec.baseBranch.map { "\(branch) → \($0)" } ?? branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(branch)
                }
                if let evidence = session.testEvidence {
                    Label(evidence.summary, systemImage: evidence.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(evidence.passed ? Palette.running : Palette.failed)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color(nsColor: Ink.muted))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(files) { file in
                    Button { selected = file.path; draftLine = nil } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(selected == file.path ? Palette.accent : Color(nsColor: Ink.faint))
                            Text(file.path).lineLimit(1).truncationMode(.head)
                                .foregroundStyle(Color(nsColor: selected == file.path ? Ink.text : Ink.muted))
                            Spacer(minLength: 4)
                            Text("+\(file.added)").foregroundStyle(Palette.running)
                            Text("−\(file.removed)").foregroundStyle(Palette.failed)
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .padding(.horizontal, 9)
                        .frame(height: 31)
                        .background(selected == file.path ? Color(nsColor: Ink.raised) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file.path)
                    .accessibilityAddTraits(selected == file.path ? .isSelected : [])
                }
            }
            .padding(8)
        }
        .frame(height: min(CGFloat(files.count) * 34 + 13, 183))
    }

    private var patchView: some View {
        let file = files.first { $0.path == selected } ?? files.first
        // Index once per render; avoid scanning every review comment for every code line.
        let fileComments = Dictionary(grouping: comments.filter { $0.path == file?.path }, by: \.line)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text("Double-click a line to comment")
                Spacer(minLength: 0)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Color(nsColor: Ink.faint))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            ScrollView(.vertical) {
                if let file {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(parsed[file.path] ?? []) { line in
                            patchRow(line, file: file, lineComments: line.newNumber.flatMap { fileComments[$0] } ?? [])
                        }
                    }
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(Color(nsColor: Theme.terminalBackground))
        }
    }

    @ViewBuilder private func patchRow(_ line: PatchLine, file: Review.FileDiff, lineComments: [ReviewComment]) -> some View {
        let commentable = line.newNumber != nil && line.kind != .header
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(Color(nsColor: Theme.terminalForeground).opacity(0.35))
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .header ? Color.secondary : Color(nsColor: Theme.terminalForeground))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .background(alignment: .leading) {
            if let tint = line.kind.tint {
                // A soft wash plus an edge bar reads as "changed" without a slab of color.
                ZStack(alignment: .leading) {
                    tint.opacity(0.08)
                    tint.opacity(0.85).frame(width: 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard commentable, let number = line.newNumber else { return }
            draftLine = number
            draftText = ""
        }
        .help(commentable ? "Double-click to comment on this line" : "")
        .contextMenu {
            if commentable {
                Button("Add review comment") { draftLine = line.newNumber; draftText = "" }
            }
        }
        ForEach(lineComments) { comment in
            CommentBubble(text: comment.text) { comments.removeAll { $0.id == comment.id } }
        }
        if draftLine == line.newNumber, commentable {
            HStack {
                TextField("Comment for the agent", text: $draftText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addComment(file: file, line: line) }
                Button("Add") { addComment(file: file, line: line) }
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { draftLine = nil }
            }
            .controlSize(.small)
            .padding(6)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !comments.isEmpty {
                Button {
                    sendComments()
                } label: {
                    Label("Send \(comments.count) comment\(comments.count == 1 ? "" : "s") to @\(session.label)", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            HStack {
                Button { commit() } label: { Label("Commit…", systemImage: "checkmark") }
                    .buttonStyle(.bordered)
                Menu("More") {
                    Button("Open Pull Request") {
                        let directory = path, base = session.spec.baseBranch, title = commitTitle
                        run { Review.openPullRequest(at: directory, base: base, title: title).map { "Opened \($0)" } }
                    }
                    if let base = session.spec.baseBranch, let branch = session.git?.branch, isWorktree {
                        Button("Merge into \(base)") {
                            let root = session.git.map(GitInfo.mainRoot) ?? path
                            run { Review.merge(branch: branch, into: base, mainRoot: root) }
                        }
                    }
                    if isWorktree {
                        Divider()
                        Button("Archive Worktree…") { archive() }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            .disabled(working || files.isEmpty && session.diffStat?.isEmpty != false)
            if let result {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Ink.muted))
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 11.5))
        .controlSize(.small)
        .padding(12)
        .background(Color(nsColor: Ink.surface))
    }

    private var commitTitle: String {
        let base = session.agentStatus ?? session.summary ?? "Changes from @\(session.label)"
        return String(base.trimmingCharacters(in: CharacterSet(charactersIn: "› ")).prefix(72))
    }

    private func load() async {
        let request = UUID()
        loadRequest = request
        loading = true
        let path = self.path, base = session.spec.baseBranch
        let (loaded, lines) = await Task.detached {
            let diffs = Review.fileDiffs(at: path, base: base)
            return (diffs, Dictionary(diffs.map { ($0.path, PatchLine.parse($0.patch)) }, uniquingKeysWith: { first, _ in first }))
        }.value
        // A refresh triggered while Git was reading may finish first. Keep the latest load.
        guard loadRequest == request else { return }
        files = loaded
        parsed = lines
        totals = DiffStat(added: loaded.reduce(0) { $0 + $1.added }, removed: loaded.reduce(0) { $0 + $1.removed }, files: loaded.count)
        if selected == nil || !loaded.contains(where: { $0.path == selected }) { selected = loaded.first?.path }
        loading = false
    }

    private func addComment(file: Review.FileDiff, line: PatchLine) {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let number = line.newNumber else { return }
        comments.append(ReviewComment(path: file.path, line: number, code: line.text, text: text))
        draftLine = nil
    }

    private func sendComments() {
        let body = comments.map { "\($0.path):\($0.line) — \($0.text) (on: \($0.code.trimmingCharacters(in: .whitespaces).prefix(80)))" }
        let message = "Review comments on your changes:\n" + body.map { "- " + $0 }.joined(separator: "\n") + "\nPlease address them."
        result = session.deliver(message, from: nil)
        session.record(.message, "Sent \(comments.count) review comments")
        comments = []
    }

    private func commit() {
        let alert = NSAlert()
        alert.messageText = "Commit changes from @\(session.label)"
        alert.informativeText = "Commits everything in \(shortPath(path))."
        let field = NSTextField(string: commitTitle)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let message = field.stringValue, directory = path
        run { Review.commit(at: directory, message: message).map { "Committed \($0)" } }
    }

    private func archive() {
        let alert = NSAlert()
        alert.messageText = "Archive @\(session.label)'s worktree?"
        alert.informativeText = "Uncommitted work is saved as a commit on its branch, then the folder is removed. The branch stays, so nothing is lost."
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let directory = path, root = session.git.map(GitInfo.mainRoot) ?? path
        run { Review.archive(worktree: directory, mainRoot: root) }
    }

    private func run(_ operation: @escaping @Sendable () -> Result<String, ReviewError>) {
        working = true
        result = nil
        Task {
            let outcome = await Task.detached { operation() }.value
            working = false
            switch outcome {
            case .success(let text):
                result = text
                session.record(.note, text)
            case .failure(let error):
                result = "⚠︎ " + error.description
            }
            await load()
            store.refreshReview(session)
        }
    }
}

private struct CommentBubble: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble.fill").foregroundStyle(Palette.accent)
            Text(text).font(.system(size: 11.5)).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Remove review comment")
            .accessibilityLabel("Remove review comment")
        }
        .padding(10)
        .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.accent.opacity(0.22), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// One rendered line of a unified diff, with its line number in the new file.
struct PatchLine: Identifiable {
    enum Kind {
        case header, added, removed, context

        var tint: Color? {
            switch self {
            case .added: Palette.running
            case .removed: Palette.failed
            case .header, .context: nil
            }
        }
    }
    let id: Int
    let kind: Kind
    let text: String
    let newNumber: Int?

    static func parse(_ patch: String) -> [PatchLine] {
        var result: [PatchLine] = []
        var newLine = 0
        for (index, raw) in patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            // The patch's trailing newline is not a line of the file.
            if line.isEmpty { continue }
            if line.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }),
                   let start = Int(plus.dropFirst().split(separator: ",").first ?? "") {
                    newLine = start
                }
                result.append(PatchLine(id: index, kind: .header, text: line, newNumber: nil))
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("new file") {
                continue
            } else if line.hasPrefix("+") {
                result.append(PatchLine(id: index, kind: .added, text: String(line.dropFirst()), newNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                result.append(PatchLine(id: index, kind: .removed, text: String(line.dropFirst()), newNumber: nil))
            } else {
                result.append(PatchLine(id: index, kind: .context, text: String(line.dropFirst(min(1, line.count))), newNumber: newLine))
                newLine += 1
            }
        }
        return result
    }
}

// MARK: - Activity

private struct ActivityView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        let recent = session.timeline.filter { $0.date > session.lastViewedAt }
        if session.timeline.isEmpty {
            InspectorEmptyState(symbol: "clock", title: "The story starts here", detail: "Prompts, commands, approvals, and test results appear as this session gets to work.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("SINCE YOU LAST LOOKED", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(Palette.accent)
                            Text(Recap.sentence(for: recent))
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.accent.opacity(0.18), lineWidth: 1))
                    }
                    HStack {
                        Text("TIMELINE").tracking(0.9)
                        Spacer()
                        Text("\(session.timeline.count) events").monospacedDigit()
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Ink.faint))
                    ForEach(session.timeline.reversed()) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: Recap.symbol(event.kind))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Recap.color(event.kind))
                                .frame(width: 28, height: 28)
                                .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(event.kind.rawValue.capitalized)
                                        .foregroundStyle(Color(nsColor: Ink.muted))
                                    Spacer(minLength: 4)
                                    Text(event.date.formatted(date: .omitted, time: .shortened))
                                        .foregroundStyle(Color(nsColor: Ink.faint))
                                }
                                .font(.system(size: 9.5, weight: .medium))
                                Text(event.text)
                                    .font(.system(size: 11.5))
                                    .lineLimit(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .help(event.text)
                            }
                        }
                        .padding(.bottom, 1)
                    }
                }
                .padding(14)
            }
        }
    }
}

enum Recap {
    /// "6 edits, 2 commands, tests passed, finished: Added refresh rotation."
    static func sentence(for events: [TimelineEvent]) -> String {
        var parts: [String] = []
        let edits = events.filter { $0.kind == .edit }.count
        let tools = events.filter { $0.kind == .tool }.count
        if edits > 0 { parts.append("\(edits) edit\(edits == 1 ? "" : "s")") }
        if tools > 0 { parts.append("\(tools) command\(tools == 1 ? "" : "s")") }
        if let test = events.last(where: { $0.kind == .test }) { parts.append(test.text.lowercased().hasPrefix("tests passed") ? "tests passed" : "tests failing") }
        let approvals = events.filter { $0.kind == .approval }.count
        if approvals > 0 { parts.append("\(approvals) approval\(approvals == 1 ? "" : "s")") }
        if let failure = events.last(where: { $0.kind == .failure }) { parts.append("failed: \(failure.text)") }
        if let done = events.last(where: { $0.kind == .done }) { parts.append("finished: \(done.text)") }
        return parts.isEmpty ? "No activity." : parts.joined(separator: ", ").capitalizedFirst + "."
    }

    static func symbol(_ kind: TimelineEvent.Kind) -> String {
        switch kind {
        case .prompt: return "text.bubble"
        case .tool: return "terminal"
        case .edit: return "pencil"
        case .approval: return "hand.raised"
        case .test: return "checkmark.diamond"
        case .done: return "flag.checkered"
        case .failure: return "exclamationmark.triangle"
        case .message: return "paperplane"
        case .note: return "info.circle"
        }
    }

    static func color(_ kind: TimelineEvent.Kind) -> Color {
        switch kind {
        case .approval: return Palette.attention
        case .failure: return Palette.failed
        case .done, .test: return Palette.running
        case .prompt, .message: return Palette.working
        default: return .secondary
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Info

private struct InfoView: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let actions: SessionActions
    @State private var copiedResume = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group(session.kind == .browser ? "Browser" : "Session details") {
                    row("Kind", session.kind.displayName)
                    row("Status", session.statusWord + (session.state.detail.map { " · " + $0 } ?? ""))
                    if session.kind == .browser {
                        row("Page", session.spec.url ?? "New tab", mono: true)
                        if let owner = session.spec.owner.flatMap({ id in store.sessions.first { $0.id == id } }) {
                            row("Agent", "@" + owner.label, mono: true)
                        }
                    } else {
                        row("Folder", abbreviateHome(session.spec.workPath), mono: true)
                    }
                    if let branch = session.git?.branch { row("Branch", branch, mono: true) }
                    if let port = session.spec.port, store.sessions.contains(where: { $0.kind == .server && $0.spec.port == port }) {
                        row("Dev server", "localhost:\(port)", mono: true)
                    }
                }
                if session.kind == .claude {
                    group("Usage") {
                        row("Model", session.usage.model ?? "—")
                        row("Cost", session.usage.costUSD.map { String(format: "$%.2f", $0) } ?? "—")
                        if let context = session.usage.contextPercent {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Context").foregroundStyle(Color(nsColor: Ink.muted))
                                    Spacer()
                                    Text("\(Int(context))%")
                                        .monospacedDigit()
                                        .foregroundStyle(context >= 90 ? Palette.attention : Color(nsColor: Ink.text))
                                }
                                ProgressView(value: min(max(context, 0), 100), total: 100)
                                    .controlSize(.small)
                                    .tint(context >= 90 ? Palette.attention : Palette.accent)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                if let id = session.spec.agentSessionId {
                    group("Resume") {
                        row("ID", id, mono: true)
                        Button {
                            let command = session.kind == .claude ? "claude --resume \(id)" : "codex resume \(id)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copiedResume = true
                        } label: {
                            Label(copiedResume ? "Copied resume command" : "Copy resume command", systemImage: copiedResume ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 5)
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.spec.workPath)])
                    } label: {
                        Label("Open in Finder", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    if session.kind == .claude {
                        Button { session.openRemoteControl() } label: { Label("On phone", systemImage: "iphone") }
                            .help("Continue with Claude Remote Control")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
            .font(.system(size: 12))
        }
        .task(id: copiedResume) {
            guard copiedResume else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedResume = false
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: Ink.faint))
                .tracking(0.9)
            VStack(alignment: .leading, spacing: 10) { content() }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Ink.hairline), lineWidth: 1))
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Color(nsColor: Ink.muted)).frame(width: 62, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
            Spacer(minLength: 0)
        }
    }
}
