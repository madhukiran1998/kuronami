// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Big Sur icon grid: 824pt body centered, continuous corners.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(srgbRed: 0.08, green: 0.085, blue: 0.10, alpha: 1).setFill()
shape.fill()
ctx.restoreGState()

shape.addClip()
let gradient = NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 1),
                                   NSColor(srgbRed: 0.07, green: 0.075, blue: 0.09, alpha: 1)])!
gradient.draw(in: body, angle: -90)
NSColor.white.withAlphaComponent(0.08).setStroke()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
rim.lineWidth = 4
rim.stroke()

// Prompt chevron + cursor.
let ink = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 268, y: 618))
chevron.line(to: NSPoint(x: 430, y: 500))
chevron.line(to: NSPoint(x: 268, y: 382))
chevron.lineWidth = 58
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
ink.setStroke()
chevron.stroke()
ink.withAlphaComponent(0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: 486, y: 352, width: 236, height: 58), xRadius: 29, yRadius: 29).fill()

// Three agents: working, waiting on you, running.
let dots: [(NSColor, CGFloat)] = [
    (NSColor(srgbRed: 0.36, green: 0.62, blue: 1.0, alpha: 1), 560),
    (NSColor(srgbRed: 1.0, green: 0.62, blue: 0.20, alpha: 1), 652),
    (NSColor(srgbRed: 0.30, green: 0.80, blue: 0.50, alpha: 1), 744),
]
for (color, x) in dots {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - 34, y: 700 - 34, width: 68, height: 68)).fill()
}
image.unlockFocus()

let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
let master = URL(fileURLWithPath: "build/icon-1024.png")
try FileManager.default.createDirectory(at: master.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: master)
print(master.path)
