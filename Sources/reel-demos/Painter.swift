import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What a window looks like: a few shapes that read as an app at a glance, no real content.
struct Look {
    enum Kind { case browser, code, notes, terminal, mail, music }
    var kind: Kind
    var seed: UInt32

    var title: String {
        switch kind {
        case .browser: return "Safari"
        case .code: return "Xcode"
        case .notes: return "Notes"
        case .terminal: return "Terminal"
        case .mail: return "Mail"
        case .music: return "Music"
        }
    }

    var tint: NSColor {
        switch kind {
        case .browser: return rgb(0x5b9cff)
        case .code: return rgb(0xb48cff)
        case .notes: return rgb(0xffc65c)
        case .terminal: return rgb(0x5fd38a)
        case .mail: return rgb(0x4cc3e8)
        case .music: return rgb(0xff6b8a)
        }
    }
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Same-every-run pseudo random numbers, so a window's made-up content doesn't flicker.
struct Dice {
    var state: UInt32
    mutating func next() -> CGFloat {
        state = state &* 1_664_525 &+ 1_013_904_223
        return CGFloat(state >> 8) / CGFloat(1 << 24)
    }
}

final class Painter {
    private let size = Stage.canvas
    private let scale: CGFloat = 1
    private lazy var wallpaper = Self.wallpaper(size: size)

    func paint(_ scene: Scene) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let base = NSGraphicsContext(bitmapImageRep: rep)!
        let cg = base.cgContext
        // Top-left origin from here on, like the layout's coordinates.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let all = CGRect(origin: .zero, size: size)
        wallpaper.draw(in: all, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        drawDisplay(scene)
        if let c = scene.caption { drawCaption(c, alpha: scene.captionAlpha, fingers: scene.fingers) }
        return rep.cgImage!
    }

    // MARK: - Display

    private func drawDisplay(_ scene: Scene) {
        let d = Stage.display
        let screen = NSBezierPath(roundedRect: d, xRadius: 12, yRadius: 12)

        // Off-screen part of the strip: faint, outside the display.
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: CGRect(origin: .zero, size: size))
        outside.append(screen)
        outside.windingRule = .evenOdd
        outside.addClip()
        for w in scene.windows { drawWindow(w, ghost: true) }
        NSGraphicsContext.restoreGraphicsState()

        // The display itself.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 40
        shadow.shadowOffset = NSSize(width: 0, height: -18)
        shadow.set()
        rgb(0x141221).setFill()
        screen.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        screen.addClip()
        wallpaper.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 0.55,
                       respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.25).setFill()
        d.fill()
        // Menu bar.
        NSColor.black.withAlphaComponent(0.35).setFill()
        CGRect(x: d.minX, y: d.minY, width: d.width, height: Stage.menuBar).fill()
        for (i, w) in [CGFloat(10), 26, 20, 30].enumerated() {
            NSColor.white.withAlphaComponent(i == 0 ? 0.8 : 0.45).setFill()
            let x = d.minX + 12 + CGFloat(i) * 40
            NSBezierPath(roundedRect: CGRect(x: x, y: d.minY + 5, width: w, height: 6), xRadius: 3, yRadius: 3).fill()
        }
        for w in scene.windows { drawWindow(w, ghost: false) }
        for t in scene.tabs { drawTabs(t) }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.4).setStroke()
        let edge = NSBezierPath(roundedRect: d.insetBy(dx: -0.75, dy: -0.75), xRadius: 12.75, yRadius: 12.75)
        edge.lineWidth = 1.5
        edge.stroke()
    }

    // MARK: - Windows

    private func drawWindow(_ w: Scene.Window, ghost: Bool) {
        let r = w.rect
        guard r.width > 2, r.height > 2 else { return }
        let body = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(w.alpha) * (ghost ? 0.3 : 1))
        NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { NSGraphicsContext.current?.cgContext.endTransparencyLayer() }

        (w.look.kind == .terminal ? rgb(0x101114) : rgb(0x1d1d22)).setFill()
        body.fill()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        let bar = CGRect(x: r.minX, y: r.minY, width: r.width, height: 26)
        rgb(0x2a2a31).setFill()
        bar.fill()
        // Traffic lights are only coloured on the window in front, as on macOS.
        let lights: [UInt32] = w.focused ? [0xff5f57, 0xfebc2e, 0x28c840] : [0x55555d, 0x55555d, 0x55555d]
        for (i, c) in lights.enumerated() {
            rgb(c).setFill()
            NSBezierPath(ovalIn: CGRect(x: r.minX + 10 + CGFloat(i) * 15, y: r.minY + 8, width: 10, height: 10)).fill()
        }
        let title = NSAttributedString(string: w.look.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(w.focused ? 0.8 : 0.45),
        ])
        let ts = title.size()
        if r.width > ts.width + 110 { title.draw(at: CGPoint(x: r.midX - ts.width / 2, y: r.minY + 6)) }
        drawContent(w.look, in: CGRect(x: r.minX, y: r.minY + 26, width: r.width, height: r.height - 26), focused: w.focused)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.1).setStroke()
        body.lineWidth = 1
        body.stroke()
        if w.focused && !ghost {
            NSColor.white.withAlphaComponent(0.92).setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 12, yRadius: 12)
            ring.lineWidth = 2.5
            ring.stroke()
        }
    }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
        guard w > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }

    private func drawContent(_ look: Look, in r: CGRect, focused: Bool) {
        var dice = Dice(state: look.seed &* 2_654_435_761)
        let pad: CGFloat = 14
        let inner = r.insetBy(dx: pad, dy: pad)
        let dim = NSColor.white.withAlphaComponent(0.16)
        let text = NSColor.white.withAlphaComponent(0.3)
        switch look.kind {
        case .browser:
            bar(r.midX - min(160, r.width * 0.3), r.minY + 8, min(320, r.width * 0.6), 14, NSColor.white.withAlphaComponent(0.1))
            var y = r.minY + 34
            let hero = CGRect(x: inner.minX, y: y, width: inner.width, height: min(140, r.height * 0.32))
            NSGradient(colors: [look.tint.withAlphaComponent(0.85), rgb(0x8a5a9e, 0.85)])!
                .draw(in: NSBezierPath(roundedRect: hero, xRadius: 8, yRadius: 8), angle: 0)
            bar(hero.minX + 16, hero.maxY - 36, min(200, hero.width * 0.5), 10, NSColor.white.withAlphaComponent(0.85))
            bar(hero.minX + 16, hero.maxY - 20, min(130, hero.width * 0.35), 6, NSColor.white.withAlphaComponent(0.5))
            y = hero.maxY + 18
            while y < inner.maxY - 8 {
                bar(inner.minX, y, inner.width * (0.55 + 0.4 * dice.next()), 6, text)
                y += 16
            }
        case .code:
            let side = min(150, r.width * 0.24)
            rgb(0x18181c).setFill()
            CGRect(x: r.minX, y: r.minY, width: side, height: r.height).fill()
            var y = r.minY + 14
            while y < r.maxY - 10 {
                bar(r.minX + 12 + (dice.next() > 0.6 ? 10 : 0), y, side * (0.35 + 0.35 * dice.next()), 5, dim)
                y += 14
            }
            y = r.minY + 14
            var indent: CGFloat = 0
            let palette = [look.tint.withAlphaComponent(0.75), rgb(0x5fd3c4, 0.7), rgb(0xff9f6b, 0.7), text]
            while y < r.maxY - 10 {
                bar(r.minX + side + 10, y, 12, 5, NSColor.white.withAlphaComponent(0.1))
                var x = r.minX + side + 34 + indent
                for _ in 0..<(1 + Int(dice.next() * 3)) {
                    let w = 18 + dice.next() * 60
                    bar(x, y, w, 5, palette[Int(dice.next() * CGFloat(palette.count)) % palette.count])
                    x += w + 6
                }
                let roll = dice.next()
                if roll > 0.75 { indent = min(indent + 14, 42) } else if roll < 0.2 { indent = max(indent - 14, 0) }
                y += 14
            }
        case .notes:
            bar(inner.minX, inner.minY + 4, min(220, inner.width * 0.55), 12, look.tint.withAlphaComponent(0.9))
            var y = inner.minY + 34
            while y < inner.maxY - 8 {
                let lines = 2 + Int(dice.next() * 3)
                for i in 0..<lines where y < inner.maxY - 8 {
                    bar(inner.minX, y, inner.width * (i == lines - 1 ? 0.4 + 0.3 * dice.next() : 0.85 + 0.15 * dice.next()), 6, text)
                    y += 14
                }
                y += 12
            }
        case .terminal:
            var y = inner.minY
            while y < inner.maxY - 8 {
                bar(inner.minX, y, 10, 6, look.tint.withAlphaComponent(0.9))
                bar(inner.minX + 16, y, inner.width * (0.2 + 0.45 * dice.next()), 6, NSColor.white.withAlphaComponent(0.55))
                y += 15
                for _ in 0..<Int(dice.next() * 3) where y < inner.maxY - 8 {
                    bar(inner.minX, y, inner.width * (0.3 + 0.6 * dice.next()), 6, dim)
                    y += 15
                }
            }
            if focused { bar(inner.minX, y, 8, 12, look.tint) }
        case .mail:
            let list = min(260, r.width * 0.42)
            var y = r.minY + 10
            var first = true
            while y < r.maxY - 40 {
                if first { look.tint.withAlphaComponent(0.25).setFill(); CGRect(x: r.minX, y: y - 6, width: list, height: 48).fill() }
                look.tint.withAlphaComponent(0.8).setFill()
                NSBezierPath(ovalIn: CGRect(x: r.minX + 12, y: y + 4, width: 24, height: 24)).fill()
                bar(r.minX + 46, y + 6, list * (0.3 + 0.3 * dice.next()), 6, NSColor.white.withAlphaComponent(0.6))
                bar(r.minX + 46, y + 20, list * (0.4 + 0.3 * dice.next()), 5, dim)
                y += 50
                first = false
            }
            if r.width - list > 120 {
                let x = r.minX + list + 18
                bar(x, r.minY + 16, (r.maxX - x - 18) * 0.6, 10, NSColor.white.withAlphaComponent(0.7))
                var yy = r.minY + 44
                while yy < r.maxY - 12 {
                    bar(x, yy, (r.maxX - x - 18) * (0.7 + 0.3 * dice.next()), 6, text)
                    yy += 15
                }
            }
        case .music:
            let cols = max(2, Int(inner.width / 110))
            let cell = (inner.width - CGFloat(cols - 1) * 12) / CGFloat(cols)
            let hues: [UInt32] = [0xff6b8a, 0xffb35c, 0x8a7bff, 0x4cc3e8, 0x5fd38a, 0xd46bff]
            var y = inner.minY
            var i = 0
            while y + cell < inner.maxY {
                for c in 0..<cols {
                    let rect = CGRect(x: inner.minX + CGFloat(c) * (cell + 12), y: y, width: cell, height: cell - 22)
                    let a = rgb(hues[(i + Int(look.seed)) % hues.count]), b = rgb(hues[(i * 3 + 1) % hues.count])
                    NSGradient(colors: [a, b])!.draw(in: NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6), angle: 45)
                    bar(rect.minX, rect.maxY + 8, cell * 0.7, 5, text)
                    i += 1
                }
                y += cell + 4
            }
        }
    }

    private func drawTabs(_ t: Scene.Tabs) {
        let r = t.frame.insetBy(dx: 0, dy: 1)
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        guard !t.titles.isEmpty else { return }
        let w = (r.width - 4) / CGFloat(t.titles.count)
        for (i, title) in t.titles.enumerated() {
            let tab = CGRect(x: r.minX + 2 + CGFloat(i) * w, y: r.minY + 2, width: w - 2, height: r.height - 4)
            if i == t.active {
                NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: tab, xRadius: 5, yRadius: 5).fill()
            }
            let s = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: i == t.active ? .semibold : .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(i == t.active ? 0.95 : 0.55),
            ])
            let sz = s.size()
            s.draw(at: CGPoint(x: tab.midX - sz.width / 2, y: tab.midY - sz.height / 2))
        }
    }

    // MARK: - Caption

    private func drawCaption(_ c: Caption, alpha: Double, fingers: Double?) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(alpha))
        let keyFont = NSFont.systemFont(ofSize: 19, weight: .semibold)
        let text = NSAttributedString(string: c.text, attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ])
        let keys = c.keys.map { NSAttributedString(string: $0, attributes: [.font: keyFont, .foregroundColor: NSColor.white]) }
        let chipW = keys.map { max(34, $0.size().width + 18) }
        let pad: CGFloat = 12, chipH: CGFloat = 34
        let lead: CGFloat = c.trackpad ? 74 : chipW.reduce(0, +) + CGFloat(max(0, keys.count - 1)) * 6
        let total = lead + (lead > 0 ? 18 : 0) + text.size().width
        let pill = CGRect(x: (size.width - total) / 2 - pad - 6, y: 566, width: total + 2 * pad + 12, height: chipH + 20)
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()

        var x = pill.minX + pad + 6
        let y = pill.midY - chipH / 2
        if c.trackpad {
            let pad = CGRect(x: x, y: y - 2, width: 62, height: chipH + 4)
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: pad, xRadius: 7, yRadius: 7).fill()
            let p = fingers ?? 0.5
            for i in 0..<4 {
                let fx = pad.minX + 10 + CGFloat(p) * 18 + CGFloat(i) * 7
                let fy = pad.midY - 4 + (i == 0 || i == 3 ? 3 : 0)
                NSColor.white.withAlphaComponent(fingers == nil ? 0.45 : 0.95).setFill()
                NSBezierPath(ovalIn: CGRect(x: fx, y: fy, width: 6, height: 6)).fill()
            }
            x += lead
        } else {
            for (k, w) in zip(keys, chipW) {
                let chip = CGRect(x: x, y: y, width: w, height: chipH)
                NSColor.white.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7).fill()
                NSColor.white.withAlphaComponent(0.28).setStroke()
                NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
                let s = k.size()
                k.draw(at: CGPoint(x: chip.midX - s.width / 2, y: chip.midY - s.height / 2))
                x += w + 6
            }
            x -= keys.isEmpty ? 0 : 6
        }
        if lead > 0 { x += 18 }
        text.draw(at: CGPoint(x: x, y: pill.midY - text.size().height / 2))
    }

    // MARK: - Wallpaper

    /// The same dusk ridges as the settings screenshots (Snapshot.swift in the app).
    static func wallpaper(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            NSGradient(colors: [rgb(0xf6b26b), rgb(0xe07a6f), rgb(0x8a5a9e), rgb(0x2c3a6b)],
                       atLocations: [0, 0.3, 0.62, 1], colorSpace: .sRGB)!.draw(in: r, angle: 90)
            NSGradient(colors: [rgb(0xffe2a8, 0.85), rgb(0xffe2a8, 0)])!
                .draw(fromCenter: NSPoint(x: r.width * 0.68, y: r.height * 0.34), radius: 0,
                      toCenter: NSPoint(x: r.width * 0.68, y: r.height * 0.34), radius: r.width * 0.32, options: [])
            let ridges: [(base: CGFloat, amp: CGFloat, color: UInt32, seed: CGFloat)] = [
                (0.42, 0.07, 0x9b6a9c, 0.3), (0.33, 0.08, 0x6d4a82, 1.7), (0.22, 0.09, 0x433463, 2.9), (0.1, 0.07, 0x221c3a, 4.1),
            ]
            for ridge in ridges {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0, y: 0))
                for i in 0...160 {
                    let t = CGFloat(i) / 160, s = ridge.seed
                    let y = ridge.base + ridge.amp * (0.55 * sin(t * 7 + s) + 0.3 * sin(t * 17 + s * 2.3) + 0.15 * sin(t * 41 + s * 5.1))
                    path.line(to: NSPoint(x: t * r.width, y: y * r.height))
                }
                path.line(to: NSPoint(x: r.width, y: 0))
                path.close()
                rgb(ridge.color).setFill()
                path.fill()
            }
            return true
        }
    }
}

enum GIF {
    static func write(_ frames: [CGImage], fps: Double, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for f in frames { CGImageDestinationAddImage(dest, f, props) }
        CGImageDestinationFinalize(dest)
    }
}
