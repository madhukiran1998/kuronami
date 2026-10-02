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
}

/// ⌘P: jump to a terminal, run an action, or "@label message" to message a terminal.
@MainActor
enum SwitcherModel {
    static func items(query raw: String, store: SessionStore, quickCreate: @escaping (SessionKind) -> Void) -> [SwitcherItem] {
        let query = raw.trimmingCharacters(in: .whitespaces)
        if let message = messageItem(query, store: store) { return [message] }
        let sessions = store.sessions
            .map { session in (session, score(query, session)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { session, _ in
                SwitcherItem(id: session.id.uuidString, title: "@" + session.label,
                             subtitle: [session.state.phrase, session.summary ?? shortPath(session.spec.cwd)].joined(separator: " · "),
                             symbol: session.kind.symbol, tint: session.kind.tint, kind: .session(session))
            }
        return sessions + actions(query, store: store, quickCreate: quickCreate)
    }

    private static func messageItem(_ query: String, store: SessionStore) -> SwitcherItem? {
        guard query.hasPrefix("@"), let space = query.firstIndex(of: " ") else { return nil }
        let label = String(query[query.index(after: query.startIndex)..<space])
        let text = query[space...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let target = store.find(label) else { return nil }
        return SwitcherItem(id: "msg", title: "Send to @\(target.label)", subtitle: text, symbol: "paperplane.fill",
                            tint: .accentColor, kind: .message(target, text))
    }

    private static func actions(_ query: String, store: SessionStore, quickCreate: @escaping (SessionKind) -> Void) -> [SwitcherItem] {
        var all: [SwitcherItem] = SessionKind.allCases.filter { $0 != .server }.map { kind in
            SwitcherItem(id: "new-\(kind.rawValue)", title: "New \(kind.displayName) here", subtitle: nil,
                         symbol: "plus", tint: kind.tint, kind: .action { quickCreate(kind) })
        }
        all += LayoutMode.allCases.map { mode in
            SwitcherItem(id: "layout-\(mode.rawValue)", title: "\(mode.title) layout", subtitle: nil,
                         symbol: mode.symbol, tint: .secondary, kind: .action { store.setLayout(mode) })
        }
        guard !query.isEmpty else { return all }
        return all.filter { fuzzyScore(query.lowercased(), $0.title.lowercased()) > 0 }
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
        if text.hasPrefix(query) { return 100 }
        if text.contains(query) { return 60 }
        var score = 0
        var streak = 0
        var index = text.startIndex
        for char in query {
            guard let found = text[index...].firstIndex(of: char) else { return 0 }
            streak = found == index ? streak + 1 : 0
            score += 1 + streak * 2
            index = text.index(after: found)
        }
        return score
    }
}

struct QuickSwitcherView: View {
    let store: SessionStore
    let quickCreate: (SessionKind) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var items: [SwitcherItem] { SwitcherModel.items(query: query, store: store, quickCreate: quickCreate) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to terminal, run an action, or @label message…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { run(selection) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selection)
                                .id(index)
                                .onTapGesture { run(index) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ item: SwitcherItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium, design: item.title.hasPrefix("@") ? .monospaced : .default))
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
    }

    private func run(_ index: Int) {
        let current = items
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
