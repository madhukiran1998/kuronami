import AppKit
import GhosttyKit
import SwiftUI

// The design system. Every size, space, radius, color and motion in the interface comes from
// here; `scripts/lint-design.sh` fails the build check on raw values anywhere else.
//
// Principles:
// - Six text styles. Hierarchy comes from weight and color before size.
// - A 4-point grid. Three corner radii: controls, rows, panes.
// - Neutral graphite. Color only ever means something: an agent's state, where focus is, or
//   which agent it is. Nothing is tinted for decoration.
// - One motion curve, and none at all with Reduce Motion.

// MARK: - Type

enum Typeface {
    /// Empty states and sheet titles.
    static let title = Font.system(size: 17, weight: .semibold)
    /// Names: a session's label, a section's subject.
    static let headline = Font.system(size: 13, weight: .semibold)
    /// Running text and controls.
    static let body = Font.system(size: 13)
    /// Secondary lines under a headline.
    static let callout = Font.system(size: 12)
    /// Metadata, section headers, help text.
    static let caption = Font.system(size: 11)
    /// Badges, key caps, counts.
    static let micro = Font.system(size: 10, weight: .medium)

    /// Code, commands, paths, diffs.
    static let code = Font.system(size: 12, design: .monospaced)
    static let codeSmall = Font.system(size: 11, design: .monospaced)

    static let codeNS = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

// MARK: - Space and shape

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    /// Key caps, chips, small controls.
    static let control: CGFloat = 5
    /// Rows, fields, buttons, bubbles.
    static let row: CGFloat = 8
    /// Tiles, panels, popovers.
    static let pane: CGFloat = 12
}

enum Size {
    /// Tile headers and the canvas strip.
    static let barHeight: CGFloat = 30
    /// Icon-only buttons.
    static let iconButton: CGFloat = 22
    static let statusDot: CGFloat = 7
    static let avatar: CGFloat = 22
    static let hairline: CGFloat = 1
}

// MARK: - Color

/// Opaque graphite layers, darkest at the back. AppKit colors for layers and windows.
enum Ink {
    /// Window and canvas: the deepest layer.
    static let floor = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1)
    /// Sidebar and inspector.
    static let deep = NSColor(srgbRed: 0.071, green: 0.071, blue: 0.082, alpha: 1)
    /// Fields, cards, bars.
    static let surface = NSColor(srgbRed: 0.106, green: 0.106, blue: 0.118, alpha: 1)
    /// Hover and selection.
    static let raised = NSColor(srgbRed: 0.149, green: 0.149, blue: 0.165, alpha: 1)
    static let hairline = NSColor(srgbRed: 0.176, green: 0.176, blue: 0.196, alpha: 1)
    static let text = NSColor(srgbRed: 0.949, green: 0.949, blue: 0.961, alpha: 1)
    static let muted = NSColor(srgbRed: 0.631, green: 0.631, blue: 0.659, alpha: 1)
    static let faint = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.451, alpha: 1)
    /// Focus and selection. Shared with "working" on purpose: blue always means "this one, live".
    static let accent = NSColor(srgbRed: 0.357, green: 0.549, blue: 1.0, alpha: 1)
}

/// The same layers for SwiftUI.
enum Tone {
    static let floor = Color(nsColor: Ink.floor)
    static let deep = Color(nsColor: Ink.deep)
    static let surface = Color(nsColor: Ink.surface)
    static let raised = Color(nsColor: Ink.raised)
    static let hairline = Color(nsColor: Ink.hairline)
    static let text = Color(nsColor: Ink.text)
    static let muted = Color(nsColor: Ink.muted)
    static let faint = Color(nsColor: Ink.faint)
}

/// Meaning. These are the only saturated colors in the app.
enum Palette {
    static let accent = Color(nsColor: Ink.accent)
    /// An agent at work, and focus.
    static let working = Color(nsColor: Ink.accent)
    /// Something needs you.
    static let attention = Color(nsColor: NSColor(srgbRed: 0.961, green: 0.647, blue: 0.141, alpha: 1))
    static let failed = Color(nsColor: NSColor(srgbRed: 0.949, green: 0.333, blue: 0.353, alpha: 1))
    /// Live servers, passing tests, added lines.
    static let running = Color(nsColor: NSColor(srgbRed: 0.247, green: 0.812, blue: 0.557, alpha: 1))
    static let idle = Tone.faint
    /// Which agent it is: used only on the agent's own mark.
    static let claude = Color(nsColor: NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1))
    static let codex = Color(nsColor: NSColor(srgbRed: 0.62, green: 0.65, blue: 1.0, alpha: 1))

    static func status(_ state: AgentState) -> Color {
        switch state {
        case .working, .starting: return working
        case .needsInput: return attention
        case .failed: return failed
        case .running: return running
        case .idle: return idle
        case .exited: return Tone.faint.opacity(0.5)
        }
    }
}

/// The terminal's own colors, from the user's Ghostty theme, for surfaces that show terminal
/// content (diffs, previews) so they read as part of the terminal.
@MainActor
enum Theme {
    static private(set) var terminalBackground = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    static private(set) var terminalForeground = NSColor(white: 0.9, alpha: 1)

    static func load(from config: ghostty_config_t?) {
        guard let config else { return }
        if let bg = color(config, "background") { terminalBackground = bg }
        if let fg = color(config, "foreground") { terminalForeground = fg }
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var value = ghostty_config_color_s()
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255, blue: CGFloat(value.b) / 255, alpha: 1)
    }
}

// MARK: - Motion

enum Motion {
    static let standard: TimeInterval = 0.2
    static let quick: TimeInterval = 0.12

    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @MainActor static func duration(_ base: TimeInterval) -> TimeInterval { reduced ? 0 : base }

    static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)

    /// SwiftUI: pass the view's `accessibilityReduceMotion`.
    static func animation(_ reduceMotion: Bool, _ base: TimeInterval = standard) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: base)
    }
}

// MARK: - Materials

extension View {
    /// Floating surfaces (the command palette, find bar, recap) are Liquid Glass on macOS 26
    /// when built with its SDK, and solid graphite otherwise.
    @ViewBuilder func floatingSurface(cornerRadius: CGFloat = Radius.pane, fallback: Color = Tone.surface) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        #else
        self.background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }
}

// MARK: - Components

/// A key cap: "⌘N".
struct KeyboardHint: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(Typeface.micro.monospaced())
            .foregroundStyle(Tone.faint)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(Tone.raised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .fixedSize()
            .accessibilityLabel(keys)
    }
}

/// A plain section heading, in sentence case, the way Apple's sidebars and inspectors title
/// their groups.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Text(title).font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.muted).lineLimit(1)
            Spacer(minLength: Space.xs)
            trailing().font(Typeface.caption).foregroundStyle(Tone.faint)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Buttons in panels: a quiet fill that deepens on press. `prominent` is the one primary action.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(label: configuration.label, pressed: configuration.isPressed, prominent: prominent, tint: tint)
    }
}

private struct PanelButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let prominent: Bool
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        label
            .font(Typeface.callout.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? Tone.floor : Tone.text)
            .padding(.horizontal, Space.m)
            .frame(minHeight: 26)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        if prominent { return tint.opacity(pressed ? 0.75 : hovering ? 0.9 : 1) }
        return pressed ? Tone.hairline : hovering ? Tone.raised : Tone.surface
    }
}

/// Kept for call sites that predate the panel style.
typealias ChromeButtonStyle = PanelButtonStyle

/// An icon-only button that shows its fill only on hover, like a toolbar button.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Tone.muted
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typeface.caption.weight(.semibold))
                .foregroundStyle(hovering ? Tone.text : tint)
                .frame(width: Size.iconButton, height: Size.iconButton)
                .background(hovering ? Tone.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A session's state as a dot: filled while something is happening, ringed while it needs you.
struct StatusDot: View {
    let state: AgentState
    var size: CGFloat = Size.statusDot

    var body: some View {
        Circle()
            .fill(Palette.status(state))
            .frame(width: size, height: size)
            .overlay {
                if state.needsAttention {
                    Circle().strokeBorder(Palette.attention.opacity(0.35), lineWidth: 2)
                        .frame(width: size + Space.xs + 1, height: size + Space.xs + 1)
                }
            }
            .frame(width: size + Space.xs + 1, height: size + Space.xs + 1)
            .accessibilityLabel(state.phrase)
    }
}

/// A small rounded tag: "+128 −41", ":5173", "3 queued".
struct Tag: View {
    let text: String
    var tint: Color = Tone.muted
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? Typeface.micro.monospaced() : Typeface.micro)
            .foregroundStyle(tint)
            .padding(.horizontal, Space.xs + 1)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .lineLimit(1)
            .fixedSize()
    }
}

/// "+128 −41" in the diff colors.
struct DiffCount: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            Text("+\(added)").foregroundStyle(Palette.running)
            Text("−\(removed)").foregroundStyle(Palette.failed)
        }
        .font(Typeface.micro.monospacedDigit())
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

/// A centered message for an empty panel.
struct EmptyMessage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(Typeface.title.weight(.light))
                .foregroundStyle(Tone.faint)
                .padding(.bottom, Space.xs)
            Text(title).font(Typeface.headline).foregroundStyle(Tone.text)
            Text(detail)
                .font(Typeface.callout)
                .foregroundStyle(Tone.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.xxl + Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A thin rule between regions.
struct Hairline: View {
    var body: some View { Rectangle().fill(Tone.hairline).frame(height: Size.hairline) }
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

/// One glyph language everywhere: agents are monograms (C, X), everything else a plain symbol.
struct KindMark: View {
    let kind: SessionKind
    var font: Font = Typeface.caption

    var body: some View {
        if let letter = kind.monogram {
            Text(letter).font(font.weight(.bold)).fontDesign(.rounded)
        } else {
            Image(systemName: kind.symbol).font(font.weight(.medium))
        }
    }
}

/// The agent's mark in its own color on a quiet square. State is shown by the dot beside it,
/// so the mark never changes color.
struct AgentAvatar: View {
    let kind: SessionKind
    var dimmed = false

    var body: some View {
        KindMark(kind: kind)
            .foregroundStyle(kind.tint.opacity(dimmed ? 0.45 : 1))
            .frame(width: Size.avatar, height: Size.avatar)
            .background(Tone.surface, in: RoundedRectangle(cornerRadius: Radius.control + 1, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon tight against its title, as in Finder's status bars.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs - 1) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Vocabulary

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
        case .shell, .server, .browser: return Tone.muted
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
