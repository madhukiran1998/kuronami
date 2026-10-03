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

// Graphite: a slight lift toward the top, nothing tinted.
NSGradient(colors: [NSColor(srgbRed: 0.125, green: 0.125, blue: 0.137, alpha: 1),
                    NSColor(srgbRed: 0.043, green: 0.043, blue: 0.047, alpha: 1)])!
    .draw(in: body, angle: -90)

/// A true sine across the mark, so the wave reads as one clean stroke at every size.
func wave(centerY: CGFloat, amplitude: CGFloat, from x0: CGFloat, to x1: CGFloat, periods: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 240
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let x = x0 + (x1 - x0) * t
        let y = centerY + amplitude * sin(t * periods * 2 * .pi)
        step == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

let ink = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
let echo = wave(centerY: 410, amplitude: 46, from: 262, to: 762, periods: 1.5)
echo.lineWidth = 30
ink.withAlphaComponent(0.26).setStroke()
echo.stroke()

let crest = wave(centerY: 540, amplitude: 70, from: 240, to: 784, periods: 1.5)
crest.lineWidth = 54
ink.setStroke()
crest.stroke()

// The one color: the same blue that means "working" in the app.
NSColor(srgbRed: 0.357, green: 0.549, blue: 1.0, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 716, y: 700, width: 64, height: 64)).fill()

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
