import AppKit
import ReelCore

/// A display in the top-left-origin coordinate space the Accessibility API uses.
struct Display: Equatable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    /// Full frame.
    let frame: CGRect
    /// Frame without the menu bar and the Dock.
    let visibleFrame: CGRect
    /// Frame without the menu bar only.
    let frameBelowMenuBar: CGRect

    func usableArea(respectDock: Bool) -> CGRect {
        respectDock ? visibleFrame : frameBelowMenuBar
    }
}

enum Displays {
    /// Height of the primary screen, which anchors the flip between AppKit and AX coordinates.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func toAX(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toAppKit(point p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func current() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(num.uint32Value)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(id)"
            let frame = toAX(screen.frame)
            let visible = toAX(screen.visibleFrame)
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            var below = frame
            below.origin.y += menuBar
            below.size.height -= menuBar
            return Display(id: id, uuid: uuid, name: screen.localizedName, frame: frame, visibleFrame: visible, frameBelowMenuBar: below)
        }
    }

    /// Whether another display touches `d` on its left or right edge (with some vertical overlap).
    static func neighbors(of d: Display, in all: [Display]) -> (left: Bool, right: Bool) {
        var left = false, right = false
        for o in all where o.id != d.id {
            let overlapsVertically = o.frame.minY < d.frame.maxY && o.frame.maxY > d.frame.minY
            guard overlapsVertically else { continue }
            if abs(o.frame.maxX - d.frame.minX) < 2 { left = true }
            if abs(o.frame.minX - d.frame.maxX) < 2 { right = true }
        }
        return (left, right)
    }

    static func display(containing point: CGPoint, in all: [Display]) -> Display? {
        all.first { $0.frame.contains(point) }
    }

    /// The display a window mostly sits on.
    static func display(for rect: CGRect, in all: [Display]) -> Display? {
        var best: Display?
        var bestArea: CGFloat = 0
        for d in all {
            let i = d.frame.intersection(rect)
            let a = i.isNull ? 0 : i.width * i.height
            if a > bestArea { bestArea = a; best = d }
        }
        if best == nil {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            best = all.min { dist($0.frame, c) < dist($1.frame, c) }
        }
        return best
    }

    private static func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// Where to park a window that's scrolled off screen: as far off as macOS allows, with one
    /// point still on the display, on a side where it can't land on another display.
    static func parkingSpot(for size: CGSize, on d: Display, side: PinSide, all: [Display], y: CGFloat) -> CGPoint {
        let f = d.frame
        let right = CGPoint(x: f.maxX - 1, y: y)
        let left = CGPoint(x: f.minX - size.width + 1, y: y)
        let bottomRight = CGPoint(x: f.maxX - 1, y: f.maxY - 1)
        let bottomLeft = CGPoint(x: f.minX - size.width + 1, y: f.maxY - 1)
        let candidates = side == .right ? [right, bottomRight, left, bottomLeft] : [left, bottomLeft, right, bottomRight]
        for c in candidates {
            let r = CGRect(origin: c, size: size)
            let hitsOther = all.contains { o in o.id != d.id && o.frame.intersects(r.insetBy(dx: 1, dy: 1)) }
            if !hitsOther { return c }
        }
        return bottomRight
    }
}
