import AppKit
import SwiftUI

/// The app icon, for the organizer's button: its own black ground, vermilion sun and brushed
/// wave (`swift scripts/make-icon.swift --mark` renders them to Resources/Mark), so the sun can
/// move behind the wave. It drifts while the organizer waits, rises and sets while it works, and
/// glows when it needs you. Core Animation runs the loops in the render server, so they cost
/// Kuronami next to nothing, and Reduce Motion holds it still.
struct KuronamiMark: NSViewRepresentable {
    enum Mood: Equatable { case resting, working, needsYou }

    var mood: Mood

    func makeNSView(context: Context) -> MarkView { MarkView() }

    func updateNSView(_ view: MarkView, context: Context) { view.mood = mood }

    final class MarkView: NSView {
        private let ground = CALayer()
        private let sun = CALayer()
        private let wave = CALayer()
        private let rim = CAShapeLayer()

        var mood: Mood = .resting {
            didSet { if mood != oldValue { animate() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for (layer, name) in [(ground, "ground"), (sun, "sun"), (wave, "wave")] {
                layer.contents = Self.image(name)
                layer.contentsGravity = .resizeAspect
                self.layer?.addSublayer(layer)
            }
            rim.fillColor = nil
            rim.strokeColor = Ink.hairline.cgColor
            rim.lineWidth = Size.hairline * 2
            layer?.addSublayer(rim)
            NotificationCenter.default.addObserver(self, selector: #selector(motionPreferenceChanged),
                                                   name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: NSWorkspace.shared.notificationCenter)
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [ground, sun, wave] { layer.frame = box }
            let circle = CGPath(ellipseIn: box, transform: nil)
            let mask = CAShapeLayer()
            mask.path = circle
            layer?.mask = mask
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
                sun.add(Self.loop("transform.translation.y", from: -side * 0.03, to: side * 0.02, period: 6), forKey: "drift")
            case .working:
                sun.add(Self.loop("transform.translation.y", from: -side * 0.18, to: side * 0.06, period: 1.6), forKey: "rise")
            case .needsYou:
                // The sun's own shape glows; the button's circle clips the outer edge of it.
                sun.shadowColor = Ink.accent.cgColor
                sun.shadowOffset = .zero
                sun.shadowOpacity = 1
                sun.add(Self.loop("shadowRadius", from: side * 0.02, to: side * 0.14, period: 1.2), forKey: "glow")
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
