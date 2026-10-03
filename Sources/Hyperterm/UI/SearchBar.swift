import SwiftUI

/// ⌘F over the focused terminal. Uses libghostty's own search (scrollback included).
@MainActor
final class SearchModel: ObservableObject {
    @Published var needle = ""
    @Published var total: Int?
    @Published var selected: Int?
}

struct SearchBar: View {
    @ObservedObject var model: SearchModel
    let onChange: (String) -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    private var canNavigate: Bool { !model.needle.isEmpty && model.total != 0 }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accent)
            TextField("Find in terminal…", text: $model.needle)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onSubmit { if canNavigate { onNext() } }
                .onChange(of: model.needle) { onChange(model.needle) }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    if canNavigate { onPrevious() }
                    return .handled
                }
                .frame(minWidth: 100, idealWidth: 176, maxWidth: 210)
                .accessibilityLabel("Find in terminal")
            Text(counter)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(model.total == 0 ? Palette.attention : Color(nsColor: Ink.muted))
                .frame(width: 72, alignment: .trailing)
                .accessibilityLabel(counter.isEmpty ? "Enter a search" : counter)
            Color(nsColor: Ink.hairline).frame(width: 1, height: 17)
            HStack(spacing: 2) {
                searchButton("chevron.up", label: "Previous match", hint: "Previous match (⇧↵)", action: onPrevious)
                    .disabled(!canNavigate)
                searchButton("chevron.down", label: "Next match", hint: "Next match (↵)", action: onNext)
                    .disabled(!canNavigate)
                searchButton("xmark", label: "Close search", hint: "Close search (Esc)", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .foregroundStyle(Color(nsColor: Ink.text))
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(focused ? Palette.accent.opacity(0.4) : Color(nsColor: Ink.hairline)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .onAppear { focused = true }
    }

    private func searchButton(_ symbol: String, label: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(SearchControlStyle())
        .help(hint)
        .accessibilityLabel(label)
    }

    private var counter: String {
        guard let total = model.total, !model.needle.isEmpty else { return "" }
        guard total > 0 else { return "No matches" }
        return "\(min((model.selected ?? 0) + 1, total)) of \(total)"
    }
}

private struct SearchControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: isEnabled ? Ink.text : Ink.faint))
            .background(Color(nsColor: configuration.isPressed ? Ink.raised : Ink.surface), in: RoundedRectangle(cornerRadius: 5))
    }
}
