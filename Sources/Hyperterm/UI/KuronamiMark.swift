import AppKit
import SwiftUI

/// The app icon, for Sumi's button: its own bone ground, vermilion sun and Tako
/// (`scripts/make-icon.sh` renders them to Resources/Mark from docs/brand), so the sun can
/// move behind Tako. It rests still while Sumi waits, rises and sets while it works,
/// and fills with the sun's vermilion when it needs you. Only working loops, so an idle window
/// never redraws for it, and Reduce Motion holds it still.
struct KuronamiMark: NSViewRepresentable {
    enum Mood: Equatable { case resting, working, needsYou }

    var mood: Mood

    /// Sumi's look: blocked on you always shows; an unseen reply only while its panel is closed.
    static func sumiMood(_ state: AgentState, unread: Bool, isOpen: Bool) -> Mood {
        switch state {
        case .working, .starting: return .working
        case .needsInput: return .needsYou
        default: return unread && !isOpen ? .needsYou : .resting
        }
    }

    func makeNSView(context: Context) -> MarkView { MarkView() }

    func updateNSView(_ view: MarkView, context: Context) { view.mood = mood }

    final class MarkView: NSView {
        private let ground = CALayer()
        private let sun = CALayer()
        private let tako = CALayer()
        /// The sun's vermilion spreading over the whole button while it needs you.
        private let flood = CAShapeLayer()
        private let rim = CAShapeLayer()
        private let circleMask = CAShapeLayer()
        private var laidOutBox = CGRect.zero

        var mood: Mood = .resting {
            didSet { if mood != oldValue { animate(from: oldValue) } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for (layer, name) in [(ground, "ground"), (sun, "sun"), (tako, "tako")] {
                layer.contents = Self.image(name)
                layer.contentsGravity = .resizeAspect
                self.layer?.addSublayer(layer)
            }
            flood.fillColor = Ink.accent.cgColor
            layer?.insertSublayer(flood, below: tako)
            rim.fillColor = nil
            rim.strokeColor = Ink.hairline.cgColor
            rim.lineWidth = Size.hairline * 2
            layer?.addSublayer(rim)
            layer?.mask = circleMask
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged),
                                                              name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                              object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private static func image(_ name: String) -> CGImage? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Mark"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        override func layout() {
            super.layout()
            let side = min(bounds.width, bounds.height)
            let box = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            guard box != laidOutBox else { return }
            laidOutBox = box
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [ground, sun, flood, tako] { layer.frame = box }
            let circle = CGPath(ellipseIn: box, transform: nil)
            circleMask.path = circle
            rim.path = circle
            CATransaction.commit()
            animate(from: nil)
        }

        @objc private func motionPreferenceChanged() { animate(from: nil) }

        /// Where the sun sits in the artwork (192 px square, y down), as a fraction of the side.
        private static let sunCenter = CGPoint(x: 144.0 / 192, y: 49.0 / 192)
        private static let sunRadius: CGFloat = 31.0 / 192

        /// A circle around the sun, in the flood layer's own (y-up) coordinates.
        private func floodPath(radius fraction: CGFloat) -> CGPath {
            let side = flood.bounds.height
            let center = CGPoint(x: side * Self.sunCenter.x, y: side * (1 - Self.sunCenter.y))
            let radius = side * fraction
            return CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                          transform: nil)
        }

        /// `previous` is the mood being left; nil means set the final look at once (first layout,
        /// a changed motion preference).
        private func animate(from previous: Mood?) {
            sun.removeAllAnimations()
            tako.removeAllAnimations()
            flood.removeAllAnimations()
            let side = sun.bounds.height
            guard side > 0 else { return }

            // Needing you is the sun's vermilion over the whole circle, held still. It spreads out
            // from the sun, then Tako settles on it once; leaving it draws back into the sun.
            let filled = mood == .needsYou
            let from = floodPath(radius: filled ? 0 : 1.1)
            let to = floodPath(radius: filled ? 1.1 : 0)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            flood.path = to
            CATransaction.commit()
            if !Motion.reduced, let previous, (previous == .needsYou) != filled {
                let spread = CABasicAnimation(keyPath: "path")
                spread.fromValue = from
                spread.toValue = to
                spread.duration = filled ? 0.55 : 0.35
                spread.timingFunction = Motion.curve
                flood.add(spread, forKey: "spread")
                if filled {
                    let settle = CAKeyframeAnimation(keyPath: "transform.scale")
                    settle.values = [1, 1.08, 1]
                    settle.keyTimes = [0, 0.5, 1]
                    settle.duration = 0.35
                    settle.beginTime = CACurrentMediaTime() + 0.4
                    settle.fillMode = .backwards
                    settle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    tako.add(settle, forKey: "settle")
                }
            }

            guard !Motion.reduced, mood == .working else { return }
            sun.add(Self.loop("transform.translation.y", from: -side * 0.18, to: side * 0.06, period: 1.6), forKey: "rise")
        }

        private static func loop(_ keyPath: String, from: CGFloat, to: CGFloat, period: CFTimeInterval) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = period / 2
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return animation
        }
    }
}
