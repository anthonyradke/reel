import AppKit
import ReelCore

/// A borderless see-through panel that never takes focus.
class OverlayPanel: NSPanel {
    init(level: NSWindow.Level = .normal, clickThrough: Bool = true) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = clickThrough
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var orderedAbove: WindowID??

    /// Places the panel at an AX (top-left origin) frame and orders it just above a window.
    /// `keepOrder` skips the reorder when it's already up above that window: during a swipe
    /// this runs for every touch frame, and nothing changes the stacking then.
    func show(at axFrame: CGRect, above window: WindowID?, keepOrder: Bool = false) {
        move(to: Displays.toAppKit(axFrame))
        if keepOrder, isVisible, orderedAbove == .some(window) { return }
        orderedAbove = .some(window)
        if let window {
            order(.above, relativeTo: Int(window))
        } else {
            orderFrontRegardless()
        }
    }

    /// Moves without resizing when the size is the same. Resizing a window reallocates its
    /// backing store; moving one is just a new position for the window server.
    func move(to frame: NSRect) {
        if frame.size == self.frame.size {
            if frame.origin != self.frame.origin { setFrameOrigin(frame.origin) }
        } else {
            setFrame(frame, display: true)
        }
    }

    override func orderOut(_ sender: Any?) {
        orderedAbove = nil
        super.orderOut(sender)
    }
}

final class OverlayController {
    private let border = BorderPanel()
    private var dims: [StripKey: [WindowID: OverlayPanel]] = [:]
    private var tabBars: [StripKey: [TabBarPanel]] = [:]
    private var indicators: [String: IndicatorPanel] = [:]
    private var focusedFrame: CGRect?
    private var focusedID: WindowID?
    private var holdingModifiers = false
    private var stickyIndicator = false
    private var holdWork: DispatchWorkItem?

    private var manager: WindowManager { WindowManager.shared }
    private var config: Config { ConfigStore.shared.config }

    func hideAll() {
        border.orderOut(nil)
        dims.values.flatMap(\.values).forEach { $0.orderOut(nil) }
        dims.removeAll()
        tabBars.values.flatMap { $0 }.forEach { $0.orderOut(nil) }
        tabBars.removeAll()
        indicators.values.forEach { $0.orderOut(nil) }
    }

    /// Drops dimming and tab bars for strips that aren't on screen (another Space, or a display
    /// Reel no longer manages). The panels join every Space, so they'd show up there otherwise.
    func retain(only keys: Set<StripKey>) {
        for (k, panels) in dims where !keys.contains(k) {
            panels.values.forEach { $0.orderOut(nil) }
            dims[k] = nil
        }
        for (k, bars) in tabBars where !keys.contains(k) {
            bars.forEach { $0.orderOut(nil) }
            tabBars[k] = nil
        }
    }

    // MARK: - Layout updates

    /// `live` is set while the fingers drive the strip, so panels only move.
    func update(key: StripKey, result: LayoutResult, strip: Strip, display: Display, isFocusedStrip: Bool, live: Bool = false) {
        updateTabBars(key: key, result: result, live: live)
        updateDims(key: key, result: result, strip: strip, live: live)
        if let ind = indicators[display.uuid], ind.isVisible {
            ind.update(key: key, strip: strip, result: result, display: display)
        }
    }

    func updateFocus(_ frame: CGRect?, live: Bool = false) {
        focusedFrame = frame
        focusedID = manager.focusedKey.flatMap { manager.strips[$0]?.focusedWindow }.map { manager.window($0)?.id ?? $0 }
        guard config.focusBorder, let frame, let id = focusedID else {
            border.orderOut(nil)
            return
        }
        border.configure(width: config.focusBorderWidth, radius: config.focusBorderRadius, color: config.focusBorderColor)
        let current = manager.animator.currentFrame(of: id) ?? frame
        border.show(at: current.insetBy(dx: -config.focusBorderWidth, dy: -config.focusBorderWidth), above: id, keepOrder: live)
    }

    /// Every animation frame: keep the border and dimming glued to their windows.
    func followAnimation(_ animator: Animator) {
        if config.focusBorder, let id = focusedID, border.isVisible, let f = animator.currentFrame(of: id) {
            border.move(to: Displays.toAppKit(f.insetBy(dx: -config.focusBorderWidth, dy: -config.focusBorderWidth)))
        }
        for (id, panel) in dims.values.flatMap({ $0 }) where panel.isVisible {
            if let f = animator.currentFrame(of: id) { panel.move(to: Displays.toAppKit(f)) }
        }
        for bars in tabBars.values {
            for bar in bars {
                guard let id = bar.activeWindow, let f = animator.currentFrame(of: id) else { continue }
                var r = bar.axFrame
                r.origin.x = f.minX
                bar.move(to: Displays.toAppKit(r))
            }
        }
    }

    func windowMoved(_ id: WindowID) {}

    func titleChanged(_ id: WindowID) {
        for bars in tabBars.values { bars.forEach { $0.refresh() } }
    }

    private func updateDims(key: StripKey, result: LayoutResult, strip: Strip, live: Bool) {
        var panels = dims[key] ?? [:]
        guard config.dimInactive, manager.running else {
            panels.values.forEach { $0.orderOut(nil) }
            dims[key] = nil
            return
        }
        let focused = strip.focusedWindow
        var keep: Set<WindowID> = []
        for p in result.placements where p.visible && p.id != focused {
            let id = manager.window(p.id)?.id ?? p.id
            keep.insert(id)
            let panel = panels[id] ?? {
                let pnl = OverlayPanel()
                let v = NSView()
                v.wantsLayer = true
                v.layer?.cornerRadius = 10
                pnl.contentView = v
                panels[id] = pnl
                return pnl
            }()
            panel.contentView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(config.dimAmount).cgColor
            panel.show(at: manager.animator.currentFrame(of: id) ?? p.frame, above: id, keepOrder: live)
        }
        for (id, panel) in panels where !keep.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        dims[key] = panels
    }

    private func updateTabBars(key: StripKey, result: LayoutResult, live: Bool) {
        var bars = tabBars[key] ?? []
        while bars.count > result.tabBars.count { bars.removeLast().orderOut(nil) }
        while bars.count < result.tabBars.count { bars.append(TabBarPanel()) }
        for (bar, info) in zip(bars, result.tabBars) {
            bar.configure(key: key, info: info)
            let active = info.windows.indices.contains(info.active) ? info.windows[info.active] : info.windows.first
            bar.show(at: info.frame, above: active.map { manager.window($0)?.id ?? $0 }, keepOrder: live)
        }
        tabBars[key] = bars
    }

    // MARK: - Strip indicator

    func showIndicator(for key: StripKey, sticky: Bool) {
        guard config.showIndicator, let d = manager.display(for: key), let strip = manager.strips[key] else { return }
        stickyIndicator = sticky
        let ind = indicators[d.uuid] ?? {
            let i = IndicatorPanel()
            indicators[d.uuid] = i
            return i
        }()
        let result = Layout.compute(strip, context: manager.context(for: key, display: d))
        ind.update(key: key, strip: strip, result: result, display: d)
        ind.present()
        scheduleIndicatorHide(ind)
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let held = flags.contains(.control) && flags.contains(.option)
        guard held != holdingModifiers else { return }
        holdingModifiers = held
        holdWork?.cancel()
        if held {
            // Holding ⌃⌥ for a moment brings the strip up, so it can be clicked or dragged.
            // A quick shortcut shows it anyway, so wait a beat before popping it up.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.holdingModifiers, self.manager.running,
                      let key = self.manager.indicatorKey() else { return }
                self.showIndicator(for: key, sticky: false)
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            indicators.values.forEach { scheduleIndicatorHide($0) }
        }
    }

    private func scheduleIndicatorHide(_ ind: IndicatorPanel) {
        ind.hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak ind] in
            guard let self, let ind else { return }
            // Holding ⌃⌥ keeps it up so it can be clicked; a swipe keeps it up until the fingers lift.
            if self.holdingModifiers || self.stickyIndicator || ind.isDragging {
                self.scheduleIndicatorHide(ind)
                return
            }
            ind.dismiss()
        }
        ind.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}

// MARK: - Focus border

final class BorderPanel: OverlayPanel {
    private let shape = CAShapeLayer()

    init() {
        super.init()
        let v = NSView()
        v.wantsLayer = true
        v.layer?.addSublayer(shape)
        contentView = v
        shape.fillColor = nil
    }

    func configure(width: Double, radius: Double, color: RGBA) {
        guard style?.width != width || style?.radius != radius || style?.color != color else { return }
        style = (width, radius, color)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.lineWidth = width
        shape.strokeColor = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a).cgColor
        CATransaction.commit()
        self.radius = radius
        pathSize = nil
        rebuildPath(for: frame.size)
    }

    private var style: (width: Double, radius: Double, color: RGBA)?
    private var radius: Double = 10
    private var pathSize: CGSize?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        rebuildPath(for: frameRect.size)
    }

    private func rebuildPath(for size: CGSize) {
        guard size != pathSize else { return }
        pathSize = size
        let bounds = NSRect(origin: .zero, size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = shape.lineWidth / 2
        let r = bounds.insetBy(dx: inset, dy: inset)
        shape.frame = bounds
        shape.path = CGPath(roundedRect: r, cornerWidth: radius + inset, cornerHeight: radius + inset, transform: nil)
        CATransaction.commit()
    }
}

// MARK: - Tab bar

final class TabBarPanel: OverlayPanel {
    private(set) var key: StripKey?
    private(set) var info: TabBar?
    private(set) var axFrame: CGRect = .zero
    private let stack = NSStackView()

    var activeWindow: WindowID? {
        guard let info else { return nil }
        let id = info.windows.indices.contains(info.active) ? info.windows[info.active] : info.windows.first
        return id.map { WindowManager.shared.window($0)?.id ?? $0 }
    }

    init() {
        super.init(clickThrough: false)
        let fx = NSVisualEffectView()
        fx.material = .titlebar
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 8
        fx.layer?.masksToBounds = true
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        contentView = fx
    }

    func configure(key: StripKey, info: TabBar) {
        let changed = self.info != info
        self.key = key
        self.info = info
        if changed { refresh() }
    }

    override func show(at axFrame: CGRect, above window: WindowID?, keepOrder: Bool = false) {
        self.axFrame = axFrame.insetBy(dx: 0, dy: 1)
        super.show(at: self.axFrame, above: window, keepOrder: keepOrder)
    }

    func refresh() {
        guard let info else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, id) in info.windows.enumerated() {
            let w = WindowManager.shared.window(id)
            let b = TabButton(title: w?.title.isEmpty == false ? w!.title : (w?.app.name ?? "Window"),
                              icon: w?.app.icon, active: i == info.active, focused: info.focused)
            b.onClick = { [weak self] in
                guard let self, let key = self.key else { return }
                WindowManager.shared.selectTab(key: key, window: id)
            }
            stack.addArrangedSubview(b)
        }
    }
}

final class TabButton: NSView {
    var onClick: (() -> Void)?
    private let active: Bool
    private let focused: Bool

    init(title: String, icon: NSImage?, active: Bool, focused: Bool) {
        self.active = active
        self.focused = focused
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        let img = NSImageView(image: icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!)
        img.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: active ? .semibold : .regular)
        label.textColor = active ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [img, label])
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            img.widthAnchor.constraint(equalToConstant: 15),
            img.heightAnchor.constraint(equalToConstant: 15),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.centerXAnchor.constraint(equalTo: centerXAnchor).withPriority(.defaultLow),
        ])
        updateLayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let base = NSColor.controlAccentColor
        layer?.backgroundColor = active ? (focused ? base.withAlphaComponent(0.35) : NSColor.labelColor.withAlphaComponent(0.12)).cgColor : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
