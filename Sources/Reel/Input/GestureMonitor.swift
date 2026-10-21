import AppKit
import ReelCore

/// Follows three- or four-finger horizontal swipes on the trackpad, one to one.
///
/// It listens to the raw touch frames macOS sends as gesture events, so the strip moves with
/// the fingers instead of waiting for a finished swipe. The tap only listens; macOS still
/// receives every swipe, which is why the setup guide asks to free the swipe there.
final class GestureMonitor {
    static let shared = GestureMonitor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private enum Phase { case idle, deciding, tracking, rejected }
    private var phase: Phase = .idle
    private var startX: Double = 0
    private var startY: Double = 0
    private var lastX: Double = 0
    /// The fingers being followed. When the set changes the centre point jumps, so movement
    /// is measured again from the new set instead.
    private var fingerIDs: Set<NSObject> = []
    /// When the finger count first stopped matching. A slow swipe makes macOS flicker touches
    /// between moving and resting for a frame or two, which must not end the swipe.
    private var mismatchSince: CFTimeInterval?

    private init() {}

    func start() {
        guard tap == nil, ConfigStore.shared.config.swipeFingers > 0 else { return }
        // NSEventType.gesture is 29; it carries the touches.
        let mask: CGEventMask = 1 << 29
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, ctx in
            let me = Unmanaged<GestureMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            me.handle(event)
            return Unmanaged.passUnretained(event)
        }, userInfo: ref) else {
            Log.engine("trackpad swipe unavailable: could not create the event tap")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        end(rejected: false)
    }

    func restart() {
        stop()
        start()
    }

    private func handle(_ cg: CGEvent) {
        guard let event = NSEvent(cgEvent: cg), event.type == .gesture else { return }
        let fingers = ConfigStore.shared.config.swipeFingers
        let all = event.allTouches()
        // macOS mixes gesture events with no touches at all into a swipe (its own swipe
        // recognizer reporting in). They say nothing about the fingers; a real lift arrives as
        // touches in the ended phase.
        if all.isEmpty { return }
        let down = all.filter { $0.phase != .ended && $0.phase != .cancelled }
        // Count resting touches only when that's what makes the number right: a thumb resting
        // on the pad shouldn't count, but a finger moving slowly can be marked as resting.
        let moving = down.filter { !$0.isResting }
        let touches = down.count == fingers ? Array(down) : Array(moving)
        let count = touches.count

        guard count == fingers else {
            let now = CACurrentMediaTime()
            let lifted = all.contains { $0.phase == .ended || $0.phase == .cancelled }
            if down.isEmpty || lifted || count > fingers {
                // A finger lifted, or one was added: the swipe is over right away, so a flick
                // still throws the strip.
                // Lifting one of too many fingers still leaves too many (or exactly enough) down:
                // that stays rejected until fewer than the swipe's count remain.
                end(rejected: count > fingers || (phase == .rejected && down.count >= fingers))
            } else if phase == .tracking || phase == .deciding {
                // A slow finger marked as resting for a moment; give it a short grace period.
                if mismatchSince == nil { mismatchSince = now }
                if now - mismatchSince! > 0.12 { end(rejected: false) }
            } else if phase == .rejected {
                if count < fingers { phase = .idle }
            }
            return
        }
        mismatchSince = nil

        let ids = Set(touches.map { $0.identity as! NSObject })
        let x = touches.map { Double($0.normalizedPosition.x) }.reduce(0, +) / Double(count)
        let y = touches.map { Double($0.normalizedPosition.y) }.reduce(0, +) / Double(count)

        if ids != fingerIDs {
            // Different fingers than last frame: keep going from here without a jump.
            if phase == .deciding { startX += x - lastX; startY = y }
            lastX = x
            fingerIDs = ids
            if phase != .idle { return }
        }

        switch phase {
        case .idle:
            phase = .deciding
            startX = x; startY = y; lastX = x
            // Out of the tap callback, so the tap never waits on it.
            DispatchQueue.main.async { WindowManager.shared.gesturePrepare() }
        case .deciding:
            lastX = x
            let dx = x - startX, dy = y - startY
            // Up and down belong to Mission Control and App Exposé.
            if abs(dy) > 0.04 && abs(dy) > abs(dx) {
                phase = .rejected
            } else if abs(dx) > 0.015 {
                phase = .tracking
                lastX = x
                WindowManager.shared.gestureBegan()
            }
        case .tracking:
            let dx = x - lastX
            lastX = x
            if dx != 0 { WindowManager.shared.gestureChanged(dx: dx) }
        case .rejected:
            break
        }
    }

    private func end(rejected: Bool) {
        if phase == .tracking { WindowManager.shared.gestureEnded(cancelled: false) }
        phase = rejected ? .rejected : .idle
        fingerIDs = []
        mismatchSince = nil
    }
}
