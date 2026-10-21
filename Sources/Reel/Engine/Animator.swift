import AppKit
import CoreVideo
import ReelCore

/// Moves windows toward their targets on a display-synced spring. The first frame is sent the
/// moment a target changes, so a key press moves the strip right away instead of waiting for
/// the next vsync.
final class Animator {
    weak var manager: WindowManager?

    final class Entry {
        let id: WindowID
        let window: TrackedWindow
        var x: Spring
        var y: Spring
        var target: CGRect
        var visible: Bool
        var hiddenSide: PinSide
        var display: Display
        var lastSentOrigin: CGPoint?
        var lastSentSize: CGSize?
        var parked = false
        var frozen = false

        init(window: TrackedWindow, frame: CGRect, display: Display, omega: Double) {
            id = window.id
            self.window = window
            x = Spring(Double(frame.minX), omega: omega)
            y = Spring(Double(frame.minY), omega: omega)
            target = frame
            visible = true
            hiddenSide = .right
            self.display = display
        }

        var current: CGRect {
            CGRect(x: x.value, y: y.value, width: Double(target.width), height: Double(target.height))
        }
    }

    private(set) var entries: [WindowID: Entry] = [:]
    private var link: CVDisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var tickScheduled = false
    var isRunning: Bool { link.map { CVDisplayLinkIsRunning($0) } ?? false }

    private var omega: Double { manager?.config.springResponse ?? 22 }

    func setTarget(_ w: TrackedWindow, frame: CGRect, visible: Bool, hiddenSide: PinSide, display: Display, animated: Bool) {
        let e: Entry
        if let existing = entries[w.id] {
            e = existing
        } else {
            // First time we see it: start from where the window actually is.
            let actual = w.frame
            let start = actual ?? frame
            e = Entry(window: w, frame: CGRect(origin: start.origin, size: frame.size), display: display, omega: omega)
            entries[w.id] = e
            // Only resize it if it isn't the right size already.
            e.lastSentSize = actual?.size
            // A window that starts off screen shouldn't fly across the display.
            if !display.frame.intersects(start) { e.x.value = Double(frame.minX); e.y.value = Double(frame.minY) }
        }
        let wasVisible = e.visible && !e.parked
        e.target = frame
        e.visible = visible
        e.hiddenSide = hiddenSide
        e.display = display
        e.x.omega = omega
        e.y.omega = omega
        e.x.target = Double(frame.minX)
        e.y.target = Double(frame.minY)

        // Off screen before and after: nothing to see, jump straight to the parking spot.
        let animate = animated && (visible || wasVisible) && !e.frozen
        if !animate {
            e.x.snap()
            e.y.snap()
        }
        if e.frozen { return }
        sendSizeIfNeeded(e)
        if animate && !(e.x.isSettled && e.y.isSettled) {
            e.parked = false
            // Move one step now so the response is immediate, then let the display link carry on.
            stepEntry(e, dt: 1.0 / 120)
            ensureRunning()
        } else {
            settle(e)
        }
    }

    func targetFrame(of id: WindowID) -> CGRect? {
        entries[id]?.target
    }

    func currentFrame(of id: WindowID) -> CGRect? {
        guard let e = entries[id] else { return nil }
        return e.current
    }

    /// Whether the window is meant to be on screen (false when scrolled away or parked).
    func isVisible(_ id: WindowID) -> Bool {
        entries[id]?.visible ?? false
    }

    func forget(_ id: WindowID) {
        entries[id] = nil
    }

    /// Forgets what was last sent, so the next layout sends the frame again even if the
    /// target hasn't changed (the app moved the window behind our back).
    func invalidate(_ id: WindowID) {
        entries[id]?.lastSentOrigin = nil
        entries[id]?.lastSentSize = nil
    }

    func freeze(_ id: WindowID) { entries[id]?.frozen = true }

    func unfreeze(_ id: WindowID) {
        guard let e = entries[id] else { return }
        e.frozen = false
        // Pick up from wherever the user left it.
        if let f = e.window.frame {
            e.x.value = Double(f.minX); e.y.value = Double(f.minY)
            e.lastSentOrigin = f.origin
            e.lastSentSize = f.size
        }
    }

    /// After a swipe, windows keep the speed the fingers had as they start settling.
    func carryVelocity(_ v: Double, windows: [WindowID]) {
        for id in windows { entries[id]?.x.velocity = v }
    }

    func stopAll() {
        if let link, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
        entries.removeAll()
    }

    // MARK: - Driving

    private func ensureRunning() {
        if link == nil {
            var l: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&l)
            guard let l else { return }
            CVDisplayLinkSetOutputCallback(l, { _, _, _, _, _, ctx in
                let me = Unmanaged<Animator>.fromOpaque(ctx!).takeUnretainedValue()
                me.scheduleTick()
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
            link = l
        }
        guard let link, !CVDisplayLinkIsRunning(link) else { return }
        lastTick = CACurrentMediaTime()
        CVDisplayLinkStart(link)
    }

    /// The display link fires on its own thread; hop to main, at most one tick in flight.
    private let tickLock = NSLock()
    private func scheduleTick() {
        tickLock.lock()
        if tickScheduled { tickLock.unlock(); return }
        tickScheduled = true
        tickLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickLock.lock(); self.tickScheduled = false; self.tickLock.unlock()
            self.tick()
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 30)
        lastTick = now
        var moving = false
        for e in entries.values where !e.frozen {
            if e.x.isSettled && e.y.isSettled { continue }
            if stepEntry(e, dt: dt) { moving = true }
        }
        manager?.animationFrame()
        if !moving, let link, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
    }

    /// Returns true while the entry is still moving.
    @discardableResult
    private func stepEntry(_ e: Entry, dt: Double) -> Bool {
        let a = e.x.step(dt)
        let b = e.y.step(dt)
        let moving = a || b
        if moving {
            // macOS won't leave less than about 40 points of a window on screen, so a window
            // sliding off the edge would be pushed back and then jump when it parks. Stop it at
            // the parking spot instead: one point on screen, which macOS allows.
            let d = e.display.frame
            let w = (e.lastSentSize ?? e.target.size).width
            let x = min(max(e.x.value.rounded(), d.minX - w + 1), d.maxX - 1)
            send(e, origin: CGPoint(x: x, y: e.y.value.rounded()))
        } else {
            settle(e)
        }
        return moving
    }

    /// Final placement: the exact frame if on screen, or the parking spot if not.
    private func settle(_ e: Entry) {
        if e.visible {
            e.parked = false
            send(e, origin: e.target.origin)
        } else {
            guard let all = manager?.displays else { return }
            let spot = Displays.parkingSpot(for: e.lastSentSize ?? e.target.size, on: e.display, side: e.hiddenSide, all: all, y: e.target.minY)
            e.parked = true
            send(e, origin: spot)
        }
    }

    private func sendSizeIfNeeded(_ e: Entry) {
        // A window off screen keeps its old size until it comes back. Growing has to happen
        // somewhere on the display, so resizing it now could flash it onto the screen.
        guard e.visible else { return }
        let size = e.target.size
        let previous = e.lastSentSize
        guard previous.map({ abs($0.width - size.width) > 0.5 || abs($0.height - size.height) > 0.5 }) ?? true else { return }
        e.lastSentSize = size
        // Resize where the window is now (the move toward the target follows on the spring).
        // A window that grows has to do it somewhere the new size fits on the display, or macOS
        // cuts it short; one that shrinks can stay put rather than flash across the screen.
        let origin = e.lastSentOrigin ?? CGPoint(x: e.x.value.rounded(), y: e.y.value.rounded())
        let d = e.display.frame
        let grows = previous.map { size.width > $0.width + 0.5 || size.height > $0.height + 0.5 } ?? true
        let resizeAt = grows ? CGPoint(x: min(max(origin.x, d.minX), max(d.minX, d.maxX - size.width)), y: e.target.minY) : nil
        e.window.lastCommanded = CGRect(origin: e.target.origin, size: size)
        e.window.lastCommandedAt = CACurrentMediaTime()
        e.window.app.mover.set(e.window.element, app: e.window.app.element, id: e.id, origin: origin, size: size, resizeAt: resizeAt)
    }

    private func send(_ e: Entry, origin: CGPoint) {
        if let last = e.lastSentOrigin, abs(last.x - origin.x) < 0.5, abs(last.y - origin.y) < 0.5 { return }
        e.lastSentOrigin = origin
        e.window.lastCommanded = CGRect(origin: e.parked ? e.target.origin : origin, size: e.target.size)
        e.window.lastCommandedAt = CACurrentMediaTime()
        e.window.app.mover.set(e.window.element, app: e.window.app.element, id: e.id, origin: origin, size: nil)
    }
}
