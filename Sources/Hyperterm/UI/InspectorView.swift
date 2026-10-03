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
                Text("Select a terminal").foregroundStyle(.secondary).padding(.top, 40)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct InspectorContent: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentAvatar(kind: session.kind, state: session.state)
                VStack(alignment: .leading, spacing: 1) {
                    Text("@" + session.label).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(shortPath(session.spec.workPath)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            if session.kind != .browser {
                Picker("", selection: $store.inspectorTab) {
                    ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            Divider()
            switch session.kind == .browser ? .info : store.inspectorTab {
            case .changes: ChangesView(session: session, store: store)
            case .activity: ActivityView(session: session)
            case .info: InfoView(session: session, store: store, actions: actions)
            }
        }
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

    private var path: String { session.spec.workPath }
    private var isWorktree: Bool { session.spec.worktreeBranch != nil || session.git?.isWorktree == true }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: loading ? "hourglass" : "checkmark.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(loading ? "Loading changes…" : "No changes yet")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if !loading {
                        Text("When @\(session.label) edits files, the diff shows up here for review.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                fileList
                Divider()
                patchView
            }
            if !files.isEmpty || !comments.isEmpty {
                Divider()
                footer
            }
        }
        .task(id: session.diffStat) { await load() }
        .onAppear { session.readyForReview = false }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !files.isEmpty {
                    let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
                    Text(DiffStat(added: added, removed: removed, files: files.count).text).font(.headline.monospacedDigit())
                } else {
                    Text(files.isEmpty ? "Working tree clean" : "\(files.count) changed file\(files.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            HStack(spacing: 10) {
                if let branch = session.git?.branch {
                    Label(session.spec.baseBranch.map { "\(branch) → \($0)" } ?? branch, systemImage: "arrow.triangle.branch")
                }
                if let evidence = session.testEvidence {
                    Label(evidence.summary, systemImage: evidence.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(evidence.passed ? Palette.running : Palette.failed)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var fileList: some View {
        List(files, selection: $selected) { file in
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(file.path).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("+\(file.added)").foregroundStyle(Palette.running)
                Text("−\(file.removed)").foregroundStyle(Palette.failed)
            }
            .font(.caption.monospaced())
            .tag(file.path)
        }
        .listStyle(.inset)
        .frame(height: min(CGFloat(files.count) * 24 + 12, 170))
    }

    private var patchView: some View {
        let file = files.first { $0.path == selected } ?? files.first
        return ScrollView(.vertical) {
            if let file {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(parsed[file.path] ?? []) { line in
                        patchRow(line, file: file)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: Theme.terminalBackground))
    }

    @ViewBuilder private func patchRow(_ line: PatchLine, file: Review.FileDiff) -> some View {
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
        ForEach(comments.filter { $0.path == file.path && $0.line == line.newNumber }) { comment in
            CommentBubble(text: comment.text) { comments.removeAll { $0.id == comment.id } }
        }
        if draftLine == line.newNumber, commentable {
            HStack {
                TextField("Comment for the agent", text: $draftText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addComment(file: file, line: line) }
                Button("Add") { addComment(file: file, line: line) }
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
                Button("Commit…") { commit() }
                Menu("More") {
                    Button("Open Pull Request") { run { Review.openPullRequest(at: path, base: session.spec.baseBranch, title: commitTitle).map { "Opened \($0)" } } }
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
                .fixedSize()
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            .disabled(working || files.isEmpty && session.diffStat?.isEmpty != false)
            if let result {
                Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(10)
    }

    private var commitTitle: String {
        let base = session.agentStatus ?? session.summary ?? "Changes from @\(session.label)"
        return String(base.trimmingCharacters(in: CharacterSet(charactersIn: "› ")).prefix(72))
    }

    private func load() async {
        loading = true
        let path = self.path, base = session.spec.baseBranch
        let (loaded, lines) = await Task.detached {
            let diffs = Review.fileDiffs(at: path, base: base)
            return (diffs, Dictionary(diffs.map { ($0.path, PatchLine.parse($0.patch)) }, uniquingKeysWith: { first, _ in first }))
        }.value
        files = loaded
        parsed = lines
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
        let message = field.stringValue
        run { Review.commit(at: path, message: message).map { "Committed \($0)" } }
    }

    private func archive() {
        let alert = NSAlert()
        alert.messageText = "Archive @\(session.label)'s worktree?"
        alert.informativeText = "Uncommitted work is saved as a commit on its branch, then the folder is removed. The branch stays, so nothing is lost."
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let root = session.git.map(GitInfo.mainRoot) ?? path
        run { Review.archive(worktree: path, mainRoot: root) }
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
            Image(systemName: "text.bubble.fill").foregroundStyle(Palette.attention)
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDelete) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(Palette.attention.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
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
        List {
            if !recent.isEmpty {
                Section("Since you last looked · \(elapsed(since: session.lastViewedAt)) ago") {
                    Text(Recap.sentence(for: recent)).font(.callout)
                }
            }
            Section("Timeline") {
                if session.timeline.isEmpty {
                    Text("Nothing yet. Prompts, tools, approvals, and test runs appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.timeline.reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: Recap.symbol(event.kind))
                            .foregroundStyle(Recap.color(event.kind))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.text).font(.callout).lineLimit(3)
                            Text(event.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("Terminal") {
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
                            HStack {
                                Text("Context").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                                ProgressView(value: min(context, 100), total: 100).controlSize(.small)
                                Text("\(Int(context))%").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let id = session.spec.agentSessionId {
                    group("Session") {
                        row("ID", id, mono: true)
                    }
                }
                HStack(spacing: 8) {
                    if let id = session.spec.agentSessionId {
                        Button("Copy Resume") {
                            let command = session.kind == .claude ? "claude --resume \(id)" : "codex resume \(id)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                    if session.kind == .claude { Button("On Phone") { session.openRemoteControl() }.help("Continue with Claude Remote Control") }
                    Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.spec.workPath)]) }
                }
                .controlSize(.small)
            }
            .padding(14)
            .font(.system(size: 12))
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).tracking(0.5)
            VStack(alignment: .leading, spacing: 5) { content() }
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
            Spacer(minLength: 0)
        }
    }
}
