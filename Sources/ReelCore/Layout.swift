import CoreGraphics
import Foundation

/// What the layout needs to know about the display a strip lives on.
public struct LayoutContext {
    /// The display's usable area (menu bar and, if asked, the Dock removed), top-left origin.
    public var area: CGRect
    /// The display's full frame, top-left origin. Windows past these edges are off screen.
    public var displayFrame: CGRect
    public var config: Config
    /// Another display touches this one on that side, so windows must not hang over it.
    public var neighborLeft = false
    public var neighborRight = false
    /// Windows that refused to be as narrow as we asked; the strip spaces them by their real width.
    public var minWidths: [WindowID: Double] = [:]
    /// Heights windows opened with, for Keep Original Height.
    public var originalHeights: [WindowID: Double] = [:]

    public init(area: CGRect, displayFrame: CGRect? = nil, config: Config) {
        self.area = area
        self.displayFrame = displayFrame ?? area
        self.config = config
    }

    var inner: CGRect {
        area.insetBy(dx: config.outerGap, dy: config.outerGap)
    }
}

/// Positions of the strip's columns in strip space (x = 0 is the left edge of the first column).
public struct StripGeometry {
    public var starts: [Double]
    public var widths: [Double]
    /// The part of the screen the scrolling strip shows, after pinned columns take their share.
    public var viewportMinX: Double
    public var viewportWidth: Double
    public var pinnedFrames: [PinSide: CGRect]
    public let gap: Double

    public init(strip: Strip, context ctx: LayoutContext) {
        let inner = ctx.inner
        let gap = ctx.config.gap
        self.gap = gap
        var minX = Double(inner.minX)
        var maxX = Double(inner.maxX)
        var pins: [PinSide: CGRect] = [:]
        let pinW = ColumnWidth.proportion(ctx.config.pinnedWidth).resolve(in: Double(inner.width), gap: gap)
        if let col = strip.pinned[.left] {
            let w = Self.width(of: col, available: Double(inner.width), gap: gap, ctx: ctx, fallback: pinW)
            pins[.left] = CGRect(x: minX, y: Double(inner.minY), width: w, height: Double(inner.height))
            minX += w + gap
        }
        if let col = strip.pinned[.right] {
            let w = Self.width(of: col, available: Double(inner.width), gap: gap, ctx: ctx, fallback: pinW)
            pins[.right] = CGRect(x: maxX - w, y: Double(inner.minY), width: w, height: Double(inner.height))
            maxX -= w + gap
        }
        viewportMinX = minX
        viewportWidth = max(100, maxX - minX)
        pinnedFrames = pins

        var starts: [Double] = []
        var widths: [Double] = []
        var x = 0.0
        for col in strip.columns {
            let w = Self.width(of: col, available: viewportWidth, gap: gap, ctx: ctx, fallback: nil)
            starts.append(x)
            widths.append(w)
            x += w + gap
        }
        self.starts = starts
        self.widths = widths
    }

    static func width(of col: Column, available: Double, gap: Double, ctx: LayoutContext, fallback: Double?) -> Double {
        var w = fallback ?? col.width.resolve(in: available, gap: gap)
        if col.isFullWidth { w = available }
        // A window that won't shrink takes the room it needs, so nothing overlaps it.
        let minW = col.windows.compactMap { ctx.minWidths[$0] }.max() ?? 0
        return max(w, minW)
    }

    public var totalWidth: Double {
        guard let last = starts.indices.last else { return 0 }
        return starts[last] + widths[last]
    }

    public func range(_ i: Int) -> ClosedRange<Double> {
        starts[i]...(starts[i] + widths[i])
    }

    /// The view offset that shows column `i` given how the strip should centre it.
    public func offset(toShow i: Int, from current: Double, previous: Int?, mode: CenterMode) -> Double {
        guard starts.indices.contains(i) else { return current }
        let s = starts[i], w = widths[i], v = viewportWidth
        let centred = s + w / 2 - v / 2
        switch mode {
        case .always:
            return centred
        case .onOverflow:
            // Centre only when the new column and the one we came from can't both be on screen.
            if let p = previous, p != i, starts.indices.contains(p) {
                let lo = min(starts[p], s), hi = max(starts[p] + widths[p], s + w)
                if hi - lo > v { return clampOffset(centred) }
                return clampOffset(minimal(lo, hi - lo, current: minimal(s, w, current: current)))
            }
            if w > v { return centred }
            return clampOffset(minimal(s, w, current: current))
        case .never:
            return clampOffset(minimal(s, w, current: current))
        }
    }

    func minimal(_ s: Double, _ w: Double, current: Double) -> Double {
        let v = viewportWidth
        if w >= v { return s } // too wide to fit: line its left edge up with the viewport
        if s < current { return s }
        if s + w > current + v { return s + w - v }
        return current
    }

    /// Keep the strip from scrolling past its ends when it doesn't need to.
    public func clampOffset(_ o: Double) -> Double {
        let maxO = max(0, totalWidth - viewportWidth)
        return min(max(o, 0), maxO)
    }

    /// Which column sits under the viewport's centre at a given offset.
    public func column(atViewCenter offset: Double) -> Int? {
        guard !starts.isEmpty else { return nil }
        let c = offset + viewportWidth / 2
        var best = 0
        var bestDist = Double.infinity
        for i in starts.indices {
            let r = range(i)
            if r.contains(c) { return i }
            let d = min(abs(r.lowerBound - c), abs(r.upperBound - c))
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// The column whose left edge (or centre, when centring always) is closest to where a swipe
    /// would come to rest.
    public func snapColumn(forOffset offset: Double, mode: CenterMode) -> Int? {
        guard !starts.isEmpty else { return nil }
        if mode == .always { return column(atViewCenter: offset) }
        var best = 0
        var bestDist = Double.infinity
        let maxO = max(0, totalWidth - viewportWidth)
        for i in starts.indices {
            // Where the view would sit if this column were lined up at the left edge.
            let target = min(starts[i], maxO)
            let d = abs(target - offset)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}

public struct WindowPlacement: Equatable {
    public var id: WindowID
    public var frame: CGRect
    /// False when the window is fully off screen (scrolled away, or a hidden tab).
    public var visible: Bool
    /// When hidden, which side of the display it went off.
    public var hiddenSide: PinSide?
    /// Keep the window's own height; only move it.
    public var keepsHeight: Bool
}

public struct TabBar: Equatable {
    public var frame: CGRect
    public var windows: [WindowID]
    public var active: Int
    public var focused: Bool
}

public struct LayoutResult {
    public var placements: [WindowPlacement] = []
    public var tabBars: [TabBar] = []
    /// Screen frames of the strip's columns, in order (pinned columns not included).
    public var columnFrames: [CGRect] = []
    public var geometry: StripGeometry?
}

public enum Layout {
    /// Lays out a strip at a given view offset.
    public static func compute(_ strip: Strip, context ctx: LayoutContext, viewOffset: Double? = nil) -> LayoutResult {
        let geo = StripGeometry(strip: strip, context: ctx)
        let offset = viewOffset ?? strip.viewOffset
        let inner = ctx.inner
        let display = ctx.displayFrame
        var result = LayoutResult()
        result.geometry = geo

        // Edges nothing may hang over: a neighbouring display, or a pinned column.
        let hasLeftPin = strip.pinned[.left] != nil, hasRightPin = strip.pinned[.right] != nil
        let leftEdge: Double? = hasLeftPin ? geo.viewportMinX : (ctx.neighborLeft ? Double(display.minX) : nil)
        let leftSnap = hasLeftPin ? geo.viewportMinX : Double(inner.minX)
        let viewportMaxX = geo.viewportMinX + geo.viewportWidth
        let rightEdge: Double? = hasRightPin ? viewportMaxX : (ctx.neighborRight ? Double(display.maxX) : nil)
        let rightSnap = hasRightPin ? viewportMaxX : Double(inner.maxX)
        let raw = strip.columns.indices.map { geo.viewportMinX + geo.starts[$0] - offset }
        let gap = ctx.config.gap
        var previousRight = -Double.infinity

        for (i, col) in strip.columns.enumerated() {
            var x = raw[i]
            let w = geo.widths[i]
            var visible = x + w > Double(display.minX) && x < Double(display.maxX)
            var side: PinSide? = nil
            if x + w <= Double(display.minX) { side = .left }
            if x >= Double(display.maxX) { side = .right }

            // A column crossing one of those edges snaps flush against it when most of it is
            // showing and there's room, and hides otherwise. It never overlaps its neighbours.
            if visible, let edge = rightEdge, x + w > edge + 0.5 {
                let snapped = rightSnap - w
                if edge - x >= w / 2 && snapped >= previousRight + gap - 0.5 { x = snapped } else { visible = false; side = .right }
            }
            if visible, let edge = leftEdge, x < edge - 0.5 {
                let next = i + 1 < raw.count ? raw[i + 1] : Double.infinity
                if x + w - edge >= w / 2 && leftSnap + w + gap <= next + 0.5 { x = leftSnap } else { visible = false; side = .left }
            }
            if visible { previousRight = x + w }

            let colRect = CGRect(x: x, y: Double(inner.minY), width: w, height: Double(inner.height))
            result.columnFrames.append(colRect)
            let focusedCol = strip.focusedPin == nil && strip.focused == i
            place(col, in: colRect, visible: visible, side: side, focused: focusedCol, ctx: ctx, into: &result)
        }

        for side in PinSide.allCases {
            guard let col = strip.pinned[side], let rect = geo.pinnedFrames[side] else { continue }
            place(col, in: rect, visible: true, side: nil, focused: strip.focusedPin == side, ctx: ctx, into: &result)
        }
        return result
    }

    static func place(_ col: Column, in rect: CGRect, visible: Bool, side: PinSide?, focused: Bool,
                      ctx: LayoutContext, into result: inout LayoutResult) {
        let gap = ctx.config.gap
        if col.tabbed && col.windows.count > 1 {
            let barH = ctx.config.tabBarHeight
            let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: barH)
            let body = CGRect(x: rect.minX, y: rect.minY + barH, width: rect.width, height: max(50, rect.height - barH))
            for (r, id) in col.windows.enumerated() {
                let isActive = r == col.active
                result.placements.append(WindowPlacement(
                    id: id, frame: body, visible: visible && isActive,
                    hiddenSide: (visible && isActive) ? nil : (side ?? .right), keepsHeight: false))
            }
            if visible {
                result.tabBars.append(TabBar(frame: bar, windows: col.windows, active: col.active, focused: focused))
            }
            return
        }

        if col.windows.count == 1, let id = col.windows.first {
            var frame = rect
            var keeps = false
            if ctx.config.keepOriginalHeight, let h = ctx.originalHeights[id] {
                frame.size.height = min(rect.height, h)
                keeps = true
            }
            result.placements.append(WindowPlacement(id: id, frame: frame, visible: visible, hiddenSide: side, keepsHeight: keeps))
            return
        }

        let n = col.windows.count
        let weights = col.weights.count == n ? col.weights : Array(repeating: 1, count: n)
        let total = weights.reduce(0, +)
        let usable = Double(rect.height) - gap * Double(n - 1)
        var y = Double(rect.minY)
        for (r, id) in col.windows.enumerated() {
            let h = r == n - 1 ? Double(rect.maxY) - y : usable * weights[r] / total
            let frame = CGRect(x: Double(rect.minX), y: y, width: Double(rect.width), height: max(40, h))
            result.placements.append(WindowPlacement(id: id, frame: frame, visible: visible, hiddenSide: side, keepsHeight: false))
            y += h + gap
        }
    }
}
