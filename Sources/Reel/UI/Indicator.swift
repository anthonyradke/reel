import AppKit
import ReelCore

/// The frosted bar that shows the whole strip while you move around it: one tile per column
/// with its app icons, the focused one lit, and a bracket for the part that's on screen.
/// Click a tile to go there; drag one to reorder the strip.
final class IndicatorPanel: OverlayPanel {
    var hideWork: DispatchWorkItem?
    private let view = IndicatorView()
    private let fx = NSVisualEffectView()
    var isDragging: Bool { view.dragFrom != nil }

    init() {
        super.init(level: .statusBar, clickThrough: false)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            view.topAnchor.constraint(equalTo: fx.topAnchor),
            view.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        contentView = fx
        hasShadow = true
        alphaValue = 0
    }

    func update(key: StripKey, strip: Strip, result: LayoutResult, display: Display) {
        view.key = key
        let maxWidth = display.frame.width - 80
        view.load(strip: strip, result: result, maxWidth: maxWidth)
        let size = view.preferredSize(maxWidth: maxWidth)
        let area = display.visibleFrame
        // Top centre, just under the menu bar (AX coordinates grow downwards).
        let frame = CGRect(x: area.midX - size.width / 2, y: area.minY + 10, width: size.width, height: size.height)
        move(to: Displays.toAppKit(frame))
        view.needsDisplay = true
    }

    func present() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }
}

final class IndicatorView: NSView {
    var key: StripKey?
    private var tiles: [Tile] = []
    private var pinnedTiles: [Tile] = []
    private var viewport: ClosedRange<Double> = 0...1
    /// Tiles shrink when a long strip wouldn't fit across the screen.
    private var scale: CGFloat = 1
    fileprivate var dragFrom: Int?
    private var dragX: CGFloat = 0
    private var hoverDrop: Int?

    struct Tile {
        var windows: [WindowID]
        var icons: [NSImage]
        var focused: Bool
        var share: Double
        var rect: NSRect = .zero
        /// Where the column sits on the strip, in points, to tell which tiles are on screen.
        var start: Double = 0
        var width: Double = 0
    }

    private let tileH: CGFloat = 44
    private let pad: CGFloat = 10
    private let spacing: CGFloat = 6

    override var isFlipped: Bool { true }

    func load(strip: Strip, result: LayoutResult, maxWidth: CGFloat) {
        guard let geo = result.geometry else { return }
        viewport = strip.viewOffset...(strip.viewOffset + geo.viewportWidth)
        tiles = strip.columns.enumerated().map { i, col in
            Tile(windows: col.windows, icons: icons(col.windows), focused: strip.focusedPin == nil && i == strip.focused,
                 share: geo.widths[i] / geo.viewportWidth, start: geo.starts[i], width: geo.widths[i])
        }
        pinnedTiles = PinSide.allCases.compactMap { side in
            strip.pinned[side].map { col in
                Tile(windows: col.windows, icons: icons(col.windows), focused: strip.focusedPin == side, share: 0.33)
            }
        }
        scale = 1
        let natural = contentWidth()
        if natural > maxWidth { scale = max(0.3, (maxWidth - (natural - tilesWidth())) / tilesWidth()) }
        layoutTiles()
    }

    private func tilesWidth() -> CGFloat {
        (tiles + pinnedTiles).reduce(0) { $0 + tileWidth($1) }
    }

    private func contentWidth() -> CGFloat {
        let all = tiles + pinnedTiles
        if all.isEmpty { return 160 }
        return pad * 2 + tilesWidth() + spacing * CGFloat(all.count - 1) + (pinnedTiles.isEmpty ? 0 : 14)
    }

    private func icons(_ ids: [WindowID]) -> [NSImage] {
        ids.compactMap { WindowManager.shared.window($0)?.app.icon }
    }

    private func tileWidth(_ t: Tile) -> CGFloat {
        // Wider columns get wider tiles, within reason.
        max(40, min(140, CGFloat(t.share) * 110)) * scale
    }

    func preferredSize(maxWidth: CGFloat) -> CGSize {
        CGSize(width: min(maxWidth, contentWidth()), height: tileH + pad * 2)
    }

    private func layoutTiles() {
        var x = pad
        for i in tiles.indices {
            let w = tileWidth(tiles[i])
            tiles[i].rect = NSRect(x: x, y: pad, width: w, height: tileH)
            x += w + spacing
        }
        if !pinnedTiles.isEmpty { x += 14 }
        for i in pinnedTiles.indices {
            let w = tileWidth(pinnedTiles[i])
            pinnedTiles[i].rect = NSRect(x: x, y: pad, width: w, height: tileH)
            x += w + spacing
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if tiles.isEmpty && pinnedTiles.isEmpty {
            let s = NSAttributedString(string: "No windows on this strip", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            s.draw(at: NSPoint(x: bounds.midX - s.size().width / 2, y: bounds.midY - s.size().height / 2))
            return
        }
        // The bracket under the tiles that are on screen right now.
        if let first = tiles.indices.first(where: { overlapsViewport($0) }),
           let last = tiles.indices.last(where: { overlapsViewport($0) }) {
            let r = NSRect(x: tiles[first].rect.minX - 3, y: pad - 3, width: tiles[last].rect.maxX - tiles[first].rect.minX + 6, height: tileH + 6)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        }
        for (i, t) in tiles.enumerated() {
            var r = t.rect
            if dragFrom == i { r.origin.x = dragX - r.width / 2 }
            drawTile(t, in: r, dimmed: dragFrom == i)
        }
        if let to = hoverDrop, let from = dragFrom, to != from, tiles.indices.contains(to) {
            let r = tiles[to].rect
            let x = to > from ? r.maxX + spacing / 2 : r.minX - spacing / 2
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: pad, width: 3, height: tileH), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if let first = pinnedTiles.first {
            NSColor.separatorColor.setFill()
            NSRect(x: first.rect.minX - 10, y: pad + 6, width: 1, height: tileH - 12).fill()
            for t in pinnedTiles { drawTile(t, in: t.rect, dimmed: false, pinned: true) }
        }
    }

    private func overlapsViewport(_ i: Int) -> Bool {
        let t = tiles[i]
        return t.start + t.width > viewport.lowerBound + 1 && t.start < viewport.upperBound - 1
    }

    private func drawTile(_ t: Tile, in r: NSRect, dimmed: Bool, pinned: Bool = false) {
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        (t.focused ? NSColor.controlAccentColor.withAlphaComponent(0.45) : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
        path.fill()
        if t.focused {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        let icons = t.icons.isEmpty ? [NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!] : t.icons
        let n = min(icons.count, 3)
        let size: CGFloat = max(10, min(n == 1 ? 28 : 20, r.width - 8))
        let totalH = size * CGFloat(n) * (n == 1 ? 1 : 0.62) + (n == 1 ? 0 : size * 0.38)
        var y = r.midY - totalH / 2
        for icon in icons.prefix(3) {
            icon.draw(in: NSRect(x: r.midX - size / 2, y: y, width: size, height: size), from: .zero,
                      operation: .sourceOver, fraction: dimmed ? 0.4 : 1, respectFlipped: true, hints: nil)
            y += size * 0.62
        }
        if pinned {
            let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")!
            pin.draw(in: NSRect(x: r.maxX - 13, y: r.minY + 3, width: 10, height: 10))
        }
    }

    // MARK: - Mouse

    private func tileIndex(at p: NSPoint) -> Int? {
        tiles.firstIndex { $0.rect.insetBy(dx: -spacing / 2, dy: -4).contains(p) }
    }

    private var downPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        if let pi = pinnedTiles.firstIndex(where: { $0.rect.contains(p) }), let key, let id = pinnedTiles[pi].windows.first {
            WindowManager.shared.focusFromIndicator(key: key, window: id)
            downPoint = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let start = downPoint else { return }
        if dragFrom == nil, abs(p.x - start.x) > 4, let i = tileIndex(at: start) {
            dragFrom = i
        }
        guard dragFrom != nil else { return }
        dragX = p.x
        hoverDrop = tileIndex(at: NSPoint(x: p.x, y: tileH / 2 + pad)) ?? (p.x < (tiles.first?.rect.minX ?? 0) ? 0 : tiles.count - 1)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragFrom = nil; hoverDrop = nil; downPoint = nil; needsDisplay = true }
        guard let key else { return }
        if let from = dragFrom {
            if let to = hoverDrop, to != from { WindowManager.shared.reorderFromIndicator(key: key, from: from, to: to) }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if let i = tileIndex(at: p), let id = tiles[i].windows.first {
            WindowManager.shared.focusFromIndicator(key: key, window: id)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
