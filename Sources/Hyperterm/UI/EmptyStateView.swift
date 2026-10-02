import SwiftUI

/// Shown when there are no terminals: one click to start each kind.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Hyperterm")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Labeled terminals for your agents, shells, and servers.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach(SessionKind.allCases) { kind in
                    Button {
                        NSApp.sendAction(#selector(AppDelegate.newSessionOfKind(_:)), to: nil, from: KindSender(kind: kind))
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(kind.tint)
                            Text(kind.displayName).font(.system(size: 12, weight: .medium))
                        }
                        .frame(width: 104, height: 78)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("⌘N new terminal  ·  ⌘⌥3 grid  ·  ⌘⇧U jump to what needs you")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.terminalBackground))
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
