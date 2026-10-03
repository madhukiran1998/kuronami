import SwiftUI

/// A quiet launchpad with the first action in reach, including on narrow canvases.
struct EmptyStateView: View {
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    hero
                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            StartButton(kind: .claude, prominent: true)
                            StartButton(kind: .codex, prominent: true)
                        }
                        HStack(spacing: 10) {
                            StartButton(kind: .shell, prominent: false)
                            StartButton(kind: .server, prominent: false)
                            StartButton(kind: .browser, prominent: false)
                        }
                    }
                    .frame(maxWidth: 560)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 22) {
                            shortcut("⌘N", "New session")
                            shortcut("⌘P", "Command center")
                            shortcut("⌘J", "Next waiting")
                        }
                        HStack(spacing: 18) {
                            shortcut("⌘N", "New session")
                            shortcut("⌘P", "Commands")
                        }
                    }
                    .padding(.top, 1)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(Color(nsColor: Ink.text))
        .background(Color(nsColor: Ink.floor))
    }

    private var hero: some View {
        VStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(LinearGradient(colors: [Color(nsColor: Ink.raised), Color(nsColor: Ink.surface)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 76, height: 76)
                    .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(Color(nsColor: Ink.hairline)))
                WaveMark().frame(width: 41, height: 34)
            }
            .padding(.bottom, 4)
            Text("A CLEAR SPACE TO BUILD")
                .font(.system(size: 9, weight: .semibold))
                .tracking(2.1)
                .foregroundStyle(Color(nsColor: Ink.muted))
            Text("Your next idea\nstarts here.")
                .font(.system(size: 35, weight: .semibold))
                .tracking(-1.3)
                .lineSpacing(-2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Launch an agent, open a terminal, or start a browser. Keep your whole workspace in view.")
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: Ink.muted))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 375)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            KeyboardHint(keys: keys)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Color(nsColor: Ink.faint))
                .fixedSize()
        }
    }
}

private struct StartButton: View {
    let kind: SessionKind
    let prominent: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { kind == .codex ? Palette.accent : (kind.isAgent ? kind.tint : Color(nsColor: Ink.muted)) }
    private var description: String {
        switch kind {
        case .claude: return "Think, build, and iterate"
        case .codex: return "Turn ideas into working code"
        case .shell: return "Run commands"
        case .server: return "Start a service"
        case .browser: return "Open the web"
        }
    }

    var body: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.newSessionOfKind(_:)), to: nil, from: KindSender(kind: kind))
        } label: {
            Group {
                if prominent {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack {
                            AgentAvatar(kind: kind, state: .idle)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(hovering ? tint : Color(nsColor: Ink.faint))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(kind.displayName).font(.system(size: 14, weight: .semibold))
                            Text(description)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color(nsColor: Ink.muted))
                                .lineLimit(2)
                        }
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tint)
                        Text(kind.displayName)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
            }
            .foregroundStyle(Color(nsColor: Ink.text))
            .background(hovering ? Color(nsColor: Ink.raised) : Color(nsColor: Ink.surface), in: RoundedRectangle(cornerRadius: prominent ? 14 : 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: prominent ? 14 : 9, style: .continuous).strokeBorder(hovering ? tint.opacity(0.5) : Color(nsColor: Ink.hairline)))
            .contentShape(RoundedRectangle(cornerRadius: prominent ? 14 : 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        .help("Start a new \(kind.displayName) session")
        .accessibilityLabel("Start \(kind.displayName)")
        .accessibilityHint(description)
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
