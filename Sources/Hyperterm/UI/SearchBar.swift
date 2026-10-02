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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Find", text: $model.needle)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .focused($focused)
                .onSubmit(onNext)
                .onChange(of: model.needle) { onChange(model.needle) }
                .frame(width: 180)
            Text(counter).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .trailing)
            Button(action: onPrevious) { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
            Button(action: onNext) { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
            Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ChromeColors.hairline))
        .onAppear { focused = true }
    }

    private var counter: String {
        guard let total = model.total, !model.needle.isEmpty else { return "" }
        guard total > 0 else { return "none" }
        return "\((model.selected ?? 0) + 1)/\(total)"
    }
}
