import AppKit
import SwiftUI

struct SwitcherItem: Identifiable {
    enum Kind { case session(TerminalSession), message(TerminalSession, String), action(() -> Void) }
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    let kind: Kind

    var group: String {
        switch kind {
        case .session: return "SESSIONS"
        case .message: return "MESSAGE"
        case .action: return id.hasPrefix("layout-") ? "ARRANGE" : "CREATE"
        }
    }
}

/// ⌘P: jump to a terminal, run an action, or "@label message" to message a terminal.
@MainActor
enum SwitcherModel {
    static func items(query raw: String, store: SessionStore, quickCreate: @escaping (SessionKind) -> Void) -> [SwitcherItem] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = messageItem(query, store: store) { return [message] }
        let commandOnly = query.hasPrefix(">")
        let search = commandOnly ? String(query.dropFirst()).trimmingCharacters(in: .whitespaces) : query
        let candidates: [TerminalSession] = commandOnly ? [] : store.sessions
        let ranked: [(session: TerminalSession, score: Int, index: Int)] = candidates.enumerated()
            .map { index, session in (session: session, score: score(search, session), index: index) }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.index < $1.index
            }
        let sessions: [SwitcherItem] = ranked.map { result in
            let session = result.session
            return SwitcherItem(id: session.id.uuidString, title: "@" + session.label,
                                subtitle: [session.statusWord, session.summary ?? shortPath(session.spec.cwd)].joined(separator: " · "),
                                symbol: session.kind.symbol, tint: session.kind.tint, kind: .session(session))
        }
        return sessions + (query.hasPrefix("@") ? [] : actions(search, store: store, quickCreate: quickCreate))
    }

    private static func messageItem(_ query: String, store: SessionStore) -> SwitcherItem? {
        guard query.hasPrefix("@"), let space = query.firstIndex(of: " ") else { return nil }
        let label = String(query[query.index(after: query.startIndex)..<space])
        let text = query[space...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let target = store.find(label) else { return nil }
        return SwitcherItem(id: "msg", title: "Send to @\(target.label)", subtitle: text, symbol: "paperplane.fill",
                            tint: Palette.accent, kind: .message(target, text))
    }

    private static func actions(_ query: String, store: SessionStore, quickCreate: @escaping (SessionKind) -> Void) -> [SwitcherItem] {
        var all: [SwitcherItem] = SessionKind.allCases.filter { $0 != .server }.map { kind in
            SwitcherItem(id: "new-\(kind.rawValue)", title: "New \(kind.displayName)", subtitle: "Start in the current workspace",
                         symbol: kind.symbol, tint: kind.tint, kind: .action { quickCreate(kind) })
        }
        all += LayoutMode.allCases.map { mode in
            SwitcherItem(id: "layout-\(mode.rawValue)", title: "\(mode.title) layout", subtitle: layoutDescription(mode),
                         symbol: mode.symbol, tint: Palette.accent, kind: .action { store.setLayout(mode) })
        }
        guard !query.isEmpty else { return all }
        let ranked: [(item: SwitcherItem, score: Int, index: Int)] = all.enumerated()
            .map { (item: $0.element, score: fuzzyScore(query, $0.element.title), index: $0.offset) }
        let matches = ranked.filter { $0.score > 0 }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        return matches.map { $0.item }
    }

    private static func layoutDescription(_ mode: LayoutMode) -> String {
        switch mode {
        case .focus: return "One session, all your attention"
        case .split: return "Your two recent sessions side by side"
        case .grid: return "Keep every active session in view"
        }
    }

    private static func score(_ query: String, _ session: TerminalSession) -> Int {
        guard !query.isEmpty else { return 1 + (session.state.needsAttention ? 10 : 0) }
        let q = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let label = fuzzyScore(q, session.label) * 3
        let other = fuzzyScore(q, [(session.summary ?? ""), session.spec.cwd, session.kind.rawValue].joined(separator: " ").lowercased())
        return max(label, other)
    }

    /// Subsequence match; consecutive and prefix matches score higher. 0 means no match.
    nonisolated static func fuzzyScore(_ query: String, _ text: String) -> Int {
        guard !query.isEmpty else { return 1 }
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let text = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if text.hasPrefix(query) { return 100 }
        if text.contains(query) { return 60 }
        var score = 0
        var streak = 0
        var index = text.startIndex
        for char in query {
            guard let found = text[index...].firstIndex(of: char) else { return 0 }
            streak = found == index ? streak + 1 : 0
            let boundary = found == text.startIndex || !text[text.index(before: found)].isLetter
            score += 1 + streak * 2 + (boundary ? 5 : 0)
            index = text.index(after: found)
        }
        return score
    }
}

struct QuickSwitcherView: View {
    @ObservedObject var store: SessionStore
    let quickCreate: (SessionKind) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = SwitcherModel.items(query: query, store: store, quickCreate: quickCreate)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "command")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text("COMMAND CENTER")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(Color(nsColor: Ink.muted))
                    TextField("Search sessions and commands…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .focused($focused)
                        .onSubmit { run(selection, in: results) }
                        .accessibilityLabel("Search sessions and commands")
                }
                Spacer(minLength: 0)
                KeyboardHint(keys: "esc")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 17)
            Color(nsColor: Ink.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if results.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 23, weight: .light))
                                    .foregroundStyle(Color(nsColor: Ink.faint))
                                Text("No matches for “\(query)”")
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(2)
                                Text("Try a session name, an agent, or a layout.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color(nsColor: Ink.muted))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || results[index - 1].group != item.group {
                                Text(item.group)
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(1.3)
                                    .foregroundStyle(Color(nsColor: Ink.faint))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 11)
                                    .padding(.top, index == 0 ? 4 : 11)
                                    .padding(.bottom, 3)
                            }
                            Button { run(index, in: results) } label: {
                                row(item, selected: index == selection)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selection) {
                    if results.indices.contains(selection) { proxy.scrollTo(results[selection].id) }
                }
            }
            .frame(height: 310)
            Color(nsColor: Ink.hairline).frame(height: 1)
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    KeyboardHint(keys: "↑ ↓")
                    Text("Navigate")
                }
                HStack(spacing: 5) {
                    KeyboardHint(keys: "↵")
                    Text("Open")
                }
                Spacer()
                Text("@ to message · > for commands")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color(nsColor: Ink.muted))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 560)
        .foregroundStyle(Color(nsColor: Ink.text))
        .background(Color(nsColor: Ink.deep))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(nsColor: Ink.hairline)))
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onChange(of: results.map(\.id)) { selection = min(selection, max(results.count - 1, 0)) }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ item: SwitcherItem, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(item.tint)
                .frame(width: 32, height: 32)
                .background(item.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium, design: item.title.hasPrefix("@") ? .monospaced : .default))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: Ink.muted)).lineLimit(1)
                }
            }
            Spacer()
            if selected {
                KeyboardHint(keys: "↵")
            } else if case .session(let session) = item.kind {
                Circle().fill(Palette.status(session.state)).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Palette.accent.opacity(0.12) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Palette.accent.opacity(0.22) : .clear))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func run(_ index: Int, in current: [SwitcherItem]) {
        guard current.indices.contains(index) else { return }
        dismiss()
        switch current[index].kind {
        case .session(let session): store.select(session)
        case .message(let session, let text): _ = session.deliver(sanitizeMessage(text), from: nil)
        case .action(let action): action()
        }
    }
}

/// Borderless floating panel that closes when it loses focus.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }
}
