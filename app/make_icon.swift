// Renders AppIcon.iconset: two overlapping account avatars on a deep warm squircle,
// with a small "switch" badge — several accounts, one tap to move between them.
// Usage: swift make_icon.swift <out-dir> [preview.png]
import AppKit

let orange = NSColor(red: 0.95, green: 0.52, blue: 0.29, alpha: 1)
let orangeDeep = NSColor(red: 0.84, green: 0.38, blue: 0.22, alpha: 1)
let cream = NSColor(red: 0.98, green: 0.93, blue: 0.86, alpha: 1)

func drawIcon(size s: CGFloat) -> NSBitmapImageRep {
    let px = Int(s)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    // macOS icon grid: 824/1024 body with a soft drop shadow
    let body = s * 824 / 1024
    let o = (s - body) / 2
    let rect = NSRect(x: o, y: o + s * 0.008, width: body, height: body)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: body * 0.225, yRadius: body * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = s * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.010)
    shadow.set()
    NSColor(red: 0.16, green: 0.14, blue: 0.14, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // deep warm background + gentle top light
    NSGradient(colors: [NSColor(red: 0.27, green: 0.22, blue: 0.21, alpha: 1),
                        NSColor(red: 0.17, green: 0.15, blue: 0.15, alpha: 1)])!.draw(in: squircle, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: orange.withAlphaComponent(0.20), ending: orange.withAlphaComponent(0))!
        .draw(fromCenter: NSPoint(x: rect.midX, y: rect.maxY), radius: 0,
              toCenter: NSPoint(x: rect.midX, y: rect.maxY), radius: body * 0.75, options: [])
    NSGraphicsContext.restoreGraphicsState()

    let u = body / 100
    func avatar(center c: NSPoint, r: CGFloat, fill: NSColor, glyph: NSColor, ring: NSColor?) {
        let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        if let ring = ring {
            let outer = NSBezierPath(ovalIn: NSRect(x: c.x - r - 2.2 * u, y: c.y - r - 2.2 * u, width: 2 * r + 4.4 * u, height: 2 * r + 4.4 * u))
            ring.setFill(); outer.fill()
        }
        fill.setFill(); circle.fill()
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        glyph.setFill()
        // head
        let hr = r * 0.36
        NSBezierPath(ovalIn: NSRect(x: c.x - hr, y: c.y + r * 0.02, width: 2 * hr, height: 2 * hr)).fill()
        // shoulders
        let sw = r * 1.25, sh = r * 0.95
        NSBezierPath(ovalIn: NSRect(x: c.x - sw / 2, y: c.y - r * 0.98, width: sw, height: sh)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // back avatar (cream), front avatar (orange) with a ring that cuts it out of the back one
    avatar(center: NSPoint(x: rect.minX + 38 * u, y: rect.minY + 60 * u), r: 19 * u,
           fill: cream, glyph: NSColor(red: 0.80, green: 0.68, blue: 0.58, alpha: 1), ring: nil)
    avatar(center: NSPoint(x: rect.minX + 60 * u, y: rect.minY + 42 * u), r: 21 * u,
           fill: orange, glyph: NSColor(red: 1, green: 0.93, blue: 0.86, alpha: 1),
           ring: NSColor(red: 0.20, green: 0.17, blue: 0.17, alpha: 1))

    // switch badge
    let d = 22 * u
    let disc = NSRect(x: rect.minX + 70 * u, y: rect.minY + 62 * u, width: d, height: d)
    NSColor(red: 0.20, green: 0.17, blue: 0.17, alpha: 1).setFill()
    NSBezierPath(ovalIn: disc.insetBy(dx: -2 * u, dy: -2 * u)).fill()
    NSGradient(starting: orange, ending: orangeDeep)!.draw(in: NSBezierPath(ovalIn: disc), angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: d * 0.48, weight: .heavy)
        .applying(.init(paletteColors: [.white]))
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
