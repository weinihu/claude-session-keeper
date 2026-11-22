// Put a window snapshot on a white rounded card with a soft shadow, so README
// screenshots read well in both GitHub themes.
// Usage: swift app/screenshot_card.swift <in.png> <out.png>
import AppKit

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!
let px = src.representations[0]
let w = CGFloat(px.pixelsWide), h = CGFloat(px.pixelsHigh)
let pad: CGFloat = 24
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w + pad * 2), pixelsHigh: Int(h + pad * 2),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let card = NSRect(x: pad, y: pad, width: w, height: h)
let path = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 16
shadow.shadowOffset = NSSize(width: 0, height: -4)
shadow.set()
NSColor.white.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
path.addClip()
src.draw(in: card, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
NSColor.black.withAlphaComponent(0.12).setStroke()
path.lineWidth = 1
path.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
