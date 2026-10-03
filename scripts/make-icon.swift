// Renders Resources/AppIcon.icns: Kuronami, a black wave.
// Run from the repository root: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Big Sur icon grid: 824pt body centered, continuous corners.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.4).cgColor)
NSColor(srgbRed: 0.043, green: 0.043, blue: 0.047, alpha: 1).setFill()
shape.fill()
ctx.restoreGState()
shape.addClip()

// Graphite sky, lighter toward the top so the black wave stands out against it.
NSGradient(colors: [NSColor(srgbRed: 0.27, green: 0.27, blue: 0.29, alpha: 1),
                    NSColor(srgbRed: 0.15, green: 0.15, blue: 0.165, alpha: 1)])!
    .draw(in: body, angle: -90)

/// A swell: a filled band whose top edge is a sine, so layers stack like distant water.
func swell(baseline: CGFloat, amplitude: CGFloat, periods: CGFloat, phase: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 0, y: 0))
    for step in 0...200 {
        let t = CGFloat(step) / 200
        path.line(to: NSPoint(x: size * t, y: baseline + amplitude * sin((t * periods + phase) * 2 * .pi)))
    }
    path.line(to: NSPoint(x: size, y: 0))
    path.close()
    return path
}
NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
swell(baseline: 330, amplitude: 22, periods: 1.4, phase: 0.2).fill()

// The wave (黒波): its face rises from the right and curls over to the left around a hollow.
// Built from arcs so the spiral stays clean; it runs past the icon edge so the rim stroke
// only shows along the crest.
let center = NSPoint(x: 500, y: 590)
func onCircle(_ radius: CGFloat, _ degrees: CGFloat) -> NSPoint {
    NSPoint(x: center.x + radius * cos(degrees * .pi / 180), y: center.y + radius * sin(degrees * .pi / 180))
}
let wave = NSBezierPath()
wave.move(to: NSPoint(x: 1024, y: -20))
wave.line(to: NSPoint(x: 1024, y: 250))
wave.curve(to: onCircle(200, 0), controlPoint1: NSPoint(x: 820, y: 270), controlPoint2: NSPoint(x: 700, y: 420))
wave.appendArc(withCenter: center, radius: 200, startAngle: 0, endAngle: 205, clockwise: false)
// The lip: a rounded tip, then back along the inside of the curl.
let tip = onCircle(200, 205), inner = onCircle(104, 205)
wave.curve(to: inner, controlPoint1: NSPoint(x: tip.x - 10, y: tip.y - 70), controlPoint2: NSPoint(x: inner.x - 20, y: inner.y - 60))
wave.appendArc(withCenter: center, radius: 104, startAngle: 205, endAngle: -35, clockwise: true)
wave.curve(to: NSPoint(x: -20, y: 230), controlPoint1: NSPoint(x: 520, y: 380), controlPoint2: NSPoint(x: 240, y: 250))
wave.line(to: NSPoint(x: -20, y: -20))
wave.close()
NSGradient(colors: [NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1),
                    NSColor(srgbRed: 0.015, green: 0.015, blue: 0.02, alpha: 1)])!
    .draw(in: wave, angle: -90)
wave.lineWidth = 16
wave.lineJoinStyle = .round
NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1).setStroke()
wave.stroke()

// The one color: a cursor block in the "working" blue, waiting inside the curl.
NSColor(srgbRed: 0.357, green: 0.549, blue: 1.0, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: center.x - 24, y: center.y - 40, width: 48, height: 80), xRadius: 8, yRadius: 8).fill()

// A hairline rim.
NSColor.white.withAlphaComponent(0.08).setStroke()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
rim.lineWidth = 4
rim.stroke()
image.unlockFocus()

// Master PNG, then every size the .icns needs.
let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
let master = URL(fileURLWithPath: "build/icon-1024.png")
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try png.write(to: master)

func run(_ path: String, _ args: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"])
print("Resources/AppIcon.icns")
