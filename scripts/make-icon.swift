// Renders Resources/AppIcon.icns and docs/icon.png: Kuronami (黒波, "black wave").
// A brush-ink wave in the manner of a woodblock print: the crest curls over with Hokusai's
// claws of foam, in front of a vermilion sun, on black.
// Run from the repository root: swift scripts/make-icon.swift
import AppKit

let S: CGFloat = 1024
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bone = NSColor(srgbRed: 0.93, green: 0.90, blue: 0.83, alpha: 1)
let vermilion = NSColor(srgbRed: 0.80, green: 0.20, blue: 0.15, alpha: 1)

/// Deterministic noise so every render is identical.
var seed: UInt64 = 7
func rand() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }

/// A brush stroke: a filled outline around a centerline, its width following `width`.
func brush(_ points: [NSPoint], width: (CGFloat) -> CGFloat, color: NSColor, dry: NSColor? = nil) {
    guard points.count > 2 else { return }
    var left: [NSPoint] = [], right: [NSPoint] = []
    var normals: [NSPoint] = []
    for i in 0..<points.count {
        let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
        var dx = b.x - a.x, dy = b.y - a.y
        let len = max(0.001, sqrt(dx * dx + dy * dy)); dx /= len; dy /= len
        let n = NSPoint(x: -dy, y: dx); normals.append(n)
        let w = width(CGFloat(i) / CGFloat(points.count - 1)) / 2
        left.append(NSPoint(x: points[i].x + n.x * w, y: points[i].y + n.y * w))
        right.append(NSPoint(x: points[i].x - n.x * w, y: points[i].y - n.y * w))
    }
    let path = NSBezierPath()
    path.move(to: left[0]); left.dropFirst().forEach { path.line(to: $0) }
    right.reversed().forEach { path.line(to: $0) }
    path.close()
    color.setFill(); path.fill()
    // Dry brush: thin streaks of the ground color running along the stroke.
    guard let dry else { return }
    NSGraphicsContext.saveGraphicsState(); path.addClip()
    for _ in 0..<14 {
        let offset = (rand() - 0.5) * 0.9, start = Int(rand() * CGFloat(points.count) * 0.5) + points.count / 3
        let streak = NSBezierPath()
        for i in start..<points.count {
            let w = width(CGFloat(i) / CGFloat(points.count - 1)) / 2
            let p = NSPoint(x: points[i].x + normals[i].x * w * offset * 2, y: points[i].y + normals[i].y * w * offset * 2)
            i == start ? streak.move(to: p) : streak.line(to: p)
        }
        streak.lineWidth = 1.5 + rand() * 3; dry.withAlphaComponent(0.35 + rand() * 0.4).setStroke(); streak.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func taper(_ t: CGFloat, start: CGFloat = 0.12, end: CGFloat = 0.35) -> CGFloat {
    let a = min(1, t / start), b = min(1, (1 - t) / end)
    return pow(max(0, a), 0.7) * pow(max(0, b), 0.9)
}

let turns: CGFloat = 1.92, shrink: CGFloat = 0.62

/// The curl: a tail along the bottom that sweeps up the right, over the top, and spirals in.
func curlPoints(center c: NSPoint, radius r0: CGFloat) -> [NSPoint] {
    var pts: [NSPoint] = []
    for i in 0...40 { let t = CGFloat(i) / 40; pts.append(NSPoint(x: c.x - r0 * 1.15 + r0 * 1.15 * t, y: c.y - r0 - 18 * sin(t * .pi))) }
    for i in 1...260 {
        let t = CGFloat(i) / 260
        let theta = -CGFloat.pi / 2 + t * turns * .pi
        let r = r0 * (1 - shrink * pow(t, 1.15))
        pts.append(NSPoint(x: c.x + r * cos(theta), y: c.y + r * sin(theta) * 0.96))
    }
    return pts
}

/// Hokusai's claws: little hooked strokes hanging off the crest's leading edge.
func claws(center c: NSPoint, radius r0: CGFloat, color: NSColor) {
    // Along the crest from its top to where it falls: the outer edge of the spiral there.
    for (k, angle) in stride(from: 100.0, through: 196.0, by: 16.0).enumerated() {
        let a = CGFloat(angle) * .pi / 180
        let t = (a + .pi / 2) / (turns * .pi)
        let edge = r0 * (1 - shrink * pow(t, 1.15)) + 118 * taper(min(1, (t * 260 + 40) / 300)) / 2 - 8
        let base = NSPoint(x: c.x + edge * cos(a), y: c.y + edge * sin(a) * 0.96)
        let out = NSPoint(x: cos(a), y: sin(a) * 0.96)
        let size = 54 + CGFloat(k % 2) * 16
        var pts: [NSPoint] = [base]
        for i in 1...30 {
            let t = CGFloat(i) / 30
            // Out from the crest, then hooking back the way the wave turns.
            let bend = t * t * 2.1
            let dir = NSPoint(x: out.x * cos(bend) - out.y * sin(bend), y: out.x * sin(bend) + out.y * cos(bend))
            let last = pts.last!
            pts.append(NSPoint(x: last.x + dir.x * size / 30 * 1.5, y: last.y + dir.y * size / 30 * 1.5))
        }
        brush(pts, width: { t in 30 * (1 - t) + 1 }, color: color)
    }
}

/// Inner flow lines, like the carved lines inside a woodblock wave.
func flowLines(center c: NSPoint, radius r0: CGFloat, color: NSColor) {
    for (k, scale) in [CGFloat(0.78), 0.6].enumerated() {
        var pts: [NSPoint] = []
        for i in 0...160 {
            let t = CGFloat(i) / 160
            let theta = -CGFloat.pi / 2 + 0.35 + t * (1.55 - CGFloat(k) * 0.2) * .pi
            let r = r0 * scale * (1 - 0.35 * t)
            pts.append(NSPoint(x: c.x + r * cos(theta), y: c.y + r * sin(theta) * 0.96))
        }
        brush(pts, width: { t in 10 * taper(t, start: 0.2, end: 0.5) }, color: color)
    }
}

func paper(_ color: NSColor, fibers: NSColor) {
    color.setFill(); body.fill()
    for _ in 0..<900 {
        let p = NSPoint(x: body.minX + rand() * body.width, y: body.minY + rand() * body.height)
        let a = rand() * .pi, l = 6 + rand() * 18
        let f = NSBezierPath(); f.move(to: p); f.line(to: NSPoint(x: p.x + cos(a) * l, y: p.y + sin(a) * l))
        f.lineWidth = 0.8; fibers.withAlphaComponent(0.05 + rand() * 0.06).setStroke(); f.stroke()
    }
}

func tile(_ draw: () -> Void, _ name: String) {
    seed = 7
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); shape.fill(); ctx.restoreGState()
    NSGraphicsContext.saveGraphicsState(); shape.addClip(); draw(); NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.08).setStroke(); let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184); rim.lineWidth = 4; rim.stroke()
    img.unlockFocus()
    try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name))
}

let c = NSPoint(x: 540, y: 520), r: CGFloat = 270
func wave(_ ink: NSColor, ground: NSColor) {
    brush(curlPoints(center: c, radius: r), width: { t in 118 * taper(t) + 3 }, color: ink, dry: ground)
    claws(center: c, radius: r, color: ink)
    flowLines(center: c, radius: r, color: ground.withAlphaComponent(0.9))
}

tile({
    let night = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 1)
    paper(night, fibers: .white)
    vermilion.setFill()
    NSBezierPath(ovalIn: NSRect(x: 560, y: 560, width: 300, height: 300)).fill()
    wave(bone, ground: night)
}, "build/icon-1024.png")

// Every size the .icns needs, plus the website's icon.
func run(_ path: String, _ args: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
}
// The organizer's button animates the icon's parts separately, so `--mark` renders them as
// layers (the icon's square, uncropped; the app clips it round): Resources/Mark/*.png.
if CommandLine.arguments.contains("--mark") {
    let night = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 1)
    func layer(_ name: String, _ draw: () -> Void) {
        seed = 7
        let img = NSImage(size: NSSize(width: S, height: S))
        img.lockFocus(); draw(); img.unlockFocus()
        let full = "build/mark-\(name).png"
        try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: full))
        run("/usr/bin/sips", ["-c", "824", "824", full, "--out", full])
        run("/usr/bin/sips", ["-z", "192", "192", full, "--out", "Resources/Mark/\(name).png"])
    }
    try FileManager.default.createDirectory(atPath: "Resources/Mark", withIntermediateDirectories: true)
    layer("ground") { paper(night, fibers: .white) }
    layer("sun") { vermilion.setFill(); NSBezierPath(ovalIn: NSRect(x: 560, y: 560, width: 300, height: 300)).fill() }
    layer("wave") { wave(bone, ground: night) }
    print("Resources/Mark/ground.png, sun.png, wave.png")
    exit(0)
}

let master = "build/icon-1024.png"
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master, "--out", iconset.appendingPathComponent(name).path])
    }
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"])
run("/usr/bin/sips", ["-z", "256", "256", master, "--out", "docs/icon.png"])
print("Resources/AppIcon.icns, docs/icon.png")
