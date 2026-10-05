import AppKit
import SwiftUI

/// The app icon in miniature, for the organizer's button: a vermilion sun behind the bone wave,
/// on black. It moves with the organizer so it reads as something alive: the sun breathes while
/// it waits, the wave rocks while it works, and the sun pulses when it needs you. Core Animation
/// runs the loops in the render server, so they cost Kuronami next to nothing, and Reduce Motion
/// holds it still.
struct KuronamiMark: NSViewRepresentable {
    enum Mood: Equatable { case resting, working, needsYou }

    var mood: Mood

    func makeNSView(context: Context) -> MarkView { MarkView() }

    func updateNSView(_ view: MarkView, context: Context) { view.mood = mood }

    final class MarkView: NSView {
        private let ground = CAShapeLayer()
        private let sun = CAShapeLayer()
        private let wave = CAShapeLayer()

        var mood: Mood = .resting {
            didSet { if mood != oldValue { animate() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            ground.fillColor = Ink.floor.cgColor
            ground.strokeColor = Ink.hairline.cgColor
            ground.lineWidth = Size.hairline * 2
            sun.fillColor = Ink.accent.cgColor
            wave.fillColor = Ink.text.cgColor
            for shape in [ground, sun, wave] { layer?.addSublayer(shape) }
            NotificationCenter.default.addObserver(self, selector: #selector(motionPreferenceChanged),
                                                   name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: NSWorkspace.shared.notificationCenter)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            let side = min(bounds.width, bounds.height)
            let box = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ground.path = CGPath(ellipseIn: box, transform: nil)
            let mask = CAShapeLayer()
            mask.path = ground.path
            layer?.mask = mask
            // Each shape spins and scales about its own centre.
            let sunRect = CGRect(x: box.minX + side * 0.52, y: box.minY + side * 0.56, width: side * 0.34, height: side * 0.34)
            sun.frame = sunRect
            sun.path = CGPath(ellipseIn: CGRect(origin: .zero, size: sunRect.size), transform: nil)
            wave.frame = box
            wave.path = Self.wavePath(in: CGRect(origin: .zero, size: box.size))
            CATransaction.commit()
            animate()
        }

        @objc private func motionPreferenceChanged() { animate() }

        private func animate() {
            sun.removeAllAnimations()
            wave.removeAllAnimations()
            guard !Motion.reduced, bounds.width > 0 else { return }
            switch mood {
            case .resting:
                sun.add(Self.loop("transform.scale", from: 0.94, to: 1.04, period: 4.5), forKey: "breathe")
                sun.add(Self.loop("opacity", from: 0.82, to: 1, period: 4.5), forKey: "glow")
            case .working:
                wave.add(Self.loop("transform.rotation.z", from: -0.14, to: 0.14, period: 0.9), forKey: "rock")
                sun.add(Self.loop("transform.scale", from: 0.9, to: 1.06, period: 0.9), forKey: "breathe")
            case .needsYou:
                sun.add(Self.loop("transform.scale", from: 0.86, to: 1.16, period: 0.6), forKey: "breathe")
                sun.add(Self.loop("opacity", from: 0.7, to: 1, period: 0.6), forKey: "glow")
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

        /// The icon's curl (scripts/make-icon.swift) at button size: a tail along the bottom that
        /// sweeps up the right, over the top, and spirals in, thick in the middle and thin at the ends.
        private static func wavePath(in box: CGRect) -> CGPath {
            let side = box.width
            let center = CGPoint(x: box.minX + side * 0.5, y: box.minY + side * 0.5)
            let radius = side * 0.3
            let turns: CGFloat = 1.92, shrink: CGFloat = 0.62
            var points: [CGPoint] = []
            for i in 0...20 {
                let t = CGFloat(i) / 20
                points.append(CGPoint(x: center.x - radius * 1.15 + radius * 1.15 * t, y: center.y - radius - side * 0.02 * sin(t * .pi)))
            }
            for i in 1...120 {
                let t = CGFloat(i) / 120
                let theta = -CGFloat.pi / 2 + t * turns * .pi
                let r = radius * (1 - shrink * pow(t, 1.15))
                points.append(CGPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta) * 0.96))
            }
            func width(_ t: CGFloat) -> CGFloat {
                let start = min(1, t / 0.12), end = min(1, (1 - t) / 0.35)
                return side * 0.15 * pow(max(0, start), 0.7) * pow(max(0, end), 0.9) + side * 0.01
            }
            var left: [CGPoint] = [], right: [CGPoint] = []
            for i in points.indices {
                let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
                let dx = b.x - a.x, dy = b.y - a.y, length = max(0.001, sqrt(dx * dx + dy * dy))
                let normal = CGPoint(x: -dy / length, y: dx / length)
                let half = width(CGFloat(i) / CGFloat(points.count - 1)) / 2
                left.append(CGPoint(x: points[i].x + normal.x * half, y: points[i].y + normal.y * half))
                right.append(CGPoint(x: points[i].x - normal.x * half, y: points[i].y - normal.y * half))
            }
            let path = CGMutablePath()
            path.addLines(between: left + right.reversed())
            path.closeSubpath()
            return path
        }
    }
}
