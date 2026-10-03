import SwiftUI

/// Shown when there are no terminals: the app's icon, one line on what it does, and a way to
/// start each kind of terminal.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 104, height: 104)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                Text("All quiet.")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.3)
                Text("Start an agent and it shows up here. Kuronami keeps every agent in view, calls you\nover when one needs you, and gives each one a browser you can watch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            HStack(spacing: 12) {
                ForEach(SessionKind.allCases) { kind in
                    StartButton(kind: kind)
                }
            }
            HStack(spacing: 18) {
                shortcut("⌘N", "New terminal")
                shortcut("⌘P", "Go to anything")
                shortcut("⌘⇧U", "Next waiting")
                shortcut("⇧⌘B", "New browser")
                shortcut("⌥⌘R", "Review")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption.monospaced().weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Ink.surface)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Ink.hairline)))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StartButton: View {
    let kind: SessionKind
    @State private var hovering = false

    var body: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.newSessionOfKind(_:)), to: nil, from: KindSender(kind: kind))
        } label: {
            VStack(spacing: 9) {
                AgentAvatar(kind: kind, state: kind.isAgent ? .idle : .running)
                    .scaleEffect(1.25)
                    .frame(height: 34)
                Text(kind.displayName).font(.callout.weight(.medium))
            }
            .frame(width: 118, height: 92)
            .background(Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? kind.tint.opacity(0.6) : Color(nsColor: Ink.hairline)))
            .shadow(color: hovering ? kind.tint.opacity(0.25) : .clear, radius: 14)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.spring(duration: 0.25), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Carries a kind through the responder chain from SwiftUI buttons.
final class KindSender: NSObject {
    let kind: SessionKind
    init(kind: SessionKind) { self.kind = kind }
}

@MainActor
enum NSHostingViewFactory {
    static func emptyState() -> NSView {
        let view = NSHostingView(rootView: EmptyStateView())
        view.autoresizingMask = [.width, .height]
        return view
    }
}
