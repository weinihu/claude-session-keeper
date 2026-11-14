// Renders AppIcon.iconset: two chat bubbles on a warm squircle, with a "switch" badge.
// Usage: swift make_icon.swift <out-dir> [preview.png]
import AppKit

func drawIcon(size s: CGFloat) -> NSBitmapImageRep {
    let px = Int(s)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    // macOS icon grid: 824/1024 body, centred, with a soft drop shadow
    let body = s * 824 / 1024
    let o = (s - body) / 2
    let rect = NSRect(x: o, y: o + s * 0.008, width: body, height: body)
    let radius = body * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.010)
    shadow.set()
    NSColor(red: 0.85, green: 0.42, blue: 0.24, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // warm gradient + top sheen
    NSGradient(colors: [NSColor(red: 0.99, green: 0.66, blue: 0.38, alpha: 1),
                        NSColor(red: 0.91, green: 0.45, blue: 0.27, alpha: 1),
                        NSColor(red: 0.78, green: 0.33, blue: 0.22, alpha: 1)])!
        .draw(in: squircle, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    func bubble(_ r: NSRect, tailLeft: Bool, fill: NSColor) {
        let p = NSBezierPath(roundedRect: r, xRadius: r.height * 0.42, yRadius: r.height * 0.42)
        let tail = NSBezierPath()
        let ty = r.minY + r.height * 0.18
        if tailLeft {
            tail.move(to: NSPoint(x: r.minX + r.width * 0.16, y: ty))
            tail.line(to: NSPoint(x: r.minX + r.width * 0.02, y: r.minY - r.height * 0.20))
            tail.line(to: NSPoint(x: r.minX + r.width * 0.36, y: r.minY + r.height * 0.02))
        } else {
            tail.move(to: NSPoint(x: r.maxX - r.width * 0.16, y: ty))
            tail.line(to: NSPoint(x: r.maxX - r.width * 0.02, y: r.minY - r.height * 0.20))
            tail.line(to: NSPoint(x: r.maxX - r.width * 0.36, y: r.minY + r.height * 0.02))
        }
        tail.close()
        fill.setFill(); p.fill(); tail.fill()
    }

    // back bubble (translucent), front bubble (white) with three "message" lines
    let u = body / 100
    bubble(NSRect(x: rect.minX + 30 * u, y: rect.minY + 44 * u, width: 52 * u, height: 34 * u),
           tailLeft: false, fill: NSColor.white.withAlphaComponent(0.45))
    let front = NSRect(x: rect.minX + 16 * u, y: rect.minY + 26 * u, width: 56 * u, height: 36 * u)
    NSGraphicsContext.saveGraphicsState()
    let bs = NSShadow(); bs.shadowColor = NSColor.black.withAlphaComponent(0.18)
    bs.shadowBlurRadius = 3 * u; bs.shadowOffset = NSSize(width: 0, height: -1.2 * u); bs.set()
    bubble(front, tailLeft: true, fill: .white)
    NSGraphicsContext.restoreGraphicsState()
    let lineColor = NSColor(red: 0.88, green: 0.47, blue: 0.29, alpha: 0.9)
    for (i, w) in [36.0, 28.0].enumerated() {
        let lh = 4.6 * u
        let y = front.maxY - 12 * u - CGFloat(i) * 9.5 * u
        let line = NSBezierPath(roundedRect: NSRect(x: front.minX + 10 * u, y: y, width: CGFloat(w) * u, height: lh),
                                xRadius: lh / 2, yRadius: lh / 2)
        lineColor.setFill(); line.fill()
    }

    // switch badge: white disc with circular arrows
    let d = 34 * u
    let disc = NSRect(x: rect.maxX - d - 9 * u, y: rect.minY + 9 * u, width: d, height: d)
    NSGraphicsContext.saveGraphicsState()
    let ds = NSShadow(); ds.shadowColor = NSColor.black.withAlphaComponent(0.22)
    ds.shadowBlurRadius = 3 * u; ds.shadowOffset = NSSize(width: 0, height: -1.2 * u); ds.set()
    NSColor.white.setFill(); NSBezierPath(ovalIn: disc).fill()
    NSGraphicsContext.restoreGraphicsState()
    let cfg = NSImage.SymbolConfiguration(pointSize: d * 0.50, weight: .heavy)
        .applying(.init(paletteColors: [NSColor(red: 0.86, green: 0.40, blue: 0.24, alpha: 1)]))
    if let sym = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: disc.midX - sz.width / 2, y: disc.midY - sz.height / 2, width: sz.width, height: sz.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                   ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! drawIcon(size: CGFloat(px)).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
if CommandLine.arguments.count > 2 {
    try! drawIcon(size: 512).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
