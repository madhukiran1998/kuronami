import AppKit
import GhosttyKit
import SwiftUI

/// Chrome colors derived from the user's Ghostty theme so the app and its terminals read as one
/// surface instead of a dark terminal floating in system grey.
@MainActor
enum Theme {
    static private(set) var terminalBackground = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    static private(set) var terminalForeground = NSColor(white: 0.9, alpha: 1)

    static func load(from config: ghostty_config_t?) {
        guard let config else { return }
        if let bg = color(config, "background") { terminalBackground = bg }
        if let fg = color(config, "foreground") { terminalForeground = fg }
    }

    static var isDark: Bool { terminalBackground.luminance < 0.5 }

    /// Sidebar + toolbar: one surface, a single step off the terminal color.
    static var chrome: NSColor { terminalBackground.adjusted(by: isDark ? 0.045 : -0.035) }
    /// Behind and between tiles.
    static var canvas: NSColor { terminalBackground.adjusted(by: isDark ? -0.02 : -0.05) }
    static var tileHeader: NSColor { terminalBackground.adjusted(by: isDark ? 0.025 : -0.02) }
    static var hairline: NSColor { NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.08 : 0.1) }
    static var focusRing: NSColor { NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.24 : 0.3) }

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var value = ghostty_config_color_s()
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255, blue: CGFloat(value.b) / 255, alpha: 1)
    }
}

/// Opaque, cool graphite layers. Semantic color is reserved for focus and session state.
enum Ink {
    /// Window and canvas: the deepest layer.
    static let floor = NSColor(srgbRed: 0.035, green: 0.039, blue: 0.055, alpha: 1)
    /// Sidebar and inspector.
    static let deep = NSColor(srgbRed: 0.055, green: 0.059, blue: 0.078, alpha: 1)
    /// Cards, fields, bars.
    static let surface = NSColor(srgbRed: 0.080, green: 0.086, blue: 0.110, alpha: 1)
    /// Selected rows, active segments.
    static let raised = NSColor(srgbRed: 0.115, green: 0.122, blue: 0.157, alpha: 1)
    static let hairline = NSColor(srgbRed: 0.170, green: 0.184, blue: 0.231, alpha: 1)
    static let text = NSColor(srgbRed: 0.91, green: 0.93, blue: 0.98, alpha: 1)
    static let muted = NSColor(srgbRed: 0.59, green: 0.63, blue: 0.72, alpha: 1)
    static let faint = NSColor(srgbRed: 0.40, green: 0.44, blue: 0.53, alpha: 1)
    static let accent = NSColor(srgbRed: 0.64, green: 0.66, blue: 1, alpha: 1)
}

@MainActor
enum ChromeColors {
    static var chrome: Color { Color(nsColor: Theme.chrome) }
    static var hairline: Color { Color(nsColor: Theme.hairline) }
    static var tileHeader: Color { Color(nsColor: Theme.tileHeader) }
}

enum Palette {
    static let accent = Color(nsColor: Ink.accent)
    /// An agent at work, and focus.
    static let working = Color(red: 0.357, green: 0.549, blue: 1.0)
    /// Something needs you.
    static let attention = Color(red: 0.961, green: 0.647, blue: 0.141)
    static let failed = Color(red: 0.949, green: 0.333, blue: 0.353)
    static let running = Color(red: 0.247, green: 0.812, blue: 0.557)
    static let idle = Color.secondary.opacity(0.55)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.55, green: 0.60, blue: 1.0)

    static func status(_ state: AgentState) -> Color {
        switch state {
        case .working, .starting: return working
        case .needsInput: return attention
        case .failed: return failed
        case .running: return running
        case .idle: return idle
        case .exited: return Color.secondary.opacity(0.3)
        }
    }
}

/// Small, consistent keyboard hints used across the workspace and command palette.
struct KeyboardHint: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(nsColor: Ink.muted))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color(nsColor: Ink.raised), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Ink.hairline)))
            .fixedSize()
            .accessibilityLabel(keys)
    }
}

/// Shared button treatment: lightweight opaque fills with native keyboard focus behavior.
struct ChromeButtonStyle: ButtonStyle {
    var accent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent ? Color(nsColor: Ink.floor) : Color(nsColor: Ink.text))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(accent ? Palette.accent.opacity(configuration.isPressed ? 0.75 : 1)
                        : Color(nsColor: configuration.isPressed ? Ink.raised : Ink.surface),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(accent ? Color.clear : Color(nsColor: Ink.hairline)))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Kuronami's wave mark, drawn once with three cubic curves; no image assets or animation.
struct WaveMark: View {
    var body: some View {
        Canvas { context, size in
            for row in 0..<3 {
                let y = size.height * (0.28 + CGFloat(row) * 0.22)
                var path = Path()
                path.move(to: CGPoint(x: size.width * 0.08, y: y))
                path.addCurve(to: CGPoint(x: size.width * 0.92, y: y),
                              control1: CGPoint(x: size.width * 0.36, y: y - size.height * 0.36),
                              control2: CGPoint(x: size.width * 0.64, y: y + size.height * 0.36))
                context.stroke(path, with: .color(Palette.accent.opacity(1 - Double(row) * 0.2)),
                               style: StrokeStyle(lineWidth: max(1.4, size.width * 0.055), lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

extension SessionKind {
    var symbol: String {
        switch self {
        case .claude: return "c.square"
        case .codex: return "x.square"
        case .shell: return "terminal"
        case .server: return "bolt"
        case .browser: return "globe"
        }
    }

    /// Agents are drawn as a letter rather than a symbol.
    var monogram: String? {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        default: return nil
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Palette.claude
        case .codex: return Palette.codex
        case .shell, .server, .browser: return .secondary
        }
    }
}

extension AgentState {
    /// The one status vocabulary used everywhere: Working, Needs you, Done, Idle (+ Failed,
    /// Exited, Running for processes).
    var phrase: String {
        switch self {
        case .starting: return "Starting"
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .idle: return "Idle"
        case .failed: return "Failed"
        case .exited(let code): return code == 0 ? "Exited" : "Exit \(code)"
        case .running: return "Running"
        }
    }
}

extension TerminalSession {
    /// Idle after finishing a turn reads as "Done"; idle before any work reads as "Idle".
    var statusWord: String {
        if state == .idle, summary != nil || !timeline.isEmpty { return "Done" }
        return state.phrase
    }
}

extension NSColor {
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    func adjusted(by delta: CGFloat) -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        func clamp(_ value: CGFloat) -> CGFloat { min(max(value + delta, 0), 1) }
        return NSColor(srgbRed: clamp(rgb.redComponent), green: clamp(rgb.greenComponent), blue: clamp(rgb.blueComponent), alpha: 1)
    }
}

func elapsed(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86_400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86_400)d"
}

/// The canvas terminals float on: flat graphite.
final class InkCanvas: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Ink.floor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}
