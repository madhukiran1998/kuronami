import SwiftUI

struct NewSessionDraft {
    var kind: SessionKind = .claude
    var label = ""
    var cwd = NSHomeDirectory()
    var command = ""
    var worktree = false
}

struct NewSessionView: View {
    @State var draft: NewSessionDraft
    let recentDirectories: [String]
    let onCreate: (NewSessionDraft) -> Void
    let onCancel: () -> Void
    @FocusState private var focus: Field?

    private enum Field { case label, command }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Terminal")
                .font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(SessionKind.allCases) { kind in
                    KindCard(kind: kind, selected: draft.kind == kind) { draft.kind = kind }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                FieldRow(title: "Label") {
                    HStack(spacing: 0) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("", text: $draft.label, prompt: Text(labelPlaceholder))
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .label)
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .inputChrome()
                }
                FieldRow(title: "Folder") {
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(recentDirectories, id: \.self) { dir in
                                Button(abbreviateHome(dir)) { draft.cwd = dir }
                            }
                            if !recentDirectories.isEmpty { Divider() }
                            Button("Choose…") { chooseFolder() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(abbreviateHome(draft.cwd)).lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12.5))
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .inputChrome()
                    }
                }
                if draft.kind.isAgent {
                    FieldRow(title: "Isolation") {
                        Toggle(isOn: $draft.worktree) {
                            Text("Own git worktree and branch")
                                .font(.system(size: 12.5))
                        }
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                FieldRow(title: commandTitle) {
                    TextField("", text: $draft.command, prompt: Text(commandPlaceholder))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .focused($focus, equals: .command)
                        .inputChrome()
                }
            }

            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Create") { onCreate(draft) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(draft.kind == .server && draft.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear { focus = draft.kind == .server ? .command : .label }
    }

    private var labelPlaceholder: String {
        let folder = URL(fileURLWithPath: expandTilde(draft.cwd)).lastPathComponent.lowercased()
        return draft.kind == .server ? "\(folder)-server" : folder
    }

    private var commandTitle: String {
        switch draft.kind {
        case .claude, .codex: return "Arguments"
        case .server: return "Command"
        case .shell: return "Run"
        case .browser: return "Address"
        }
    }

    private var commandPlaceholder: String {
        switch draft.kind {
        case .claude: return "optional · --model opus"
        case .codex: return "optional · -m gpt-5"
        case .server: return "pnpm dev"
        case .shell: return "optional"
        case .browser: return "localhost:3000"
        }
    }

    private var hint: String {
        let label = "@" + (draft.label.isEmpty ? labelPlaceholder : normalizeLabel(draft.label))
        switch draft.kind {
        case .claude: return "Runs Claude Code named \(label). Other agents can message it by that name."
        case .codex: return "Runs Codex as \(label). Agents reach it through Hyperterm's MCP tools."
        case .server: return "Runs the command as \(label). Ports appear in the sidebar; agents can read its logs or restart it."
        case .shell: return "A login shell labeled \(label)."
        case .browser: return "A Chromium browser labeled \(label). Agents can drive it by that name; it shares logins with your other Hyperterm browsers."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: expandTilde(draft.cwd))
        if panel.runModal() == .OK, let url = panel.url { draft.cwd = url.path }
    }
}

private struct KindCard: View {
    let kind: SessionKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                AgentAvatar(kind: kind, state: kind.isAgent ? .idle : .running)
                Text(kind.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(kind.tint.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.8 : 0.5)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? kind.tint.opacity(0.7) : Color.primary.opacity(0.07), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FieldRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            content
        }
    }
}

private extension View {
    func inputChrome() -> some View {
        padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
    }
}
