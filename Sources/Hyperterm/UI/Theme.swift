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

@MainActor
enum ChromeColors {
    static var chrome: Color { Color(nsColor: Theme.chrome) }
    static var hairline: Color { Color(nsColor: Theme.hairline) }
    static var tileHeader: Color { Color(nsColor: Theme.tileHeader) }
}

enum Palette {
    static let working = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let attention = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let failed = Color(red: 1.0, green: 0.36, blue: 0.33)
    static let running = Color(red: 0.30, green: 0.80, blue: 0.50)
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

extension SessionKind {
    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "hexagon"
        case .shell: return "terminal"
        case .server: return "bolt.horizontal"
        case .browser: return "globe"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Palette.claude
        case .codex: return Palette.codex
        case .shell: return .secondary
        case .server: return Palette.running
        case .browser: return Palette.working
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
