// Draws Reel's icon: three rounded columns on a dark squircle, the middle one lit.
// swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.22, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1)])!.draw(in: bg, angle: -90)
    bg.addClip()
    let h = body.height * 0.62
    let y = body.midY - h / 2
    let gap = body.width * 0.05
    let mid = body.width * 0.42
    let side = body.width * 0.34
    let cols: [(CGFloat, CGFloat, NSColor)] = [
        (body.midX - mid / 2 - gap - side, side, NSColor(calibratedWhite: 1, alpha: 0.22)),
        (body.midX - mid / 2, mid, NSColor(calibratedRed: 0.36, green: 0.62, blue: 1, alpha: 1)),
        (body.midX + mid / 2 + gap, side, NSColor(calibratedWhite: 1, alpha: 0.22)),
    ]
    for (x, w, c) in cols {
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: s * 0.035, yRadius: s * 0.035).fill()
    }
    // Viewport bracket around the lit column.
    NSColor(calibratedWhite: 1, alpha: 0.9).setStroke()
    let frame = NSBezierPath(roundedRect: NSRect(x: body.midX - mid / 2 - gap * 0.6, y: y - gap * 0.6,
                                                 width: mid + gap * 1.2, height: h + gap * 1.2),
                             xRadius: s * 0.05, yRadius: s * 0.05)
    frame.lineWidth = max(1, s * 0.014)
    frame.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
