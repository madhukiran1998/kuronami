import SwiftUI

/// Shown when there are no terminals: the app's icon, one line on what it does, and a way to
/// start each kind of terminal.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                Text("Run agents side by side")
                    .font(.system(size: 22, weight: .semibold))
                Text("Each terminal gets a label like @api. Hyperterm shows what every agent is doing,\nbrings you the ones that need you, and lets them message each other.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
                shortcut("⌥⌘R", "Review")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption.monospaced().weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? kind.tint.opacity(0.6) : Color.primary.opacity(0.08)))
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
