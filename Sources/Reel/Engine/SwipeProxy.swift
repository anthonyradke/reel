import AppKit
import ReelCore
import ScreenCaptureKit

/// Swipes the strip with pictures of its windows instead of the windows themselves.
///
/// Apps move their windows in their own time when asked through Accessibility, so a strip of
/// real windows falls out of step during a swipe and the wallpaper shows through the gaps. Here
/// the windows are captured when the fingers land, and one panel covers the display with the
/// desktop behind them and a layer per window. Moving layers in one transaction keeps every
/// window in step at the display's refresh rate. On release the pictures settle on a spring,
/// the real windows are put in their final places underneath, and the panel fades away once
/// they are there.
///
/// Needs Screen Recording permission and macOS 14. Without either, swipes move the real windows.
final class SwipeProxy: NSObject {
    enum State { case idle, preparing, ready, tracking, settling }
    private(set) var state: State = .idle
    private(set) var key: StripKey?
    /// The view offset the pictures show right now.
    private(set) var offset: Double = 0

    /// Something on screen that moves with a strip window: the window itself, or one of Reel's
    /// own panels decorating it (focus border, dimming, tab bar).
    struct Source {
        var number: CGWindowID
        var owner: WindowID
        /// Where the item is on screen. For a window this is its layout frame, used only when the
        /// capture can't say where the window really is.
        var frame: CGRect
        /// The owner's layout origin when captured. Frames passed to `begin` and `move` are layout
        /// frames, and each item keeps its offset from them (a window held back by its minimum
        /// width or height isn't exactly at its layout frame).
        var anchor: CGPoint
        /// Whether the window is on screen. One scrolled away is parked elsewhere, so only its
        /// captured size counts.
        var onScreen: Bool
    }

    private struct Item {
        let source: Source
        let layer: CALayer
        let isWindow: Bool
        /// Where the item was on screen when captured.
        let frame: CGRect
        /// Where the item sits relative to its owner's layout frame.
        let delta: CGPoint
    }

    private var generation = 0
    private var display: Display?
    private var items: [Item] = []
    private var root: CALayer?
    private var panel: OverlayPanel?
    private var readyAt: CFTimeInterval = 0
    private var onReady: (() -> Void)?

    private var spring = Spring(0)
    private var frames: ((Double) -> [WindowID: CGRect])?
    private var inPlace: (([WindowID: CGRect]) -> Bool)?
    private var settled: (() -> Void)?
    private var settledAt: CFTimeInterval?
    private var lastCheck: CFTimeInterval = 0
    private var animated = true
    /// Where each window's picture is drawn right now, in screen coordinates.
    private var shown: [WindowID: CGRect] = [:]
    /// A CADisplayLink (macOS 14), kept untyped so the class still builds for macOS 13.
    private var link: AnyObject?
    private var lastTick: CFTimeInterval = 0

    static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks for Screen Recording once, the first time a swipe could have used it.
    static func requestPermissionOnce() {
        let asked = "askedScreenRecording"
        guard !UserDefaults.standard.bool(forKey: asked) else { return }
        UserDefaults.standard.set(true, forKey: asked)
        CGRequestScreenCaptureAccess()
    }

    /// Whether pictures for `key` are ready to swipe with, and no older than `age` seconds.
    func isReady(for key: StripKey, within age: CFTimeInterval = 2) -> Bool {
        state == .ready && self.key == key && CACurrentMediaTime() - readyAt < age
    }

    // MARK: - Capture

    /// Captures the windows and the desktop behind them. Runs when the fingers land, so the
    /// pictures are usually ready by the time they've moved far enough to count as a swipe.
    func prepare(key: StripKey, display: Display, sources: [Source], completion: @escaping () -> Void) {
        guard #available(macOS 14.0, *) else { return }
        if state == .settling || state == .tracking { return }
        generation += 1
        let gen = generation
        // Still fading out from the last swipe: finish that now.
        root?.removeFromSuperlayer()
        root = nil
        panel?.orderOut(nil)
        state = .preparing
        self.key = key
        self.display = display
        onReady = completion
        let started = CACurrentMediaTime()
        Task.detached(priority: .userInitiated) {
            let shot = await Self.capture(display: display, sources: sources)
            await MainActor.run {
                guard self.generation == gen, self.state == .preparing else { return }
                guard let shot else {
                    Log.engine("swipe pictures: capture failed")
                    self.reset()
                    return
                }
                Log.engine("swipe pictures: \(shot.images.count) windows in \(Int((CACurrentMediaTime() - started) * 1000)) ms")
                self.build(shot, sources: sources)
                self.state = .ready
                self.readyAt = CACurrentMediaTime()
                let ready = self.onReady
                self.onReady = nil
                ready?()
            }
        }
    }

    private struct Shot {
        var background: CGImage
        var images: [CGWindowID: CGImage]
        /// Where the captured windows really are, which can differ from their layout frames.
        var frames: [CGWindowID: CGRect]
        /// Window numbers back to front, as the window server stacks them.
        var order: [CGWindowID]
    }

    @available(macOS 14.0, *)
    private static func capture(display: Display, sources: [Source]) async -> Shot? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else { return nil }
        let scale = await MainActor.run {
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id }?
                .backingScaleFactor ?? 2
        }
        let wanted = Set(sources.map(\.number))
        let byNumber = Dictionary(content.windows.filter { wanted.contains($0.windowID) }.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let ownPid = ProcessInfo.processInfo.processIdentifier
        // The desktop as it would look without the strip: everything else stays in the picture.
        let hide = content.windows.filter { wanted.contains($0.windowID) || $0.owningApplication?.processID == ownPid }

        async let backgroundShot: CGImage? = {
            let filter = SCContentFilter(display: scDisplay, excludingWindows: hide)
            let config = SCStreamConfiguration()
            config.width = Int(display.frame.width * scale)
            config.height = Int(display.frame.height * scale)
            config.showsCursor = false
            return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }()

        let images = await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for (number, window) in byNumber {
                group.addTask {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int(window.frame.width * scale))
                    config.height = max(1, Int(window.frame.height * scale))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    return (number, try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
                }
            }
            var out: [CGWindowID: CGImage] = [:]
            for await (n, img) in group { if let img { out[n] = img } }
            return out
        }
        guard let background = await backgroundShot else { return nil }

        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        let order = list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }.filter { wanted.contains($0) }.reversed()
        return Shot(background: background, images: images, frames: byNumber.mapValues(\.frame), order: Array(order))
    }

    // MARK: - Layers

    private func build(_ shot: Shot, sources: [Source]) {
        guard let display else { return }
        let panel = self.panel ?? {
            let p = OverlayPanel(level: .normal)
            // Not transient: Mission Control should take it along like a window, not drop it.
            p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
            let v = NSView()
            v.wantsLayer = true
            p.contentView = v
            self.panel = p
            return p
        }()
        panel.setFrame(Displays.toAppKit(display.frame), display: false)
        root?.removeFromSuperlayer()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let root = CALayer()
        root.isGeometryFlipped = true
        root.frame = CGRect(origin: .zero, size: display.frame.size)
        let bg = CALayer()
        bg.frame = root.bounds
        bg.contents = shot.background
        bg.contentsGravity = .resize
        root.addSublayer(bg)

        let rank = Dictionary(shot.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        items = sources.sorted { (rank[$0.number] ?? -1) < (rank[$1.number] ?? -1) }.compactMap { s in
            let isWindow = s.number == s.owner
            func delta(_ f: CGRect) -> CGPoint { CGPoint(x: f.minX - s.anchor.x, y: f.minY - s.anchor.y) }
            guard let image = shot.images[s.number] ?? nil else {
                // A window we couldn't capture still needs to cover its spot.
                guard isWindow else { return nil }
                let l = CALayer()
                l.backgroundColor = NSColor.windowBackgroundColor.cgColor
                l.cornerRadius = 12
                root.addSublayer(l)
                return Item(source: s, layer: l, isWindow: true, frame: s.frame, delta: delta(s.frame))
            }
            var frame = s.frame
            if isWindow, let real = shot.frames[s.number] {
                frame = s.onScreen ? real : CGRect(origin: s.frame.origin, size: real.size)
            }
            let l = CALayer()
            l.contents = image
            l.contentsGravity = .resize
            if isWindow {
                l.shadowColor = NSColor.black.cgColor
                l.shadowOpacity = 0.35
                l.shadowRadius = 16
                l.shadowOffset = CGSize(width: 0, height: 8)
            }
            root.addSublayer(l)
            return Item(source: s, layer: l, isWindow: isWindow, frame: frame, delta: delta(frame))
        }
        // Everything starts exactly where it is on screen.
        shown = [:]
        for item in items { place(item, at: item.frame.origin, size: item.frame.size) }
        panel.contentView?.layer?.addSublayer(root)
        CATransaction.commit()
        self.root = root
    }

    private func place(_ item: Item, at origin: CGPoint, size: CGSize) {
        guard let display else { return }
        if item.isWindow { shown[item.source.owner] = CGRect(origin: origin, size: size) }
        let r = CGRect(x: origin.x - display.frame.minX, y: origin.y - display.frame.minY, width: size.width, height: size.height)
        if item.layer.frame != r {
            item.layer.frame = r
            if item.isWindow {
                item.layer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 12, cornerHeight: 12, transform: nil)
            }
        }
    }

    private func apply(_ frames: [WindowID: CGRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in items {
            guard let owner = frames[item.source.owner] else { continue }
            let origin = CGPoint(x: owner.minX + item.delta.x, y: owner.minY + item.delta.y)
            place(item, at: origin, size: item.frame.size)
        }
        CATransaction.commit()
    }

    // MARK: - Swiping

    /// Covers the strip with the pictures. `above` is the window number to stack the panel
    /// over: the frontmost of the strip and its decorations, so other windows stay on top.
    func begin(offset: Double, frames: [WindowID: CGRect]) {
        guard state == .ready, let panel else { return }
        state = .tracking
        self.offset = offset
        apply(frames)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1
        }
        let numbers = Set(items.map(\.source.number))
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        if let top = list.lazy.compactMap({ ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }).first(where: { numbers.contains($0) }) {
            panel.order(.above, relativeTo: Int(top))
        } else {
            panel.orderFrontRegardless()
        }
    }

    func move(offset: Double, frames: [WindowID: CGRect]) {
        guard state == .tracking else { return }
        self.offset = offset
        apply(frames)
    }

    /// Picks up a settling strip again when the fingers land before it has finished. Returns
    /// the unfinished settle's `done`, which the caller now owns: it must run once the new
    /// swipe has settled or been dropped.
    func resume() -> (() -> Void)? {
        guard state == .settling else { return nil }
        stopLink()
        state = .tracking
        let pending = settled
        settled = nil
        return pending
    }

    /// Lets go: the pictures spring to `target` (or jump there when not `animated`), then the
    /// panel goes once `inPlace` says the real windows are where the pictures show them (or
    /// after half a second, whichever comes first).
    func settle(to target: Double, velocity: Double, omega: Double, animated: Bool,
                frames: @escaping (Double) -> [WindowID: CGRect], inPlace: @escaping ([WindowID: CGRect]) -> Bool,
                done: @escaping () -> Void) {
        guard state == .tracking else { done(); return }
        state = .settling
        spring = Spring(offset, omega: omega)
        spring.velocity = velocity
        spring.target = target
        if !animated { spring.snap() }
        self.animated = animated
        self.frames = frames
        self.inPlace = inPlace
        settled = done
        settledAt = nil
        startLink()
    }

    private func startLink() {
        guard #available(macOS 14.0, *), let view = panel?.contentView else { return }
        stopLink()
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = CACurrentMediaTime()
    }

    private func stopLink() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
    }

    @objc private func tick(_ l: AnyObject) {
        guard state == .settling else { stopLink(); return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 30)
        lastTick = now
        if spring.step(dt) || settledAt == nil {
            offset = spring.value
            if let frames { apply(frames(offset)) }
            if spring.isSettled && settledAt == nil { settledAt = now }
            return
        }
        // At rest: wait for the real windows to be where the pictures are, then hand over.
        // Asking where they are is a round trip to each app, so not on every frame.
        if now - (settledAt ?? now) > 0.5 {
            finish(fade: animated)
        } else if now - lastCheck >= 0.05 {
            lastCheck = now
            guard let display else { return }
            if inPlace?(shown.filter { $0.value.intersects(display.frame) }) == true { finish(fade: animated) }
        }
    }

    private func finish(fade: Bool) {
        stopLink()
        let done = settled
        settled = nil
        frames = nil
        inPlace = nil
        guard let panel else { reset(); done?(); return }
        if fade {
            state = .idle
            let gen = generation
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.generation == gen, self.state == .idle else { return }
                self.reset()
            })
            done?()
        } else {
            reset()
            done?()
        }
    }

    /// Drops the pictures and hides the panel right away.
    func cancel() {
        guard state != .idle else { return }
        let done = settled
        generation += 1
        reset()
        done?()
    }

    private func reset() {
        stopLink()
        state = .idle
        key = nil
        items = []
        shown = [:]
        onReady = nil
        settled = nil
        frames = nil
        inPlace = nil
        root?.removeFromSuperlayer()
        root = nil
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }
}
