import SwiftUI

struct NewSessionDraft {
    var kind: SessionKind = .claude
    var label = ""
    var cwd = NSHomeDirectory()
    var command = ""
    var worktree = false
    /// nil: the account picked for new agents of this kind.
    var account: String?
}

struct NewSessionView: View {
    @State var draft: NewSessionDraft
    let recentDirectories: [String]
    let onCreate: (NewSessionDraft) -> Void
    let onCancel: () -> Void
    @FocusState private var focus: Field?

    private enum Field { case label, command }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "terminal")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 44, height: 44)
                    .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Create a session")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.5)
                    Text("Agents, terminals, servers, and browsers.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(nsColor: Ink.muted))
                }
                Spacer()
                Text("NEW SESSION")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(Color(nsColor: Ink.faint))
                    .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Session type")
                HStack(spacing: 8) {
                    ForEach(SessionKind.allCases) { kind in
                        KindCard(kind: kind, selected: draft.kind == kind) {
                            draft.kind = kind
                            draft.account = nil
                            focus = kind == .server || kind == .browser ? .command : .label
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Configuration")
                FieldRow(title: "Label") {
                    HStack(spacing: 0) {
                        Text("@").foregroundStyle(Palette.accent).padding(.trailing, 3)
                        TextField("", text: $draft.label, prompt: Text(labelPlaceholder))
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .label)
                            .accessibilityLabel("Session label")
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .inputChrome(focused: focus == .label)
                }
                FieldRow(title: "Folder") {
                    Menu {
                        ForEach(recentDirectories, id: \.self) { dir in
                            Button(abbreviateHome(dir)) { draft.cwd = dir }
                        }
                        if !recentDirectories.isEmpty { Divider() }
                        Button("Choose folder…") { chooseFolder() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(Color(nsColor: Ink.muted))
                            Text(abbreviateHome(draft.cwd)).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(nsColor: Ink.faint))
                        }
                        .font(.system(size: 12.5))
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .inputChrome()
                    .help(draft.cwd)
                    .accessibilityLabel("Working folder")
                }
                if draft.kind.isAgent, AccountStore.shared.accounts(for: draft.kind).count > 1 {
                    FieldRow(title: "Account") {
                        Picker("", selection: Binding(
                            get: { draft.account ?? AccountStore.shared.preferredID(for: draft.kind) },
                            set: { draft.account = $0 })) {
                            ForEach(AccountStore.shared.accounts(for: draft.kind)) { account in
                                Text(account.name + (AccountStore.signedInEmail(account).map { " · \($0)" } ?? " · not signed in"))
                                    .tag(account.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Account")
                    }
                }
                if draft.kind.isAgent {
                    FieldRow(title: "Isolation") {
                        Toggle(isOn: $draft.worktree) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Use a dedicated worktree")
                                    .font(.system(size: 12.5, weight: .medium))
                                Text("Keep this agent’s changes on its own branch.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(nsColor: Ink.muted))
                            }
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
                        .inputChrome(focused: focus == .command)
                        .accessibilityLabel(commandTitle)
                }
                if draft.kind == .server && draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a command to start your server.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Ink.muted))
                        .padding(.leading, 82)
                }
            }
            .padding(16)
            .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: Ink.hairline), lineWidth: 1))

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: draft.kind.isAgent ? "point.3.connected.trianglepath.dotted" : "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: Ink.muted))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Text("↵").font(.system(size: 12, design: .monospaced))
                    Text("to create")
                }
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Ink.faint))
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                Button {
                    onCreate(draft)
                } label: {
                    HStack(spacing: 8) {
                        Text("Create session")
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(ChromeButtonStyle(accent: true))
                    .disabled(draft.kind == .server && draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(26)
        .frame(width: 584)
        .foregroundStyle(Color(nsColor: Ink.text))
        .background(Color(nsColor: Ink.deep))
        .tint(Palette.accent)
        .onAppear { focus = draft.kind == .server || draft.kind == .browser ? .command : .label }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Color(nsColor: Ink.faint))
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
        case .codex: return "optional · --model <model>"
        case .server: return "pnpm dev"
        case .shell: return "optional"
        case .browser: return "localhost:3000"
        }
    }

    private var hint: String {
        let label = "@" + (draft.label.isEmpty ? labelPlaceholder : normalizeLabel(draft.label))
        switch draft.kind {
        case .claude: return "Runs Claude Code named \(label). Other agents can message it by that name."
        case .codex: return "Runs Codex as \(label). Agents reach it through Kuronami's MCP tools."
        case .server: return "Runs the command as \(label). Ports appear in the sidebar; agents can read its logs or restart it."
        case .shell: return "A login shell labeled \(label)."
        case .browser: return "A Chromium browser labeled \(label). Agents can drive it by that name; it shares logins with your other Kuronami browsers."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a working folder"
        panel.prompt = "Use folder"
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
            VStack(spacing: 8) {
                AgentAvatar(kind: kind, state: kind.isAgent ? .idle : .running)
                Text(kind.displayName)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Color(nsColor: selected ? Ink.text : Ink.muted))
                Text(kind.isAgent ? "AI AGENT" : kind == .server ? "PROCESS" : kind == .browser ? "WEB" : "TERMINAL")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(selected ? Palette.accent : Color(nsColor: Ink.faint))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(0.10) : Color(nsColor: hovering ? Ink.raised : Ink.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Palette.accent.opacity(0.65) : Color(nsColor: Ink.hairline), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.accent)
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FieldRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Ink.muted))
                .frame(width: 70, alignment: .leading)
            content
        }
    }
}

private extension View {
    func inputChrome(focused: Bool = false) -> some View {
        padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Ink.deep)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Palette.accent.opacity(0.7) : Color(nsColor: Ink.hairline), lineWidth: 1))
    }
}
