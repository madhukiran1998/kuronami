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
                ContentUnavailableView("No Terminal Selected", systemImage: "sidebar.right")
            }
        }
        .frame(minWidth: 320)
    }
}

private struct InspectorContent: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: SessionStore
    let actions: SessionActions

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $store.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch store.inspectorTab {
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
                ContentUnavailableView(loading ? "Loading changes…" : "No Changes",
                                       systemImage: loading ? "hourglass" : "checkmark.seal",
                                       description: Text(loading ? "" : "The agent hasn't changed any files here."))
            } else {
                fileList
                Divider()
                patchView
            }
            Divider()
            footer
        }
        .task(id: session.diffStat) { await load() }
        .onAppear { session.readyForReview = false }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let stat = session.diffStat, !stat.isEmpty {
                    Text(stat.text).font(.headline.monospacedDigit())
                } else {
                    Text("Changes").font(.headline)
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
                    ForEach(PatchLine.parse(file.patch)) { line in
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
        .background(line.kind == .added ? Palette.running.opacity(0.14) : line.kind == .removed ? Palette.failed.opacity(0.14) : .clear)
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
        let loaded = await Task.detached { Review.fileDiffs(at: path, base: base) }.value
        files = loaded
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
    enum Kind { case header, added, removed, context }
    let id: Int
    let kind: Kind
    let text: String
    let newNumber: Int?

    static func parse(_ patch: String) -> [PatchLine] {
        var result: [PatchLine] = []
        var newLine = 0
        for (index, raw) in patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
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
        Form {
            Section {
                LabeledContent("Label", value: "@" + session.label)
                LabeledContent("Kind", value: session.kind.displayName)
                LabeledContent("State", value: session.state.phrase + (session.state.detail.map { " · " + $0 } ?? ""))
                LabeledContent("Folder") { Text(abbreviateHome(session.spec.workPath)).textSelection(.enabled).lineLimit(2).truncationMode(.head) }
                if let branch = session.git?.branch { LabeledContent("Branch", value: branch) }
                if let port = session.spec.port { LabeledContent("Port", value: String(port)) }
            }
            if session.kind == .claude {
                Section("Usage") {
                    LabeledContent("Model", value: session.usage.model ?? "—")
                    LabeledContent("Cost", value: session.usage.costUSD.map { String(format: "$%.2f", $0) } ?? "—")
                    LabeledContent("Context") {
                        if let context = session.usage.contextPercent {
                            ProgressView(value: min(context, 100), total: 100) { EmptyView() } currentValueLabel: { Text("\(Int(context))%") }
                        } else { Text("—") }
                    }
                    if let limits = store.rateLimits { UsageMeter(limits: limits) }
                }
            }
            if let id = session.spec.agentSessionId {
                Section("Session") {
                    LabeledContent("ID") { Text(id).font(.caption.monospaced()).textSelection(.enabled) }
                    Button("Copy Resume Command") {
                        let command = session.kind == .claude ? "claude --resume \(id)" : "codex resume \(id)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
            }
            Section {
                if session.kind == .claude { Button("Continue on Phone (Remote Control)") { session.openRemoteControl() } }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.spec.workPath)]) }
                Button("Rename…") { actions.rename(session) }
            }
        }
        .formStyle(.grouped)
    }
}
