import AppKit
import SwiftUI

/// The app icon, for the organizer's button: its own bone ground, vermilion sun and Tako
/// (`scripts/make-icon.sh` renders them to Resources/Mark from docs/brand), so the sun can
/// move behind Tako. It rests still while the organizer waits, rises and sets while it works,
/// and glows when it needs you. Only working loops, so an idle window never redraws for it, and
/// Reduce Motion holds it still.
struct KuronamiMark: NSViewRepresentable {
    enum Mood: Equatable { case resting, working, needsYou }

    var mood: Mood

    func makeNSView(context: Context) -> MarkView { MarkView() }

    func updateNSView(_ view: MarkView, context: Context) { view.mood = mood }

    final class MarkView: NSView {
        private let ground = CALayer()
        private let sun = CALayer()
        private let tako = CALayer()
        private let rim = CAShapeLayer()
        private let circleMask = CAShapeLayer()
        private var laidOutBox = CGRect.zero

        var mood: Mood = .resting {
            didSet { if mood != oldValue { animate() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for (layer, name) in [(ground, "ground"), (sun, "sun"), (tako, "tako")] {
                layer.contents = Self.image(name)
                layer.contentsGravity = .resizeAspect
                self.layer?.addSublayer(layer)
            }
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
            for layer in [ground, sun, tako] { layer.frame = box }
            let circle = CGPath(ellipseIn: box, transform: nil)
            circleMask.path = circle
            rim.path = circle
            CATransaction.commit()
            animate()
        }

        @objc private func motionPreferenceChanged() { animate() }

        private func animate() {
            sun.removeAllAnimations()
            sun.shadowOpacity = 0
            let side = sun.bounds.height
            guard !Motion.reduced, side > 0 else { return }
            switch mood {
            case .resting:
                break
            case .working:
                sun.add(Self.loop("transform.translation.y", from: -side * 0.18, to: side * 0.06, period: 1.6), forKey: "rise")
            case .needsYou:
                // The sun's own shape glows; the button's circle clips the outer edge of it.
                sun.shadowColor = Ink.accent.cgColor
                sun.shadowOffset = .zero
                // Held, not pulsed: an animated shadow re-renders offscreen every frame.
                sun.shadowRadius = side * 0.1
                sun.shadowOpacity = 1
            }
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
