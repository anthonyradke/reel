import AppKit
import SwiftUI

/// Debug aid: `REEL_SNAPSHOT=/tmp/shots Reel` renders every settings page and the onboarding
/// steps to PNGs, so the UI can be checked without screen recording permission. It also
/// writes `hero-<page>.png`: the window on a wallpaper, as used in the README.
enum Snapshot {
    static func run(into dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        EngineState.showsAsRunning = true
        EngineState.shared.refresh()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for page in [SettingsPage.layout, .shortcuts, .setup] {
            let view = SettingsView(page: page, titleBarInset: 24)
                .environmentObject(ConfigStore.shared)
                .environmentObject(EngineState.shared)
                .frame(width: 860, height: 640)
            guard let shot = image(view, size: NSSize(width: 860, height: 640), appearance: .darkAqua) else { continue }
            let name = page.id.lowercased().replacingOccurrences(of: " ", with: "-")
            try? Hero.compose(shot).write(to: dir.appendingPathComponent("hero-\(name).png"))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for page in SettingsPage.allCases {
                let view = SettingsView(page: page)
                    .environmentObject(ConfigStore.shared)
                    .environmentObject(EngineState.shared)
                    .frame(width: 860, height: 640)
                render(view, size: NSSize(width: 860, height: 640), appearance: appearance,
                       to: dir.appendingPathComponent("settings-\(page.id.lowercased().replacingOccurrences(of: " ", with: "-"))-\(suffix).png"))
            }
            let onboarding = OnboardingView(onFinish: {}).environmentObject(EngineState.shared)
            render(onboarding, size: NSSize(width: 620, height: 470), appearance: appearance,
                   to: dir.appendingPathComponent("onboarding-\(suffix).png"))
        }
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        try? image(view, size: size, appearance: appearance)?.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func image<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        // Let SwiftUI lay out and finish its first pass.
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

/// Puts a window screenshot on a drawn dusk wallpaper with rounded corners, traffic lights and
/// a soft shadow. Drawn rather than photographed, so the repo holds no third-party images.
enum Hero {
    static func compose(_ shot: NSBitmapImageRep) -> Data {
        let scale = CGFloat(shot.pixelsWide) / shot.size.width
        let win = shot.size
        let height = (win.height * 1.45).rounded()
        let canvas = NSSize(width: (height * 16 / 9).rounded(), height: height)
        let px = NSSize(width: canvas.width * scale, height: canvas.height * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        drawWallpaper(in: NSRect(origin: .zero, size: canvas))

        let frame = NSRect(x: (canvas.width - win.width) / 2, y: (canvas.height - win.height) / 2,
                           width: win.width, height: win.height)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 60
        shadow.shadowOffset = NSSize(width: 0, height: -24)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        shot.draw(in: frame)
        for (i, color) in [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                           NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                           NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: frame.minX + 18 + CGFloat(i) * 20, y: frame.maxY - 20, width: 12, height: 12)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        edge.lineWidth = 1
        edge.stroke()
        return rep.representation(using: .png, properties: [:])!
    }

    private static func drawWallpaper(in r: NSRect) {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        NSGradient(colors: [c(0xf6b26b), c(0xe07a6f), c(0x8a5a9e), c(0x2c3a6b)],
                   atLocations: [0, 0.3, 0.62, 1], colorSpace: .sRGB)!.draw(in: r, angle: 90)
        // Low sun glow behind the ridges.
        NSGradient(colors: [c(0xffe2a8).withAlphaComponent(0.85), c(0xffe2a8).withAlphaComponent(0)])!
            .draw(fromCenter: NSPoint(x: r.width * 0.68, y: r.height * 0.34), radius: 0,
                  toCenter: NSPoint(x: r.width * 0.68, y: r.height * 0.34), radius: r.width * 0.32, options: [])
        // Ridges, far to near: a few sine waves each, darker and lower as they come closer.
        let ridges: [(base: CGFloat, amp: CGFloat, color: UInt32, seed: CGFloat)] = [
            (0.42, 0.07, 0x9b6a9c, 0.3), (0.33, 0.08, 0x6d4a82, 1.7), (0.22, 0.09, 0x433463, 2.9), (0.1, 0.07, 0x221c3a, 4.1),
        ]
        for ridge in ridges {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: 0))
            let steps = 160
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let s = ridge.seed
                let y = ridge.base + ridge.amp * (0.55 * sin(t * 7 + s) + 0.3 * sin(t * 17 + s * 2.3) + 0.15 * sin(t * 41 + s * 5.1))
                path.line(to: NSPoint(x: t * r.width, y: y * r.height))
            }
            path.line(to: NSPoint(x: r.width, y: 0))
            path.close()
            c(ridge.color).setFill()
            path.fill()
        }
    }
}
